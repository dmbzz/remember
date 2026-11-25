"""Windows 原生地址表边界与直连非 RFC1918 网段的发现来源校验。"""

from __future__ import annotations

import ctypes
import ipaddress
import struct
from pathlib import Path
from types import SimpleNamespace

import pytest

import app.services.ipv4_networks as networks_module
from app.services.ipv4_networks import LocalIpv4Networks
from app.services.pairing_discovery import PairingDiscovery
from app.services.pairing_service import PairingService


def windows_row(address: str, mask: str, flags: int = 0) -> bytes:
    # 独立构造微软 Windows ABI：地址/掩码是网络顺序，DWORD/USHORT 是小端整数。
    return b"".join([
        ipaddress.IPv4Address(address).packed,
        struct.pack("<I", 7),
        ipaddress.IPv4Address(mask).packed,
        struct.pack("<IIHH", 0, 65535, 0, flags),
    ])


def windows_table(*rows: bytes) -> bytes:
    return struct.pack("<I", len(rows)) + b"".join(rows)


def size_value(pointer):
    return ctypes.cast(pointer, ctypes.POINTER(ctypes.c_uint32)).contents


def test_windows_structure_layout_and_network_order_parsing():
    assert ctypes.sizeof(networks_module._DWORD) == 4
    assert networks_module._TABLE_OFFSET == 4
    assert networks_module._ROW_BYTES == 24
    assert networks_module._MibIpAddrRow.dwMask.offset == 8
    assert networks_module._MibIpAddrRow.wType.offset == 22
    data = windows_table(
        windows_row("172.10.229.15", "255.255.255.0"),
        windows_row("192.168.70.5", "255.255.255.0"),
        windows_row("172.10.229.16", "255.255.255.0"),
    )
    assert networks_module._parse_ipv4_table(data) == (
        ipaddress.IPv4Network("172.10.229.0/24"),
        ipaddress.IPv4Network("192.168.70.0/24"),
    )


@pytest.mark.parametrize(("mask", "network"), [
    ("255.0.0.0", "172.0.0.0/8"),
    ("255.255.0.0", "172.10.0.0/16"),
    ("255.255.254.0", "172.10.228.0/23"),
    ("255.255.255.254", "172.10.229.14/31"),
    ("255.255.255.255", "172.10.229.15/32"),
])
def test_windows_contiguous_masks(mask: str, network: str):
    data = windows_table(windows_row("172.10.229.15", mask))
    assert networks_module._parse_ipv4_table(data) == (ipaddress.IPv4Network(network),)


@pytest.mark.parametrize("mask", ["0.0.0.0", "255.0.255.0", "0.0.0.255", "255.255.255.1"])
def test_windows_rejects_zero_and_noncontiguous_masks(mask: str):
    data = windows_table(windows_row("172.10.229.15", mask))
    assert networks_module._parse_ipv4_table(data) == ()


@pytest.mark.parametrize("flags", [0x0008, 0x0040, 0x0048, 0x0009])
def test_windows_skips_disconnected_or_deleted_addresses(flags: int):
    data = windows_table(windows_row("172.10.229.15", "255.255.255.0", flags))
    assert networks_module._parse_ipv4_table(data) == ()


def test_windows_allows_valid_transient_address():
    data = windows_table(windows_row("172.10.229.15", "255.255.255.0", 0x0084))
    assert networks_module._parse_ipv4_table(data) == (ipaddress.IPv4Network("172.10.229.0/24"),)


@pytest.mark.parametrize("address", ["0.0.0.0", "224.0.0.1", "255.255.255.255"])
def test_windows_skips_non_host_interface_addresses(address: str):
    data = windows_table(windows_row(address, "255.255.255.0"))
    assert networks_module._parse_ipv4_table(data) == ()


