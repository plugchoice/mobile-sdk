package com.plugchoice.internal

import org.json.JSONArray
import org.json.JSONObject

/** Error codes from `bridge/PROTOCOL.md`. */
internal object ErrorCode {
    // Generic, any method.
    const val UNSUPPORTED_METHOD = "unsupportedMethod"
    const val INVALID_PARAMS = "invalidParams"
    const val INTERNAL = "internal"

    // wifi.*
    const val USER_DENIED = "userDenied"
    const val INVALID_PASSPHRASE = "invalidPassphrase"
    const val DID_NOT_FIND_NETWORK = "didNotFindNetwork"
    const val UNABLE_TO_CONNECT = "unableToConnect"
    const val TIMEOUT_OCCURRED = "timeoutOccurred"
    const val LOCATION_PERMISSION_DENIED = "locationPermissionDenied"
    const val LOCATION_SERVICES_OFF = "locationServicesOff"
    const val UNAVAILABLE_FOR_OS_VERSION = "unavailableForOSVersion"

    // http.* / ws.*
    const val FORBIDDEN_HOST = "forbiddenHost"
    const val NETWORK = "network"
    const val TIMEOUT = "timeout"
    const val CANCELLED = "cancelled"

    // camera.scanCode
    const val USER_CANCELLED = "userCancelled"
    const val CAMERA_PERMISSION_DENIED = "cameraPermissionDenied"
    const val UNAVAILABLE = "unavailable"

    // lan.*, http.session.*, tcp.*, udp.exchange
    const val BUSY = "busy"
    const val LOCAL_NETWORK_DENIED = "localNetworkDenied"
    const val UNKNOWN_SESSION = "unknownSession"
    const val TOO_MANY_SESSIONS = "tooManySessions"
    const val TLS = "tls"

    // auth.clientSecret
    const val CLIENT_SECRET_UNAVAILABLE = "clientSecretUnavailable"

    // tcp.*
    const val UNKNOWN_SOCKET = "unknownSocket"
    const val TOO_MANY_SOCKETS = "tooManySockets"

    // ble.*
    const val BLUETOOTH_OFF = "bluetoothOff"
    const val BLUETOOTH_PERMISSION_DENIED = "bluetoothPermissionDenied"
    const val UNKNOWN_DEVICE = "unknownDevice"
    const val NOT_CONNECTED = "notConnected"
    const val UNKNOWN_CHARACTERISTIC = "unknownCharacteristic"
    const val NOT_PERMITTED = "notPermitted"
    const val TOO_MANY_CONNECTIONS = "tooManyConnections"
    const val GATT = "gatt"
}

/**
 * A request failed with a protocol error [code]; the message is free text for logs. [details]
 * (optional) goes to the page as `error.details`, e.g. a `tls` error's `{ presentedFingerprint }`
 * (PROTOCOL.md §4).
 */
internal class BridgeException(
    val code: String,
    message: String,
    val details: JSONObject? = null,
) : Exception(message) {
    companion object {
        fun invalidParams(message: String) = BridgeException(ErrorCode.INVALID_PARAMS, message)
    }
}

// Strict readers for request params. Anything off-contract is `invalidParams`.

internal fun JSONObject.requireString(name: String, allowEmpty: Boolean = false): String {
    val value = opt(name)
    if (value !is String || (!allowEmpty && value.isEmpty())) {
        throw BridgeException.invalidParams("$name must be a ${if (allowEmpty) "" else "non-empty "}string")
    }
    return value
}

internal fun JSONObject.optStringOrNull(name: String): String? = when (val value = opt(name)) {
    null, JSONObject.NULL -> null
    is String -> value
    else -> throw BridgeException.invalidParams("$name must be a string")
}

/** A `string[]`; empty when absent. */
internal fun JSONObject.optStringList(name: String): List<String> = when (val value = opt(name)) {
    null, JSONObject.NULL -> emptyList()
    is JSONArray -> List(value.length()) { i ->
        value.opt(i) as? String ?: throw BridgeException.invalidParams("$name[$i] must be a string")
    }
    else -> throw BridgeException.invalidParams("$name must be an array of strings")
}

internal fun JSONObject.optObjectOrNull(name: String): JSONObject? = when (val value = opt(name)) {
    null, JSONObject.NULL -> null
    is JSONObject -> value
    else -> throw BridgeException.invalidParams("$name must be an object")
}

internal fun JSONObject.requireBoolean(name: String): Boolean =
    opt(name) as? Boolean ?: throw BridgeException.invalidParams("$name must be a boolean")

