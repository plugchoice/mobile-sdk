package com.plugchoice.internal

import com.plugchoice.Device
import com.plugchoice.LinkError
import com.plugchoice.LinkResult
import org.json.JSONArray
import org.json.JSONObject

/** `session.close` params as the host app's [LinkResult] (PROTOCOL.md §6.1). */
internal object SessionClose {
    /**
     * `{ status, sessionId?, action?, devices?: [{ type, id }], error?: { code, message? } }`.
     * Without an `action`, the action the screen was opened with ([openedAction]). An empty
     * `sessionId` is none.
     */
    fun parse(params: JSONObject, openedAction: String): LinkResult {
        val status = LinkResult.Status.fromValue(params.optStringOrNull("status"))
            ?: throw BridgeException.invalidParams("status must be success, cancelled or error")
        val sessionId = params.optStringOrNull("sessionId")?.takeIf { it.isNotEmpty() }
        val action = params.optStringOrNull("action")?.takeIf { it.isNotEmpty() } ?: openedAction
        val devices = devices(params.opt("devices"))
        val error = params.optObjectOrNull("error")?.let { LinkError(it.requireString("code"), it.optStringOrNull("message")) }
        return LinkResult(status, action, sessionId, devices, error)
    }

    private fun devices(value: Any?): List<Device> = when (value) {
        null, JSONObject.NULL -> emptyList()
        is JSONArray -> List(value.length()) { i ->
            val device = value.opt(i) as? JSONObject
                ?: throw BridgeException.invalidParams("devices[$i] must be an object")
            Device(
                device.optStringOrNull("type")?.takeIf { it.isNotEmpty() }
                    ?: throw BridgeException.invalidParams("devices[$i].type must be a non-empty string"),
                device.optStringOrNull("id")?.takeIf { it.isNotEmpty() }
                    ?: throw BridgeException.invalidParams("devices[$i].id must be a non-empty string"),
            )
        }
        else -> throw BridgeException.invalidParams("devices must be an array")
    }
}
