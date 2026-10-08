package com.plugchoice.internal

import com.plugchoice.Device
import com.plugchoice.LinkError
import com.plugchoice.LinkResult
import com.plugchoice.Plugchoice
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** The handshake's capabilities (PROTOCOL.md §5) and `session.close` (§6.1). */
class BridgeTest {

    private fun assertCode(code: String, body: () -> Unit) {
        try {
            body()
            fail("expected $code")
        } catch (e: BridgeException) {
            assertEquals(code, e.code)
        }
    }

    private fun json(vararg pairs: Pair<String, Any?>) = JSONObject().apply { for ((key, value) in pairs) put(key, value) }

    // hello

    @Test
    fun `the bridge is version 1`() {
        assertEquals(1, LinkBridge.BRIDGE_VERSION)
    }

    @Test
    fun `the SDK version is semver`() {
        // Not a fixed value: release-please bumps it.
        assertTrue(Plugchoice.SDK_VERSION, Regex("""^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$""").matches(Plugchoice.SDK_VERSION))
    }

    @Test
    fun `every capability, ble when the device and the app can do Bluetooth`() {
        assertEquals(
            listOf(
                "wifi.join", "http.request", "ws", "session.close", "camera.scanCode", "ui.closeRequest", "lan.address",
                "lan.discover", "http.session", "auth.clientSecret", "ble", "tcp", "udp", "trust.custom",
            ),
            LinkBridge.capabilities(bluetoothAvailable = true),
        )
        assertFalse("ble" in LinkBridge.capabilities(bluetoothAvailable = false))
        assertEquals(LinkBridge.capabilities(bluetoothAvailable = true) - "ble", LinkBridge.capabilities(bluetoothAvailable = false))
    }

    // session.close

    @Test
    fun `a close`() {
        val result = SessionClose.parse(
            json(
                "status" to "success",
                "sessionId" to "ls_1",
                "action" to "reconnect",
                "devices" to JSONArray().put(json("type" to "charger", "id" to "42")).put(json("type" to "meter", "id" to "m1")),
            ),
            openedAction = "reconnect",
        )
        assertEquals(
            LinkResult(LinkResult.Status.SUCCESS, "reconnect", "ls_1", listOf(Device("charger", "42"), Device("meter", "m1"))),
            result,
        )
    }

    @Test
    fun `only devices are read`() {
        // chargerIds is no part of the protocol: ignored like any unknown field.
        val result = SessionClose.parse(
            json("status" to "success", "action" to "setup", "chargerIds" to JSONArray(listOf("1"))),
            openedAction = "add",
        )
        assertEquals("setup", result.action)
        assertTrue(result.devices.isEmpty())
    }

    @Test
    fun `without an action the opened one`() {
        val result = SessionClose.parse(json("status" to "cancelled"), openedAction = "reconnect")
        assertEquals(LinkResult(LinkResult.Status.CANCELLED, "reconnect"), result)
        assertNull(result.sessionId)
        assertEquals("reconnect", SessionClose.parse(json("status" to "cancelled", "action" to ""), "reconnect").action)
    }

    @Test
    fun `an empty sessionId is none`() {
        assertNull(SessionClose.parse(json("status" to "cancelled", "sessionId" to "", "devices" to JSONArray()), "add").sessionId)
    }

    @Test
    fun `errors from the page`() {
        val result = SessionClose.parse(
            json("status" to "error", "action" to "add", "devices" to JSONArray(), "error" to json("code" to "chargerOffline", "message" to "gone")),
            openedAction = "add",
        )
        assertEquals(LinkError("chargerOffline", "gone"), result.error)
        assertEquals(LinkError("chargerOffline"), SessionClose.parse(json("status" to "error", "error" to json("code" to "chargerOffline")), "add").error)
        // A message outside `error` is no part of the protocol.
        assertNull(SessionClose.parse(json("status" to "error", "message" to "boom"), "add").error)
    }

    @Test
    fun `bad close params`() {
        for (bad in listOf(
            json(),
            json("status" to "done"),
            json("status" to 1),
            json("status" to "success", "devices" to "42"),
            json("status" to "success", "devices" to JSONArray().put("42")),
            json("status" to "success", "devices" to JSONArray().put(json("type" to "charger"))),
            json("status" to "success", "devices" to JSONArray().put(json("type" to "", "id" to "42"))),
            json("status" to "success", "devices" to JSONArray().put(json("type" to "charger", "id" to 42))),
            json("status" to "success", "action" to 3),
            json("status" to "error", "error" to json("message" to "no code")),
            json("status" to "error", "error" to json("code" to "x", "message" to 1)),
            json("status" to "error", "error" to "x"),
            json("status" to "success", "sessionId" to 5),
        )) {
            assertCode(ErrorCode.INVALID_PARAMS) { SessionClose.parse(bad, "add") }
        }
    }
}