@pytest.mark.parametrize("data", [
    b"",
    b"\x00" * 3,
    struct.pack("<I", 1),
    windows_table(windows_row("172.10.229.15", "255.255.255.0"))[:-1],
    struct.pack("<I", 2) + windows_row("172.10.229.15", "255.255.255.0"),
    struct.pack("<I", 0xFFFFFFFF),
    b"\x00" * (networks_module._MAX_BUFFER_BYTES + 1),
], ids=["empty", "short-header", "missing-row", "truncated-row", "short-row-count",
        "forged-count", "oversized-buffer"])
def test_windows_rejects_truncated_oversized_or_forged_tables(data: bytes):
    assert networks_module._parse_ipv4_table(data) == ()


def test_windows_two_call_query_and_interface_change_resize():
    first_table = windows_table(windows_row("172.10.229.15", "255.255.255.0"))
    new_table = windows_table(
        windows_row("172.10.229.15", "255.255.255.0"),
        windows_row("172.11.1.5", "255.255.255.0"),
    )
    calls = []

    def get_ip_addr_table(buffer, size_pointer, ordered):
        assert ordered is False
        size = size_value(size_pointer)
        calls.append((buffer is None, size.value))
        if buffer is None:
            size.value = len(first_table)
            return 122
        if size.value < len(new_table):
            size.value = len(new_table)
            return 122
        ctypes.memmove(buffer, new_table, len(new_table))
        size.value = len(new_table)
        return 0

    assert networks_module._query_ipv4_networks(get_ip_addr_table) == (
        ipaddress.IPv4Network("172.10.229.0/24"),
        ipaddress.IPv4Network("172.11.1.0/24"),
    )
    assert calls == [(True, 0), (False, len(first_table)), (False, len(new_table))]


@pytest.mark.parametrize("requested_size", [0, 3, networks_module._MAX_BUFFER_BYTES + 1, 0xFFFFFFFF])
def test_windows_query_bounds_size_before_allocating(
    requested_size: int, monkeypatch: pytest.MonkeyPatch
):
    calls = []

    def get_ip_addr_table(buffer, size_pointer, ordered):
        calls.append(buffer)
        size_value(size_pointer).value = requested_size
        return 122

    def unexpected_allocation(*args):
        pytest.fail("an invalid native buffer size must not be allocated")

    monkeypatch.setattr(networks_module.ctypes, "create_string_buffer", unexpected_allocation)
    assert networks_module._query_ipv4_networks(get_ip_addr_table) == ()
    assert calls == [None]


def test_windows_query_limits_repeated_growth():
    calls = []

    def get_ip_addr_table(buffer, size_pointer, ordered):
        calls.append(buffer is None)
        size_value(size_pointer).value += 28
        return 122

    assert networks_module._query_ipv4_networks(get_ip_addr_table) == ()
    assert len(calls) == 1 + networks_module._MAX_QUERY_ATTEMPTS


@pytest.mark.parametrize(("first_result", "second_result", "second_size"), [
    (50, 0, 28),
    (0, 0, 28),
    (122, 5, 28),
    (122, 122, 28),
    (122, 0, 3),
    (122, 0, 29),
])
def test_windows_query_failure_and_impossible_output_size(
    first_result: int, second_result: int, second_size: int
):
    def get_ip_addr_table(buffer, size_pointer, ordered):
        if buffer is None:
            size_value(size_pointer).value = 28
            return first_result
        size_value(size_pointer).value = second_size
        return second_result

    assert networks_module._query_ipv4_networks(get_ip_addr_table) == ()


def test_windows_loader_declares_fixed_width_native_signature(monkeypatch: pytest.MonkeyPatch):
    calls = []

    def function(*args):
        return 0

    def load_library(name, **options):
        calls.append((name, options))
        return SimpleNamespace(GetIpAddrTable=function)

    monkeypatch.setattr(networks_module.ctypes, "WinDLL", load_library, raising=False)
    assert networks_module._load_ip_addr_table() is function
    assert calls == [("iphlpapi.dll", {"use_last_error": True})]
    assert function.restype is ctypes.c_uint32
    assert function.argtypes == [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32), ctypes.c_int32]


@pytest.mark.parametrize("error", [OSError("API unavailable"), AttributeError("missing function"),
                                      ctypes.ArgumentError("bad native call"), MemoryError()])
