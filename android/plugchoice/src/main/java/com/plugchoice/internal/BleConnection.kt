package com.plugchoice.internal

import org.json.JSONArray
import org.json.JSONObject
import java.util.Base64

/** A discovered GATT service, as plain data. */
internal data class GattService(val uuid: String, val characteristics: List<GattCharacteristic>)

/** A characteristic: its UUID and the Android `PROPERTY_*` bits. */
internal data class GattCharacteristic(val uuid: String, val properties: Int)

/** What [BleConnection] needs from a `BluetoothGatt`. Each call answers whether it started. */
internal interface GattLink {
    fun discoverServices(): Boolean

    fun requestMtu(mtu: Int): Boolean

    fun services(): List<GattService>

    fun read(service: String, characteristic: String): Boolean

    fun write(service: String, characteristic: String, value: ByteArray, withResponse: Boolean): Boolean

    /** Turns notifications on or off locally and writes [cccd] to the CCCD descriptor. */
    fun setNotifications(service: String, characteristic: String, enable: Boolean, cccd: ByteArray): CccdWrite

    /** Disconnects and releases the connection; no callbacks after this. */
    fun close()

    enum class CccdWrite { STARTED, NO_DESCRIPTOR, FAILED }
}

/**
 * One `ble.connect`ed device (PROTOCOL.md §11), over a [GattLink]: connecting, discovery and the
 * MTU within the connect timeout, then reads, writes and (un)subscribes through a [GattQueue]
 * (an operation that times out ends the connection with reason `timeout`), notifications as
 * `ble.notification` events, and `ble.disconnected` as the last event.
 *
 * The `on*` methods are the GATT callbacks (statuses as Android reports them). Main thread only.
 */
