package com.plugchoice.internal

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import androidx.core.content.ContextCompat
import org.json.JSONObject
import java.util.UUID

/**
 * `ble.*` (PROTOCOL.md §11) on Android: [android.bluetooth.le.BluetoothLeScanner] for
 * `ble.scan`, [BluetoothGatt] (LE transport) per connected device, behind [BleConnection].
 *
 * - Permissions: `BLUETOOTH_SCAN` (`neverForLocation`) and `BLUETOOTH_CONNECT` on Android 12+;
 *   precise location on 10 and 11, where location services must also be on to scan. Asked through
 *   the Link screen; every method but `ble.stopScan` and `ble.disconnect` checks first.
 * - A `deviceId` is the device's address, and must come from a scan on this page.
 * - At most [MAX_CONNECTIONS] connections, connecting ones included.
 * - The page going away stops the scan and closes every connection without events.
 *
 * Main thread only (GATT and scan callbacks are delivered on it).
 */
@SuppressLint("MissingPermission") // Checked at run time by ensureReady before every radio call.
internal class BleManager(
    private val host: BridgeHost,
    /** Sends an event to the page; safe to call from any thread. */
    private val emit: (event: String, params: JSONObject) -> Unit,
) {
    private val context = host.hostContext.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val scheduler = HandlerScheduler(main)
    private val adapter: BluetoothAdapter?
        get() = context.getSystemService(BluetoothManager::class.java)?.adapter

    private var scan: Scan? = null
    private val seen = HashMap<String, BluetoothDevice>()
    private val connections = HashMap<String, BleConnection>()

    // ble.ensurePermissions and the checks before every call

    /**
     * Asks for what Bluetooth needs and checks it is on: `unavailable` (no Bluetooth LE, or the app
     * removed the library's Bluetooth permissions), `bluetoothPermissionDenied`, `bluetoothOff`,
     * and when [scanning] on Android 10–11 `locationServicesOff`.
     */
    suspend fun ensureReady(scanning: Boolean) {
        if (!context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE) || adapter == null) {
            throw BridgeException(ErrorCode.UNAVAILABLE, "this device has no Bluetooth LE")
        }
        if (!Transports.bluetoothAvailable(context)) {
            throw BridgeException(ErrorCode.UNAVAILABLE, "the app's manifest lacks the Bluetooth permissions")
        }
        val missing = missingPermissions()
        if (missing.isNotEmpty()) {
            host.requestPermissions(missing.toTypedArray())
            if (missingPermissions().isNotEmpty()) {
                throw BridgeException(ErrorCode.BLUETOOTH_PERMISSION_DENIED, "not granted: ${missingPermissions().joinToString()}")
            }
        }
        if (adapter?.isEnabled != true) throw BridgeException(ErrorCode.BLUETOOTH_OFF, "Bluetooth is off")
        if (scanning && !Transports.usesNearbyDevicePermissions(context)) {
            val location = context.getSystemService(LocationManager::class.java)
            if (location != null && !location.isLocationEnabled) {
                throw BridgeException(ErrorCode.LOCATION_SERVICES_OFF, "location services are off; Android 10 and 11 need them to scan")
            }
        }
    }

    private fun missingPermissions(): List<String> =
        Transports.bluetoothRuntimePermissions(context).filter {
            ContextCompat.checkSelfPermission(context, it) != PackageManager.PERMISSION_GRANTED
        }

    // ble.scan / ble.stopScan

    fun scan(request: BleRequests.Scan, callback: (Result<JSONObject>) -> Unit) {
        if (scan != null) throw BridgeException(ErrorCode.BUSY, "a ble.scan is already running")
        val scanner = adapter?.bluetoothLeScanner ?: throw BridgeException(ErrorCode.BLUETOOTH_OFF, "Bluetooth is off")
        val started = Scan(request) { result ->
            scan = null
            callback(result)
        }
        scan = started
        started.start(scanner)
    }

    /** The running scan answers with what it found. */
    fun stopScan() {
        scan?.finish(null)
    }

    private inner class Scan(private val request: BleRequests.Scan, private val onFinished: (Result<JSONObject>) -> Unit) {
        private val results = BleScanResults(request.stopOnName)
        private var scanner: android.bluetooth.le.BluetoothLeScanner? = null
        private var timer: Cancellable? = null
        private var finished = false

        private val scanCallback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                main.post { add(result) }
            }

            override fun onBatchScanResults(results: MutableList<ScanResult>) {
                main.post { results.forEach(::add) }
            }

            override fun onScanFailed(errorCode: Int) {
                main.post {
                    val error = if (errorCode == SCAN_FAILED_ALREADY_STARTED) {
                        BridgeException(ErrorCode.BUSY, "a scan is already running")
                    } else {
                        BridgeException(ErrorCode.UNAVAILABLE, "the scan failed to start (code $errorCode)")
                    }
                    finish(error)
                }
            }
        }

        fun start(scanner: android.bluetooth.le.BluetoothLeScanner) {
            this.scanner = scanner
            val filters = request.services.map { ScanFilter.Builder().setServiceUuid(ParcelUuid.fromString(it)).build() }
            val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
            try {
                scanner.startScan(filters, settings, scanCallback)
            } catch (e: SecurityException) {
                finish(BridgeException(ErrorCode.BLUETOOTH_PERMISSION_DENIED, "scan refused: ${e.message}"))
                return
            } catch (e: IllegalStateException) {
                finish(BridgeException(ErrorCode.BLUETOOTH_OFF, "Bluetooth is off: ${e.message}"))
                return
            }
            if (!finished) timer = scheduler.schedule(request.timeoutMs) { finish(null) }
        }

        private fun add(result: ScanResult) {
            if (finished) return
            val device = result.device
            val deviceId = device.address
            seen[deviceId] = device
            val cachedName = try {
                device.name
            } catch (_: SecurityException) {
                null
            }
            val advertisement = BleAdvertisement.parse(result.scanRecord?.bytes)
            if (results.add(deviceId, cachedName, result.rssi, advertisement, result.isConnectable)) finish(null)
        }

        /** Answers with what was found, or [error]. */
        fun finish(error: BridgeException?) {
            if (finished) return
            finished = true
            timer?.cancel()
            try {
                if (adapter?.isEnabled == true) scanner?.stopScan(scanCallback)
            } catch (e: RuntimeException) {
                Log.w(TAG, "ble.scan: stopScan failed: $e")
            }
            onFinished(if (error != null) Result.failure(error) else Result.success(JSONObject().put("devices", results.toJson())))
        }
    }

    // ble.connect / ble.disconnect

    fun connect(request: BleRequests.Connect, callback: (Result<JSONObject>) -> Unit) {
        connections[request.deviceId]?.let { existing ->
            if (existing.isReady) {
                callback(Result.success(existing.stateJson()))
                return
            }
            throw BridgeException(ErrorCode.BUSY, "${request.deviceId} is already connecting")
        }
        val device = seen[request.deviceId]
            ?: throw BridgeException(ErrorCode.UNKNOWN_DEVICE, "${request.deviceId} was not found by a ble.scan on this page")
        if (connections.size >= MAX_CONNECTIONS) {
            throw BridgeException(ErrorCode.TOO_MANY_CONNECTIONS, "at most $MAX_CONNECTIONS devices can be connected")
        }
        val connection = BleConnection(request.deviceId, scheduler, emit) { closed -> connections.remove(closed.deviceId, closed) }
        val gatt = try {
            device.connectGatt(context, false, GattCallback(connection), BluetoothDevice.TRANSPORT_LE, BluetoothDevice.PHY_LE_1M_MASK, main)
        } catch (e: SecurityException) {
            throw BridgeException(ErrorCode.BLUETOOTH_PERMISSION_DENIED, "connect refused: ${e.message}")
        } ?: throw BridgeException(ErrorCode.GATT, "could not start connecting to ${request.deviceId}")
        connections[request.deviceId] = connection
        connection.start(AndroidGattLink(gatt), request.timeoutMs, request.mtu, callback)
    }

    fun disconnect(deviceId: String) {
        connections[deviceId]?.disconnect()
    }

    /** The connected device [deviceId]: `notConnected` otherwise (`unknownDevice` if never seen). */
    fun connection(deviceId: String): BleConnection {
        connections[deviceId]?.takeIf { it.isReady }?.let { return it }
        if (deviceId !in seen) throw BridgeException(ErrorCode.UNKNOWN_DEVICE, "$deviceId was not found by a ble.scan on this page")
        throw BridgeException(ErrorCode.NOT_CONNECTED, "$deviceId is not connected")
    }

    /** The page is gone: the scan stops and every connection closes, without events. */
    fun onNewDocument() {
        scan?.finish(BridgeException(ErrorCode.NETWORK, "the page that started the scan went away"))
        for (connection in connections.values.toList()) connection.abandon()
        connections.clear()
        seen.clear()
    }

    fun dispose() = onNewDocument()

    /** GATT callbacks, delivered on the main thread (the handler given to `connectGatt`). */
    private class GattCallback(private val connection: BleConnection) : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) =
            connection.onConnectionStateChange(status, newState == BluetoothProfile.STATE_CONNECTED)

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) = connection.onServicesDiscovered(status)

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) = connection.onMtuChanged(mtu, status)

        override fun onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray, status: Int) =
            connection.onRead(characteristic.serviceUuid(), BleUuids.text(characteristic.uuid), value, status)

        @Deprecated("Before Android 13")
        @Suppress("DEPRECATION")
        override fun onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) return
            connection.onRead(characteristic.serviceUuid(), BleUuids.text(characteristic.uuid), characteristic.value ?: ByteArray(0), status)
        }

        override fun onCharacteristicWrite(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) =
            connection.onWrite(characteristic.serviceUuid(), BleUuids.text(characteristic.uuid), status)

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            val characteristic = descriptor.characteristic
            connection.onDescriptorWrite(characteristic.serviceUuid(), BleUuids.text(characteristic.uuid), status)
        }

        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) =
            connection.onChanged(characteristic.serviceUuid(), BleUuids.text(characteristic.uuid), value)

        @Deprecated("Before Android 13")
        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) return
            connection.onChanged(characteristic.serviceUuid(), BleUuids.text(characteristic.uuid), characteristic.value ?: ByteArray(0))
        }

        private fun BluetoothGattCharacteristic.serviceUuid(): String = BleUuids.text(service.uuid)
    }

    /** [GattLink] over a [BluetoothGatt]. */
    private class AndroidGattLink(private val gatt: BluetoothGatt) : GattLink {
        override fun discoverServices(): Boolean = guarded { gatt.discoverServices() }

        override fun requestMtu(mtu: Int): Boolean = guarded { gatt.requestMtu(mtu) }

        override fun services(): List<GattService> = gatt.services.map { service ->
            GattService(BleUuids.text(service.uuid), service.characteristics.map { GattCharacteristic(BleUuids.text(it.uuid), it.properties) })
        }

        private fun characteristic(service: String, characteristic: String): BluetoothGattCharacteristic? =
            gatt.getService(UUID.fromString(service))?.getCharacteristic(UUID.fromString(characteristic))

        override fun read(service: String, characteristic: String): Boolean = guarded {
            characteristic(service, characteristic)?.let(gatt::readCharacteristic) ?: false
        }

        override fun write(service: String, characteristic: String, value: ByteArray, withResponse: Boolean): Boolean = guarded {
            val target = characteristic(service, characteristic) ?: return@guarded false
            // With response, a value past the MTU goes as a long (prepared) write: Android does it.
            val type = if (withResponse) BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT else BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                gatt.writeCharacteristic(target, value, type) == BluetoothStatusCodes.SUCCESS
            } else {
                target.writeType = type
                @Suppress("DEPRECATION")
                target.value = value
                @Suppress("DEPRECATION")
                gatt.writeCharacteristic(target)
            }
        }

        override fun setNotifications(service: String, characteristic: String, enable: Boolean, cccd: ByteArray): GattLink.CccdWrite {
            val target = characteristic(service, characteristic) ?: return GattLink.CccdWrite.FAILED
            val started = guarded {
                if (!gatt.setCharacteristicNotification(target, enable)) return@guarded false
                val descriptor = target.getDescriptor(CCCD) ?: return GattLink.CccdWrite.NO_DESCRIPTOR
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    gatt.writeDescriptor(descriptor, cccd) == BluetoothStatusCodes.SUCCESS
                } else {
                    @Suppress("DEPRECATION")
                    descriptor.value = cccd
                    @Suppress("DEPRECATION")
                    gatt.writeDescriptor(descriptor)
                }
            }
            return if (started) GattLink.CccdWrite.STARTED else GattLink.CccdWrite.FAILED
        }

        override fun close() {
            guarded {
                gatt.disconnect()
                true
            }
            guarded {
                gatt.close()
                true
            }
        }

        /** A permission withdrawn meanwhile reads as "could not start". */
        private inline fun guarded(call: () -> Boolean): Boolean = try {
            call()
        } catch (_: SecurityException) {
            false
        }
    }

    companion object {
        const val MAX_CONNECTIONS = 8
        private const val TAG = "Plugchoice"

        /** The Client Characteristic Configuration Descriptor. */
        private val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }
}