/** A required positive number of milliseconds, capped to Int range. */
internal fun JSONObject.requireTimeoutMs(name: String): Long {
    val value = opt(name)
    if (value == null || value == JSONObject.NULL) throw BridgeException.invalidParams("$name is required")
    return optTimeoutMs(name, 0)
}

/** A whole number in [range], [default] when absent. */
internal fun JSONObject.optWholeNumber(name: String, range: IntRange, default: Int): Int = when (val value = opt(name)) {
    null, JSONObject.NULL -> default
    is Number -> {
        val number = value.toDouble()
        if (number != Math.rint(number) || number < range.first || number > range.last) {
            throw BridgeException.invalidParams("$name must be a whole number from ${range.first} to ${range.last}")
        }
        number.toInt()
    }
    else -> throw BridgeException.invalidParams("$name must be a number")
}

/** A required, non-empty `string[]`. */
internal fun JSONObject.requireStringList(name: String): List<String> {
    if (opt(name) !is JSONArray) throw BridgeException.invalidParams("$name must be an array of strings")
    return optStringList(name).ifEmpty { throw BridgeException.invalidParams("$name must not be empty") }
}

/** A positive number of milliseconds (rounded up), [default] when absent, capped to Int range. */
internal fun JSONObject.optTimeoutMs(name: String, default: Long): Long = when (val value = opt(name)) {
    null, JSONObject.NULL -> default
    is Number -> {
        val ms = value.toDouble()
        if (ms.isNaN() || ms <= 0) throw BridgeException.invalidParams("$name must be a positive number")
        Math.ceil(ms.coerceAtMost(Int.MAX_VALUE.toDouble())).toLong()
    }
    else -> throw BridgeException.invalidParams("$name must be a number")
}

/**
 * An optional positive number of milliseconds, [default] when absent, clamped to [range] (any
 * positive value is accepted: the range keeps a page from waiting forever or giving a call no chance).
 */
internal fun JSONObject.optClampedTimeoutMs(name: String, default: Long, range: LongRange): Long = when (val value = opt(name)) {
    null, JSONObject.NULL -> default
    is Number -> {
        val ms = value.toDouble()
        if (ms.isNaN() || ms <= 0) throw BridgeException.invalidParams("$name must be a positive number")
        Math.ceil(ms.coerceAtMost(range.last.toDouble())).toLong().coerceIn(range)
    }
    else -> throw BridgeException.invalidParams("$name must be a number")
}

/** A required positive number of milliseconds, clamped to [range]. */
internal fun JSONObject.requireClampedTimeoutMs(name: String, range: LongRange): Long {
    if (opt(name) == null || opt(name) == JSONObject.NULL) throw BridgeException.invalidParams("$name is required")
    return optClampedTimeoutMs(name, range.first, range)
}

/** A required whole number in [range]. */
internal fun JSONObject.requireWholeNumber(name: String, range: IntRange): Int {
    if (opt(name) == null || opt(name) == JSONObject.NULL) throw BridgeException.invalidParams("$name is required")
    return optWholeNumber(name, range, range.first)
}

/** Standard base64 (padding optional) as bytes; `invalidParams` otherwise. */
internal fun JSONObject.requireBase64(name: String): ByteArray {
    val value = requireString(name, allowEmpty = true)
    return try {
        java.util.Base64.getDecoder().decode(value)
    } catch (_: IllegalArgumentException) {
        throw BridgeException.invalidParams("$name must be base64")
    }
}

/** A `Record<string, string>`; empty when absent. */
internal fun JSONObject.optStringMap(name: String): Map<String, String> = when (val value = opt(name)) {
    null, JSONObject.NULL -> emptyMap()
    is JSONObject -> buildMap {
        for (key in value.keys()) {
            put(key, value.opt(key) as? String ?: throw BridgeException.invalidParams("$name.$key must be a string"))
        }
    }
    else -> throw BridgeException.invalidParams("$name must be an object")
}

/** `headers` (absent: none): names are tokens, values visible ASCII, spaces and tabs (PROTOCOL.md §9.1). */
internal fun JSONObject.optHeaders(name: String = "headers"): Map<String, String> {
    val headers = optStringMap(name)
    for ((key, value) in headers) {
        if (!Http1.isValidHeaderName(key) || !Http1.isValidHeaderValue(value)) {
            throw BridgeException.invalidParams("$name.$key is not a valid header")
        }
    }
    return headers
}