internal class BleConnection(
    val deviceId: String,
    private val scheduler: Scheduler,
    private val emit: (event: String, params: JSONObject) -> Unit,
    /** The connection is over (failed, disconnected or closed); the manager forgets it. */
    private val onClosed: (BleConnection) -> Unit,
) {
    private enum class State { NEW, CONNECTING, DISCOVERING, MTU, READY, CLOSED }

    private var state = State.NEW
    private var link: GattLink? = null
    private var requestedMtu = BleRequests.DEFAULT_MTU
    private var connectCallback: ((Result<JSONObject>) -> Unit)? = null
    private var connectTimer: Cancellable? = null
    private val queue = GattQueue(scheduler).apply {
        // The device may still answer, out of step: end the connection (as on iOS).
        onTimeout = { end("timeout", "a request got no answer within ${GattQueue.OPERATION_TIMEOUT_MS} ms") }
    }
    private var services: List<GattService> = emptyList()

    /** The ATT MTU: 23 until the device agreed to more. */
    var mtu: Int = DEFAULT_ATT_MTU
        private set

    val isReady: Boolean
        get() = state == State.READY

    /** Starts the flow on a link whose connection attempt was just made. */
    fun start(link: GattLink, timeoutMs: Long, mtu: Int, callback: (Result<JSONObject>) -> Unit) {
        check(state == State.NEW)
        this.link = link
        requestedMtu = mtu
        connectCallback = callback
        state = State.CONNECTING
        connectTimer = scheduler.schedule(timeoutMs) {
            failConnect(BridgeException(ErrorCode.TIMEOUT, "not connected and discovered within $timeoutMs ms"))
        }
    }

    /** `{ mtu, maxWriteLength, services }`, the answer to `ble.connect`. */
    fun stateJson(): JSONObject = JSONObject()
        .put("mtu", mtu)
        .put("maxWriteLength", maxWriteLength)
        .put(
            "services",
            JSONArray(
                services.map { service ->
                    JSONObject()
                        .put("uuid", service.uuid)
                        .put(
                            "characteristics",
                            JSONArray(
                                service.characteristics.map { characteristic ->
                                    JSONObject().put("uuid", characteristic.uuid).put("properties", JSONArray(propertyNames(characteristic.properties)))
                                },
                            ),
                        )
                },
            ),
        )

    /** The longest write without response. */
    val maxWriteLength: Int
        get() = mtu - ATT_HEADER_BYTES

    // GATT callbacks

    fun onConnectionStateChange(status: Int, connected: Boolean) {
        when {
            connected && state == State.CONNECTING -> {
                state = State.DISCOVERING
                if (link?.discoverServices() != true) failConnect(BridgeException(ErrorCode.GATT, "could not start service discovery"))
            }
            connected -> Unit
            state in CONNECTING_STATES ->
                failConnect(BridgeException(ErrorCode.GATT, "the device disconnected while connecting (status $status)"))
            state == State.READY -> end(disconnectReason(status), "status $status")
        }
    }

    fun onServicesDiscovered(status: Int) {
        if (state != State.DISCOVERING) return
        if (status != GATT_SUCCESS) {
            failConnect(BridgeException(ErrorCode.GATT, "service discovery failed (status $status)"))
            return
        }
        services = link?.services().orEmpty()
        state = State.MTU
        if (link?.requestMtu(requestedMtu) != true) ready()
    }

    fun onMtuChanged(mtu: Int, status: Int) {
        // Also unasked: Android 14 negotiates 517 by itself when connecting.
        if (status == GATT_SUCCESS && mtu >= DEFAULT_ATT_MTU) this.mtu = mtu
        if (state == State.MTU) ready()
    }

    fun onRead(service: String, characteristic: String, value: ByteArray, status: Int) {
        queue.complete(
            key("read", service, characteristic),
            if (status == GATT_SUCCESS) Result.success(JSONObject().put("value", Base64.getEncoder().encodeToString(value))) else gattFailure("read", status),
        )
    }

    fun onWrite(service: String, characteristic: String, status: Int) {
        queue.complete(key("write", service, characteristic), if (status == GATT_SUCCESS) Result.success(JSONObject()) else gattFailure("write", status))
    }

    fun onDescriptorWrite(service: String, characteristic: String, status: Int) {
        queue.complete(key("cccd", service, characteristic), if (status == GATT_SUCCESS) Result.success(JSONObject()) else gattFailure("subscription", status))
    }

    fun onChanged(service: String, characteristic: String, value: ByteArray) {
        if (state != State.READY) return
        emit(
            "ble.notification",
            JSONObject()
                .put("deviceId", deviceId)
                .put("service", service)
                .put("characteristic", characteristic)
                .put("value", Base64.getEncoder().encodeToString(value)),
        )
    }

    // Requests

    fun read(service: String, characteristic: String, callback: (Result<JSONObject>) -> Unit) {
        requireProperty(service, characteristic, PROPERTY_READ, "read")
        queue.enqueue(key("read", service, characteristic), {
            if (!link().read(service, characteristic)) throw BridgeException(ErrorCode.GATT, "could not start the read")
            null
        }, callback)
    }

    fun write(service: String, characteristic: String, value: ByteArray, withResponse: Boolean, callback: (Result<JSONObject>) -> Unit) {
        if (withResponse) {
            requireProperty(service, characteristic, PROPERTY_WRITE, "write")
        } else {
            requireProperty(service, characteristic, PROPERTY_WRITE_NO_RESPONSE, "writeWithoutResponse")
            if (value.size > maxWriteLength) {
                throw BridgeException.invalidParams("a write without response takes at most maxWriteLength ($maxWriteLength) bytes")
            }
        }
        queue.enqueue(key("write", service, characteristic), {
            if (!link().write(service, characteristic, value, withResponse)) throw BridgeException(ErrorCode.GATT, "could not start the write")
            null
        }, callback)
    }

    /** Notifications, or indications when the characteristic has only those; answers once the device confirmed. */
    fun subscribe(service: String, characteristic: String, enable: Boolean, callback: (Result<JSONObject>) -> Unit) {
        val properties = requireCharacteristic(service, characteristic).properties
        if (properties and (PROPERTY_NOTIFY or PROPERTY_INDICATE) == 0) {
            throw BridgeException(ErrorCode.NOT_PERMITTED, "$characteristic has neither notify nor indicate")
        }
        val cccd = when {
            !enable -> DISABLE_VALUE
            properties and PROPERTY_NOTIFY != 0 -> ENABLE_NOTIFICATION_VALUE
            else -> ENABLE_INDICATION_VALUE
        }
        queue.enqueue(key("cccd", service, characteristic), {
            when (link().setNotifications(service, characteristic, enable, cccd)) {
                GattLink.CccdWrite.STARTED -> null
                // Nothing to confirm on the device: the local switch is all there is.
                GattLink.CccdWrite.NO_DESCRIPTOR -> Result.success(JSONObject())
                GattLink.CccdWrite.FAILED -> throw BridgeException(ErrorCode.GATT, "could not ${if (enable) "enable" else "disable"} notifications")
            }
        }, callback)
    }

    /** `ble.disconnect`: the last event is `ble.disconnected` with `requested`. */
    fun disconnect() {
        when {
            state in CONNECTING_STATES -> failConnect(BridgeException(ErrorCode.NOT_CONNECTED, "ble.disconnect while connecting"))
            state == State.READY -> end("requested", null)
        }
    }

    /** The page is gone: closes without events (whatever waits is answered, to nobody). */
    fun abandon() {
        if (state == State.CLOSED) return
        val wasConnecting = state in CONNECTING_STATES
        state = State.CLOSED
        connectTimer?.cancel()
        link?.close()
        val gone = BridgeException(ErrorCode.NOT_CONNECTED, "the page that connected went away")
        if (wasConnecting) connectCallback?.invoke(Result.failure(gone))
        connectCallback = null
        queue.failAll(gone)
        onClosed(this)
    }

    // Internals

    private fun ready() {
        state = State.READY
        connectTimer?.cancel()
        val callback = connectCallback
        connectCallback = null
        callback?.invoke(Result.success(stateJson()))
    }

    private fun failConnect(error: BridgeException) {
        if (state !in CONNECTING_STATES) return
        state = State.CLOSED
        connectTimer?.cancel()
        link?.close()
        val callback = connectCallback
        connectCallback = null
        callback?.invoke(Result.failure(error))
        onClosed(this)
    }

    private fun end(reason: String, message: String?) {
        if (state != State.READY) return
        state = State.CLOSED
        link?.close()
        queue.failAll(BridgeException(ErrorCode.NOT_CONNECTED, "the device is disconnected"))
        emit(
            "ble.disconnected",
            JSONObject().put("deviceId", deviceId).put("reason", reason).apply { if (message != null && reason != "requested") put("message", message) },
        )
        onClosed(this)
    }

    private fun link(): GattLink = link ?: throw BridgeException(ErrorCode.NOT_CONNECTED, "$deviceId is not connected")

    private fun requireCharacteristic(service: String, characteristic: String): GattCharacteristic {
        if (state != State.READY) throw BridgeException(ErrorCode.NOT_CONNECTED, "$deviceId is not connected")
        return services.firstOrNull { it.uuid == service }?.characteristics?.firstOrNull { it.uuid == characteristic }
            ?: throw BridgeException(ErrorCode.UNKNOWN_CHARACTERISTIC, "no characteristic $characteristic in service $service")
    }

    private fun requireProperty(service: String, characteristic: String, property: Int, name: String) {
        if (requireCharacteristic(service, characteristic).properties and property == 0) {
            throw BridgeException(ErrorCode.NOT_PERMITTED, "$characteristic does not allow $name")
        }
    }

    private fun gattFailure(what: String, status: Int): Result<JSONObject> =
        Result.failure(BridgeException(ErrorCode.GATT, "the device refused the $what (status $status)"))

    private fun key(kind: String, service: String, characteristic: String) = "$kind $service/$characteristic"

    companion object {
        const val DEFAULT_ATT_MTU = 23
        private const val ATT_HEADER_BYTES = 3
        const val GATT_SUCCESS = 0

        // BluetoothGattCharacteristic.PROPERTY_*
        const val PROPERTY_READ = 0x02
        const val PROPERTY_WRITE_NO_RESPONSE = 0x04
        const val PROPERTY_WRITE = 0x08
        const val PROPERTY_NOTIFY = 0x10
        const val PROPERTY_INDICATE = 0x20

        // BluetoothGattDescriptor.*_VALUE
        val ENABLE_NOTIFICATION_VALUE = byteArrayOf(0x01, 0x00)
        val ENABLE_INDICATION_VALUE = byteArrayOf(0x02, 0x00)
        val DISABLE_VALUE = byteArrayOf(0x00, 0x00)

        // HCI disconnect reasons Android reports as the status.
        private const val CONNECTION_TIMEOUT = 0x08
        private const val REMOTE_USER_TERMINATED = 0x13
        private const val REMOTE_LOW_RESOURCES = 0x14
        private const val REMOTE_POWER_OFF = 0x15

        private val CONNECTING_STATES = setOf(State.CONNECTING, State.DISCOVERING, State.MTU)

        /** `read`, `write`, `writeWithoutResponse`, `notify`, `indicate` (others aren't reported). */
        fun propertyNames(properties: Int): List<String> = buildList {
            if (properties and PROPERTY_READ != 0) add("read")
            if (properties and PROPERTY_WRITE != 0) add("write")
            if (properties and PROPERTY_WRITE_NO_RESPONSE != 0) add("writeWithoutResponse")
            if (properties and PROPERTY_NOTIFY != 0) add("notify")
            if (properties and PROPERTY_INDICATE != 0) add("indicate")
        }

        /** The `reason` of an unrequested `ble.disconnected`. */
        fun disconnectReason(status: Int): String = when (status) {
            GATT_SUCCESS, REMOTE_USER_TERMINATED, REMOTE_LOW_RESOURCES, REMOTE_POWER_OFF -> "remote"
            CONNECTION_TIMEOUT -> "timeout"
            else -> "error"
        }
    }
}
