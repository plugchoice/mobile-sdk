package com.plugchoice.internal

import org.json.JSONArray
import org.json.JSONObject
import java.util.Base64
import java.util.Locale
import java.util.UUID

/**
 * Bluetooth UUIDs as the bridge speaks them (PROTOCOL.md §11): answered as full 128-bit
 * lower-case strings; params take the full form or the 16-bit short form (`a002`), and the 32-bit
 * one (`0000a002`), all expanded with the Bluetooth base UUID.
 */
internal object BleUuids {
    private const val BASE_SUFFIX = "-0000-1000-8000-00805f9b34fb"
    private val FULL = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
    private val SHORT = Regex("^([0-9a-f]{4}|[0-9a-f]{8})$")

    /** The full lower-case form of [value], or null when it isn't a UUID. */
    fun normalize(value: String): String? {
        val lower = value.lowercase(Locale.ROOT)
        return when {
            FULL.matches(lower) -> lower
            SHORT.matches(lower) -> lower.padStart(8, '0') + BASE_SUFFIX
            else -> null
        }
    }

    fun text(uuid: UUID): String = uuid.toString().lowercase(Locale.ROOT)

    /** A 16- or 32-bit UUID from its little-endian bytes in an advertisement. */
    fun fromShort(littleEndian: ByteArray): String {
        var value = 0L
        for (i in littleEndian.indices.reversed()) value = (value shl 8) or (littleEndian[i].toLong() and 0xff)
        return String.format(Locale.ROOT, "%08x", value) + BASE_SUFFIX
    }

    /** A 128-bit UUID from its little-endian bytes in an advertisement. */
    fun fromLong(littleEndian: ByteArray): String {
        val hex = littleEndian.reversed().joinToString("") { String.format(Locale.ROOT, "%02x", it.toInt() and 0xff) }
        return "${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}"
    }
}

/**
 * What one advertisement (with its scan response) says, parsed from the raw AD structures
 * (Bluetooth Core Supplement, part A). Plain JVM code, so it is unit tested directly.
 */
internal class BleAdvertisement(
    val localName: String?,
    val serviceUuids: List<String>,
    /** Company id and the data after it. */
    val manufacturerData: List<Pair<Int, ByteArray>>,
    val serviceData: List<Pair<String, ByteArray>>,
) {
    companion object {
        val EMPTY = BleAdvertisement(null, emptyList(), emptyList(), emptyList())

        /** Parses what it can; a malformed structure ends the parse with what came before it. */
        fun parse(bytes: ByteArray?): BleAdvertisement {
            if (bytes == null) return EMPTY
            var completeName: String? = null
            var shortName: String? = null
            val services = LinkedHashSet<String>()
            val manufacturer = mutableListOf<Pair<Int, ByteArray>>()
            val serviceData = mutableListOf<Pair<String, ByteArray>>()
            var i = 0
            while (i < bytes.size) {
                val length = bytes[i].toInt() and 0xff
                if (length == 0) break // the rest is padding
                if (i + 1 + length > bytes.size) break
                val type = bytes[i + 1].toInt() and 0xff
                val data = bytes.copyOfRange(i + 2, i + 1 + length)
                when (type) {
                    0x02, 0x03 -> data.chunked(2).forEach { services += BleUuids.fromShort(it) }
                    0x04, 0x05 -> data.chunked(4).forEach { services += BleUuids.fromShort(it) }
                    0x06, 0x07 -> data.chunked(16).forEach { services += BleUuids.fromLong(it) }
                    0x08 -> shortName = data.decodeToString()
                    0x09 -> completeName = data.decodeToString()
                    0x16 -> if (data.size >= 2) serviceData += BleUuids.fromShort(data.copyOfRange(0, 2)) to data.copyOfRange(2, data.size)
                    0x20 -> if (data.size >= 4) serviceData += BleUuids.fromShort(data.copyOfRange(0, 4)) to data.copyOfRange(4, data.size)
                    0x21 -> if (data.size >= 16) serviceData += BleUuids.fromLong(data.copyOfRange(0, 16)) to data.copyOfRange(16, data.size)
                    0xff -> if (data.size >= 2) {
                        val companyId = (data[0].toInt() and 0xff) or ((data[1].toInt() and 0xff) shl 8)
                        manufacturer += companyId to data.copyOfRange(2, data.size)
                    }
                }
                i += 1 + length
            }
            return BleAdvertisement(completeName ?: shortName, services.toList(), manufacturer, serviceData)
        }

        /** Whole chunks of [size] bytes (a trailing partial one is dropped). */
        private fun ByteArray.chunked(size: Int): List<ByteArray> =
            (0 until this.size / size).map { copyOfRange(it * size, it * size + size) }
    }
}

