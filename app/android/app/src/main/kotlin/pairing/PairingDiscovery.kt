package pairing

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.SocketTimeoutException
import java.security.SecureRandom
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.min

/** A short, explicitly Wi-Fi-bound discovery. It never broadcasts pairing credentials. */
class PairingDiscovery(context: Context, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val connectivity = context.applicationContext
        .getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
    private val main = Handler(Looper.getMainLooper())
    private val channel = MethodChannel(messenger, "class_notes/pairing_discovery")
    private val executor = Executors.newFixedThreadPool(2) { task ->
        Thread(task, "pairing-discovery").apply { isDaemon = true }
    }
    private val requests = ConcurrentHashMap<String, Request>()
    private val lifecycleLock = Any()
    private var disposed = false

    init { channel.setMethodCallHandler(this) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "discover" && call.method != "cancel") {
            result.notImplemented()
            return
        }
        val id = (call.arguments as? Map<*, *>)?.get("request_id") as? String
        if (id.isNullOrBlank() || id.length > 128) {
            result.error("BAD_REQUEST", "缺少有效的发现请求标识", null)
            return
        }
        if (call.method == "cancel") {
            requests[id]?.let { request ->
                request.cancel()
                finish(request, outcome("unavailable", request.gateways, error = "已取消发现", cancelled = true))
            }
            result.success(null)
            return
        }
        val request = Request(id, result)
        synchronized(lifecycleLock) {
            if (disposed) {
                result.success(outcome("unavailable", error = "发现服务已关闭"))
                return
            }
            if (requests.containsKey(id) || requests.size >= 2) {
                result.error("BUSY", "已有发现请求正在进行，请稍后重试", null)
                return
            }
            requests[id] = request
            executor.execute {
                val value = try {
                    discover(request)
                } catch (_: SecurityException) {
                    outcome("unavailable", request.gateways, error = "无法访问 Wi-Fi 网络，请检查应用的网络权限")
                } catch (_: Exception) {
                    outcome("unavailable", request.gateways, error = "Wi-Fi 发现暂时不可用，请检查连接后重试")
                } finally {
                    request.closeSockets()
                }
                finish(request, value)
            }
        }
    }

    fun dispose() {
        synchronized(lifecycleLock) {
            if (disposed) return
            disposed = true
            channel.setMethodCallHandler(null)
            requests.values.toList().forEach { request ->
                request.cancel()
                finish(request, outcome("unavailable", request.gateways, error = "发现服务已关闭", cancelled = true))
            }
            executor.shutdownNow()
        }
    }

    private fun finish(request: Request, value: Map<String, Any>) {
        if (!request.completed.compareAndSet(false, true)) return
        requests.remove(request.id, request)
        main.post { request.result.success(value) }
    }

    @Suppress("DEPRECATION") // A single bounded snapshot, including Wi-Fi without Internet validation.
    private fun discover(request: Request): Map<String, Any> {
        val manager = connectivity ?: return outcome("unavailable", error = "无法读取 Wi-Fi 网络状态")
        val links = mutableListOf<WifiLink>()
        val gateways = linkedSetOf<Inet4Address>()
        var hasWifi = false
        for (network in manager.allNetworks) {
            if (request.cancelled.get()) return cancelledOutcome(request)
            val capabilities = manager.getNetworkCapabilities(network) ?: continue
            if (!capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) continue
            hasWifi = true
            val properties = manager.getLinkProperties(network) ?: continue
            val localGateways = properties.routes.mapNotNull { it.gateway as? Inet4Address }
                .filter { isUsableIpv4(it) }.distinct()
            gateways.addAll(localGateways)
            request.gateways = gateways.map { it.hostAddress ?: "" }.filter { it.isNotEmpty() }
            for (link in properties.linkAddresses) {
                val address = link.address as? Inet4Address ?: continue
                if (isUsableIpv4(address) && links.size < MAX_LINKS) {
                    links.add(WifiLink(network, address, link.prefixLength, localGateways))
                }
            }
        }
        if (!hasWifi) return outcome("no_wifi", error = "未连接 Wi-Fi，请连接电脑所在网络或电脑热点")
        if (links.isEmpty()) return outcome("unavailable", request.gateways, error = "当前 Wi-Fi 没有可用的 IPv4 地址")

        val endpoints = mutableListOf<Endpoint>()
        for (link in links) {
            if (request.cancelled.get()) return cancelledOutcome(request)
            val socket = DatagramSocket(null)
            if (!request.addSocket(socket)) return cancelledOutcome(request)
            try {
                socket.broadcast = true
                socket.bind(InetSocketAddress(link.address, 0))
                // Keep discovery on this Wi-Fi even when mobile data is the default network.
                link.network.bindSocket(socket)
                val targets = linkedSetOf<Inet4Address>()
                broadcastAddress(link.address, link.prefix)?.let { targets.add(it) }
                targets.add(InetAddress.getByAddress(byteArrayOf(-1, -1, -1, -1)) as Inet4Address)
                targets.addAll(link.gateways)
                endpoints.add(Endpoint(socket, targets))
            } catch (error: SecurityException) {
                socket.close()
                throw error
            } catch (_: Exception) {
                socket.close()
            }
        }
        if (endpoints.isEmpty()) return outcome("unavailable", request.gateways, error = "当前 Wi-Fi 无法发送发现请求，可尝试手动连接")

        val nonce = newNonce()
        val bytes = JSONObject().put("app", APP).put("version", 1).put("nonce", nonce)
            .toString().toByteArray(Charsets.UTF_8)
        val servers = linkedMapOf<String, Map<String, Any>>()
        val started = SystemClock.elapsedRealtime()
        val deadline = started + DISCOVERY_MS
        var rounds = 0
        var packets = 0
        var sent = false
        while (!request.cancelled.get() && SystemClock.elapsedRealtime() < deadline && packets < MAX_PACKETS && servers.size < MAX_SERVERS) {
            val now = SystemClock.elapsedRealtime()
            if (rounds < 2 && now >= started + rounds * (DISCOVERY_MS / 2)) {
                for (endpoint in endpoints) for (target in endpoint.targets) {
                    if (request.cancelled.get()) return cancelledOutcome(request)
                    try {
                        endpoint.socket.send(DatagramPacket(bytes, bytes.size, target, PORT))
                        sent = true
                    } catch (error: SecurityException) {
                        throw error
                    } catch (_: Exception) {
                        // Another destination/interface may still work; keep the Wi-Fi gateways.
                    }
                }
                rounds++
            }
            for (endpoint in endpoints) {
                val remaining = deadline - SystemClock.elapsedRealtime()
                if (request.cancelled.get() || remaining <= 0 || packets >= MAX_PACKETS || servers.size >= MAX_SERVERS) break
                if (endpoint.socket.isClosed) continue
                try {
                    endpoint.socket.soTimeout = min(80L, remaining).toInt().coerceAtLeast(1)
                    // One extra byte distinguishes oversized/truncated messages from valid packets.
                    val buffer = ByteArray(MAX_PACKET_BYTES + 1)
                    val packet = DatagramPacket(buffer, buffer.size)
                    endpoint.socket.receive(packet)
                    packets++
                    val server = parseResponse(packet.data, packet.offset, packet.length, packet.address, packet.port, nonce)
                    if (server != null) servers["${server["server_id"]}@${server["host"]}:${server["port"]}"] = server
                } catch (_: SocketTimeoutException) {
                    // A short timeout keeps cancellation and the second broadcast round responsive.
                } catch (error: SecurityException) {
                    throw error
                } catch (_: Exception) {
                    endpoint.socket.close()
                }
            }
            if (endpoints.all { it.socket.isClosed }) break
        }
        if (request.cancelled.get()) return cancelledOutcome(request)
        return if (sent && (servers.isNotEmpty() || endpoints.any { !it.socket.isClosed })) outcome("ok", request.gateways, servers.values.toList())
        else outcome("unavailable", request.gateways, error = "当前 Wi-Fi 无法发送发现请求，可尝试手动连接")
    }

    private fun cancelledOutcome(request: Request) = outcome("unavailable", request.gateways, error = "已取消发现", cancelled = true)

    private data class WifiLink(val network: Network, val address: Inet4Address, val prefix: Int, val gateways: List<Inet4Address>)
    private data class Endpoint(val socket: DatagramSocket, val targets: Set<Inet4Address>)
    private class Request(val id: String, val result: MethodChannel.Result) {
        val cancelled = AtomicBoolean(false)
        val completed = AtomicBoolean(false)
        @Volatile var gateways: List<String> = emptyList()
        private val sockets = mutableListOf<DatagramSocket>()
        fun addSocket(socket: DatagramSocket): Boolean = synchronized(sockets) {
            if (cancelled.get()) { socket.close(); false } else { sockets.add(socket); true }
        }
        fun cancel() { cancelled.set(true); closeSockets() }
        fun closeSockets() = synchronized(sockets) { sockets.forEach { it.close() }; sockets.clear() }
    }

    companion object {
        private const val APP = "class_notes_assistant"
        private const val PORT = 48137
        private const val DISCOVERY_MS = 2500L
        private const val MAX_PACKET_BYTES = 1024
        private const val MAX_PACKETS = 64
        private const val MAX_SERVERS = 8
        private const val MAX_LINKS = 8
        private val serverIdPattern = Regex("^[0-9a-fA-F]{16}$")
        private val random = SecureRandom()

        private fun outcome(status: String, gateways: List<String> = emptyList(), servers: List<Map<String, Any>> = emptyList(), error: String? = null, cancelled: Boolean = false): Map<String, Any> {
            val value = mutableMapOf<String, Any>("status" to status, "servers" to servers, "gateways" to gateways)
            if (error != null) value["error"] = error
            if (cancelled) value["cancelled"] = true
            return value
        }

        internal fun newNonce(): String {
            val bytes = ByteArray(16)
            random.nextBytes(bytes)
            return bytes.joinToString("") { "%02x".format(it.toInt() and 255) }
        }

        internal fun broadcastAddress(address: Inet4Address, prefix: Int): Inet4Address? {
            if (prefix !in 1..30) return null // /31 and /32 do not have a subnet broadcast.
            var ipv4 = 0L
            for (byte in address.address) ipv4 = (ipv4 shl 8) or (byte.toLong() and 255)
            val broadcast = ipv4 or ((1L shl (32 - prefix)) - 1)
            return InetAddress.getByAddress(ByteArray(4) { index -> (broadcast shr (24 - index * 8)).toByte() }) as Inet4Address
        }

        private fun isUsableIpv4(address: Inet4Address): Boolean =
            !address.isAnyLocalAddress && !address.isLoopbackAddress && !address.isMulticastAddress &&
                (address.address[0].toInt() and 255) in 1..223

        internal fun parseResponse(bytes: ByteArray, offset: Int, length: Int, source: InetAddress, sourcePort: Int, nonce: String): Map<String, Any>? {
            if (source !is Inet4Address || !isUsableIpv4(source) || sourcePort != PORT || length !in 1..MAX_PACKET_BYTES) return null
            return try {
                val json = JSONObject(String(bytes, offset, length, Charsets.UTF_8))
                if (json.opt("app") != APP || json.opt("nonce") != nonce || json.opt("version") != 1) return null
                val id = json.opt("server_id") as? String ?: return null
                val name = json.opt("name") as? String ?: return null
                val port = json.opt("port") as? Int ?: return null
                if (!serverIdPattern.matches(id) || name.length > 64 || name.any { it.isISOControl() } || port !in 1..65535) return null
                // The datagram source is authoritative; never trust a JSON host or URL.
                mapOf("host" to (source.hostAddress ?: return null), "port" to port, "server_id" to id.lowercase(), "name" to name)
            } catch (_: Exception) { null }
        }
    }
}