def test_windows_enumeration_failure_is_empty(error: Exception, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setattr(networks_module, "sys", SimpleNamespace(platform="win32"))

    def load_error():
        raise error

    monkeypatch.setattr(networks_module, "_load_ip_addr_table", load_error)
    assert networks_module.windows_ipv4_networks() == ()


def test_non_windows_never_loads_native_library(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setattr(networks_module, "sys", SimpleNamespace(platform="linux"))

    def unexpected_load():
        pytest.fail("native Windows library must not be loaded on other systems")

    monkeypatch.setattr(networks_module, "_load_ip_addr_table", unexpected_load)
    assert networks_module.windows_ipv4_networks() == ()


def test_network_cache_refreshes_after_twenty_seconds_and_clears_failed_snapshot(
    monkeypatch: pytest.MonkeyPatch
):
    clock = [1000.0]
    snapshots = iter([
        (ipaddress.IPv4Network("172.10.229.0/24"),),
        (ipaddress.IPv4Network("172.11.1.0/24"),),
        (),
    ])
    calls = []

    def enumerate_networks():
        calls.append(clock[0])
        return next(snapshots)

    monkeypatch.setattr(networks_module.time, "monotonic", lambda: clock[0])
    monkeypatch.setattr(networks_module, "windows_ipv4_networks", enumerate_networks)
    cache = LocalIpv4Networks()
    old = ipaddress.IPv4Address("172.10.229.25")
    new = ipaddress.IPv4Address("172.11.1.25")
    assert cache.contains(old)
    clock[0] += 19.9
    assert not cache.contains(new)
    assert len(calls) == 1
    clock[0] = 1020.0
    assert cache.contains(new)
    assert not cache.contains(old)
    clock[0] = 1040.0
    assert not cache.contains(new)
    assert not cache.contains(new)
    assert calls == [1000.0, 1020.0, 1040.0]


def test_discovery_accepts_only_public_sources_in_direct_interface_subnet(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
):
    table = windows_table(windows_row("172.10.229.15", "255.255.255.0"))
    monkeypatch.setattr(networks_module, "windows_ipv4_networks",
                        lambda: networks_module._parse_ipv4_table(table))
    discovery = PairingDiscovery(PairingService(tmp_path / "pairing.json", 8000))
    request = b'{"app":"class_notes_assistant","version":1,"nonce":"0123456789abcdef0123456789abcdef"}'
    assert discovery.response_for(request, "172.10.229.30") is not None
    assert discovery.response_for(request, "172.10.228.30") is None
    assert discovery.response_for(request, "8.8.8.8") is None


@pytest.mark.parametrize(("source", "accepted"), [
    ("172.10.229.30", False),
    ("192.168.1.30", True),
    ("100.64.0.1", True),
    ("100.127.255.254", True),
    ("100.63.255.254", False),
    ("100.128.0.1", False),
    ("8.8.8.8", False),
])
def test_discovery_private_and_cgnat_fallback_when_enumeration_unavailable(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, source: str, accepted: bool
):
    monkeypatch.setattr(networks_module, "windows_ipv4_networks", lambda: ())
    discovery = PairingDiscovery(PairingService(tmp_path / "pairing.json", 8000))
    request = b'{"app":"class_notes_assistant","version":1,"nonce":"0123456789abcdef0123456789abcdef"}'
    assert (discovery.response_for(request, source) is not None) is accepted


@pytest.mark.parametrize("source", ["0.0.0.0", "224.0.0.1", "255.255.255.255", "::1"])
def test_discovery_cannot_expand_unusable_sources_with_a_subnet(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, source: str
):
    discovery = PairingDiscovery(PairingService(tmp_path / "pairing.json", 8000))

    def unexpected_lookup(address):
        pytest.fail("unusable source must be rejected before looking up subnets")

    monkeypatch.setattr(discovery._local_networks, "contains", unexpected_lookup)
    request = b'{"app":"class_notes_assistant","version":1,"nonce":"0123456789abcdef0123456789abcdef"}'
    assert discovery.response_for(request, source) is None