/**
 * The devices one `ble.scan` saw, once each with their latest RSSI and name (PROTOCOL.md §11),
 * in the order first seen. Advertised data accumulates: service UUIDs, and manufacturer and service
 * data per company id and UUID (the latest wins). Plain JVM code.
 */
internal class BleScanResults(private val stopOnName: String?) {
    private class Device(val deviceId: String) {
        var name: String? = null
        var rssi = 0
        val serviceUuids = LinkedHashSet<String>()
        val manufacturerData = LinkedHashMap<Int, ByteArray>()
        val serviceData = LinkedHashMap<String, ByteArray>()
        var connectable: Boolean? = null
    }

    private val devices = LinkedHashMap<String, Device>()

    val size: Int
        get() = devices.size

    /** Records a sighting. Returns true when the scan should stop: the name contains `stopOnName`. */
    fun add(deviceId: String, name: String?, rssi: Int, advertisement: BleAdvertisement, connectable: Boolean?): Boolean {
        val device = devices.getOrPut(deviceId) { Device(deviceId) }
        val seenName = advertisement.localName ?: name
        if (seenName != null) device.name = seenName
        device.rssi = rssi
        device.serviceUuids += advertisement.serviceUuids
        for ((companyId, data) in advertisement.manufacturerData) device.manufacturerData[companyId] = data
        for ((uuid, data) in advertisement.serviceData) device.serviceData[uuid] = data
        if (connectable != null) device.connectable = connectable
        return device.name?.let { DiscoveredServices.matches(it, stopOnName) } ?: false
    }

    /** `BleDevice[]` (§11). */
    fun toJson(): JSONArray {
        val list = JSONArray()
        val base64 = Base64.getEncoder()
        for (device in devices.values) {
            list.put(
                JSONObject()
                    .put("deviceId", device.deviceId)
                    .put("name", device.name ?: JSONObject.NULL)
                    .put("rssi", device.rssi)
                    .put("serviceUuids", JSONArray(device.serviceUuids.toList()))
                    .put(
                        "manufacturerData",
                        JSONArray(device.manufacturerData.map { (id, data) -> JSONObject().put("companyId", id).put("data", base64.encodeToString(data)) }),
                    )
                    .put(
                        "serviceData",
                        JSONArray(device.serviceData.map { (uuid, data) -> JSONObject().put("uuid", uuid).put("data", base64.encodeToString(data)) }),
                    )
                    .put("connectable", device.connectable ?: JSONObject.NULL),
            )
        }
        return list
    }
}

/** `ble.*` params (PROTOCOL.md §11), checked. */
internal object BleRequests {
    /** Scans and connects: `timeoutMs` clamped to this. */
    val TIMEOUT_RANGE = 1_000L..60_000L
    const val DEFAULT_MTU = 247
    val MTU_RANGE = 23..517

    /** Longest value of a write with response (a long write past the MTU). */
    const val MAX_VALUE_BYTES = 512

    class Scan(val services: List<String>, val timeoutMs: Long, val stopOnName: String?)

    class Connect(val deviceId: String, val timeoutMs: Long, val mtu: Int)

    class Characteristic(val deviceId: String, val service: String, val characteristic: String)

    class Write(val target: Characteristic, val value: ByteArray, val withResponse: Boolean)

    fun scan(params: JSONObject): Scan = Scan(
        services = params.optStringList("services").map { uuid(it, "services") }.distinct(),
        timeoutMs = params.requireClampedTimeoutMs("timeoutMs", TIMEOUT_RANGE),
        stopOnName = params.optStringOrNull("stopOnName")?.takeIf { it.isNotEmpty() },
    )

    fun connect(params: JSONObject): Connect = Connect(
        deviceId = params.requireString("deviceId"),
        timeoutMs = params.requireClampedTimeoutMs("timeoutMs", TIMEOUT_RANGE),
        mtu = params.optWholeNumber("mtu", MTU_RANGE, DEFAULT_MTU),
    )

    fun characteristic(params: JSONObject): Characteristic = Characteristic(
        deviceId = params.requireString("deviceId"),
        service = uuid(params.requireString("service"), "service"),
        characteristic = uuid(params.requireString("characteristic"), "characteristic"),
    )

    fun write(params: JSONObject): Write {
        val target = characteristic(params)
        val value = params.requireBase64("value")
        if (value.size > MAX_VALUE_BYTES) throw BridgeException.invalidParams("value is longer than $MAX_VALUE_BYTES bytes")
        return Write(target, value, params.requireBoolean("withResponse"))
    }

    private fun uuid(value: String, name: String): String =
        BleUuids.normalize(value) ?: throw BridgeException.invalidParams("$name: $value is not a Bluetooth UUID")
}
