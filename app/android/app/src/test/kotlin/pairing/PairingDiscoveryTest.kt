package pairing

import java.net.Inet4Address
import java.net.InetAddress
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [28])
class PairingDiscoveryTest {
    private val nonce = "0123456789abcdef0123456789abcdef"
    private val source = InetAddress.getByName("192.168.137.1")
    private fun response() = JSONObject().put("app", "class_notes_assistant").put("version", 1)
        .put("nonce", nonce).put("port", 8000).put("server_id", "aBcD0123456789ef").put("name", "课堂电脑")
    private fun parse(json: JSONObject, address: InetAddress = source, port: Int = 48137): Map<String, Any>? {
        val bytes = json.toString().toByteArray(Charsets.UTF_8)
        return PairingDiscovery.parseResponse(bytes, 0, bytes.size, address, port, nonce)
    }

    @Test fun broadcast_uses_real_prefix_instead_of_assuming_slash_24() {
        val address = InetAddress.getByName("192.168.137.17") as Inet4Address
        assertEquals("192.168.137.255", PairingDiscovery.broadcastAddress(address, 23)?.hostAddress)
        assertEquals("192.168.143.255", PairingDiscovery.broadcastAddress(address, 20)?.hostAddress)
        assertEquals("192.168.137.19", PairingDiscovery.broadcastAddress(address, 30)?.hostAddress)
        assertNull(PairingDiscovery.broadcastAddress(address, 31))
        assertNull(PairingDiscovery.broadcastAddress(address, 32))
    }

    @Test fun host_comes_from_packet_source_and_server_identity_is_normalized() {
        val server = parse(response().put("host", "https://untrusted.invalid"))!!
        assertEquals("192.168.137.1", server["host"])
        assertEquals("abcd0123456789ef", server["server_id"])
        assertEquals(8000, server["port"])
        assertEquals("课堂电脑", server["name"])
    }

    @Test fun unrelated_or_replayed_packets_are_rejected() {
        assertNull(parse(response().put("app", "other_app")))
        assertNull(parse(response().put("nonce", "fedcba9876543210fedcba9876543210")))
        assertNull(parse(response().put("version", 2)))
        assertNull(parse(response().put("version", "1")))
        assertNull(parse(response(), port = 48138))
        assertNull(parse(response(), address = InetAddress.getByName("::1")))
        assertNull(parse(response(), address = InetAddress.getByName("127.0.0.1")))
    }

    @Test fun invalid_ports_identity_and_overlong_or_control_character_names_are_rejected() {
        for (port in listOf<Any>(0, 65536, "8000", 8000.5)) assertNull(parse(response().put("port", port)))
        for (id in listOf("short", "g".repeat(16), "a".repeat(17))) assertNull(parse(response().put("server_id", id)))
        assertNull(parse(response().put("name", "名".repeat(65))))
        assertNull(parse(response().put("name", "电脑\n伪造条目")))
        assertNotNull(parse(response().put("name", "名".repeat(64))))
        assertNotNull(parse(response().put("port", 1)))
        assertNotNull(parse(response().put("port", 65535)))
    }

    @Test fun oversized_malformed_or_non_json_packets_are_rejected() {
        val tooLarge = ByteArray(1025) { 32 }
        assertNull(PairingDiscovery.parseResponse(tooLarge, 0, tooLarge.size, source, 48137, nonce))
        val malformed = "not a discovery response".toByteArray()
        assertNull(PairingDiscovery.parseResponse(malformed, 0, malformed.size, source, 48137, nonce))
        assertNull(PairingDiscovery.parseResponse(ByteArray(0), 0, 0, source, 48137, nonce))
    }

    @Test fun each_request_nonce_has_128_random_bits_encoded_as_32_hex_digits() {
        val nonces = (1..100).map { PairingDiscovery.newNonce() }
        assertTrue(nonces.all { it.matches(Regex("^[0-9a-f]{32}$")) })
        assertEquals(nonces.size, nonces.toSet().size)
    }
}
