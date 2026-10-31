"""Windows 当前 IPv4 直连子网；只用于补充局域网发现来源校验。"""

from __future__ import annotations

import ctypes
import ipaddress
import sys
import time
from collections.abc import Callable

__all__ = ["LocalIpv4Networks", "windows_ipv4_networks"]

# 微软结构文档：
# https://learn.microsoft.com/windows/win32/api/ipmib/ns-ipmib-mib_ipaddrrow_xp
# https://learn.microsoft.com/windows/win32/api/ipmib/ns-ipmib-mib_ipaddrtable
# DWORD 固定 32 位，不能使用在其他平台可能为 64 位的 c_ulong。
_DWORD = ctypes.c_uint32


class _MibIpAddrRow(ctypes.Structure):
    _fields_ = [
        ("dwAddr", _DWORD),
        ("dwIndex", _DWORD),
        ("dwMask", _DWORD),
        ("dwBCastAddr", _DWORD),
        ("dwReasmSize", _DWORD),
        ("unused1", ctypes.c_uint16),
        ("wType", ctypes.c_uint16),
    ]


class _MibIpAddrTable(ctypes.Structure):
    _fields_ = [("dwNumEntries", _DWORD), ("table", _MibIpAddrRow * 1)]


_TABLE_OFFSET = _MibIpAddrTable.table.offset
_ROW_BYTES = ctypes.sizeof(_MibIpAddrRow)
_MAX_BUFFER_BYTES = 256 * 1024
_MAX_QUERY_ATTEMPTS = 3
_ERROR_INSUFFICIENT_BUFFER = 122
_INACTIVE_ADDRESS_FLAGS = 0x0008 | 0x0040  # DISCONNECTED / DELETED


def _parse_ipv4_table(data: bytes) -> tuple[ipaddress.IPv4Network, ...]:
    """按结构布局解码；不信任越界计数、无效掩码或默认路由大小的子网。"""
    if len(data) < _TABLE_OFFSET or len(data) > _MAX_BUFFER_BYTES:
        return ()
    entries = _DWORD.from_buffer_copy(data).value
    if entries > (len(data) - _TABLE_OFFSET) // _ROW_BYTES:
        return ()
    networks: list[ipaddress.IPv4Network] = []
    for index in range(entries):
        offset = _TABLE_OFFSET + index * _ROW_BYTES
        row = _MibIpAddrRow.from_buffer_copy(data, offset)
        if row.wType & _INACTIVE_ADDRESS_FLAGS:
            continue
        # 地址字段的内存字节已是网络顺序，直接读取，避免 DWORD 整数二次换序。
        address_offset = offset + _MibIpAddrRow.dwAddr.offset
        mask_offset = offset + _MibIpAddrRow.dwMask.offset
        address = ipaddress.IPv4Address(data[address_offset:address_offset + 4])
        mask = int(ipaddress.IPv4Address(data[mask_offset:mask_offset + 4]))
        if address.is_unspecified or address.is_multicast or int(address) == 0xFFFFFFFF:
            continue
        # /0 会把任意公网来源当成本地；不连续位和反向 hostmask 也不能接受。
        inverse = mask ^ 0xFFFFFFFF
        if mask == 0 or inverse & (inverse + 1):
            continue
        network = ipaddress.IPv4Network((int(address), mask.bit_count()), strict=False)
        if network not in networks:
            networks.append(network)
    return tuple(networks)


def _query_ipv4_networks(get_ip_addr_table: Callable) -> tuple[ipaddress.IPv4Network, ...]:
    """大小探测与有限扩容，处理两次调用之间接口地址表发生变化的情况。"""
    size = _DWORD(0)
    if get_ip_addr_table(None, ctypes.byref(size), False) != _ERROR_INSUFFICIENT_BUFFER:
        return ()
    for _ in range(_MAX_QUERY_ATTEMPTS):
        allocated = size.value
        if not _TABLE_OFFSET <= allocated <= _MAX_BUFFER_BYTES:
            return ()
        buffer = ctypes.create_string_buffer(allocated)
        result = get_ip_addr_table(buffer, ctypes.byref(size), False)
        if result == 0:
            if not _TABLE_OFFSET <= size.value <= allocated:
                return ()
            return _parse_ipv4_table(buffer.raw[:size.value])
        if result != _ERROR_INSUFFICIENT_BUFFER or size.value <= allocated:
            return ()
    return ()


def _load_ip_addr_table() -> Callable:
    function = ctypes.WinDLL("iphlpapi.dll", use_last_error=True).GetIpAddrTable
    function.argtypes = [ctypes.c_void_p, ctypes.POINTER(_DWORD), ctypes.c_int32]
    function.restype = _DWORD
    return function


def windows_ipv4_networks() -> tuple[ipaddress.IPv4Network, ...]:
    """枚举失败或非 Windows 系统返回空集，不影响 HTTP 与私网发现兜底。"""
    if sys.platform != "win32":
        return ()
    try:
        return _query_ipv4_networks(_load_ip_addr_table())
    except (OSError, AttributeError, ValueError, OverflowError, MemoryError, ctypes.ArgumentError):
        return ()


class LocalIpv4Networks:
    """按需刷新而非启动快照，支持应用运行期间切换网络或开启热点。"""

    _cache_seconds = 20.0

    def __init__(self) -> None:
        self._networks: tuple[ipaddress.IPv4Network, ...] = ()
        self._expires_at = float("-inf")

    def contains(self, address: ipaddress.IPv4Address) -> bool:
        now = time.monotonic()
        if now >= self._expires_at:
            self._networks = windows_ipv4_networks()
            self._expires_at = now + self._cache_seconds
        return any(address in network for network in self._networks)
