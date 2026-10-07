import CoreBluetooth
import Foundation

/// `ble.*` (PROTOCOL §11): Bluetooth LE as a GATT client, with
/// CoreBluetooth. The page decides what to look for and what to write.
///
/// - The central manager is created on the first `ble.*` call that needs
///   it, never at `hello`: creating it shows the permission prompt the first
///   time, and every call waits for the user's answer (no timeout of its
///   own). Without `NSBluetoothAlwaysUsageDescription` in the host's
///   Info.plist (iOS would end the app) every call answers `unavailable`.
/// - `ble.connect` needs a device from a scan on this page, connects and
///   discovers every service and characteristic within `timeoutMs`.
/// - Requests on one device run one at a time with a 10 s operation timeout
///   (`BLEOperationQueue`); a timeout disconnects the device (reason
///   `timeout`), since it may still answer, out of step.
/// - At most `maxConnections` connections, connecting ones included.
/// - Everything ends with the page (`pageDidChange`), without events.
@MainActor
final class BluetoothService: NSObject {
    typealias Emit = (_ event: String, _ params: JSONObject) -> Void

    static let maxConnections = 8
    static let operationTimeoutMs = 10_000
    /// `ble.scan` and `ble.connect` clamp `timeoutMs` to this.
    nonisolated static let timeoutRange = 1_000...60_000
    nonisolated static let maxValueBytes = 512

    struct ScanRequest {
        let services: [CBUUID]?
        let timeoutMs: Int
        let stopOnName: String?
    }

    struct CharacteristicRequest {
        let deviceId: String
        let service: CBUUID
        let characteristic: CBUUID
    }

    private let emit: Emit
    private var central: CBCentralManager?
    private var stateWaiters: [CheckedContinuation<Void, Never>] = []
    private var scan: Scan?
    /// Peripherals a scan on this page found, by `deviceId`.
    private var known: [String: CBPeripheral] = [:]
    /// Connecting and connected devices, by `deviceId`.
    private var devices: [String: BLEDevice] = [:]

    init(emit: @escaping Emit) {
        self.emit = emit
    }

    var connectionCount: Int { devices.count }

    // MARK: - State

    /// `ble.ensurePermissions`, and the check every other call makes first.
    func ensureReady() async throws {
        guard BluetoothSupport.hasUsageDescription else {
            throw BridgeError(code: "unavailable", message: "the host app's Info.plist has no NSBluetoothAlwaysUsageDescription")
        }
        let central = self.central ?? makeCentral()
        while central.state == .unknown || central.state == .resetting {
            await withCheckedContinuation { stateWaiters.append($0) }
            try Task.checkCancellation()
        }
        if let error = Self.stateError(central.state) { throw error }
    }

    private func makeCentral() -> CBCentralManager {
        // Main queue; no "turn on Bluetooth" alert of the system's: the page
        // says so itself (bluetoothOff).
        let central = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        self.central = central
        return central
    }

    nonisolated static func stateError(_ state: CBManagerState) -> BridgeError? {
        switch state {
        case .poweredOn:
            return nil
        case .poweredOff:
            return BridgeError(code: "bluetoothOff", message: "Bluetooth is off")
        case .unauthorized:
            return BridgeError(code: "bluetoothPermissionDenied", message: "the app may not use Bluetooth")
        case .unsupported:
            return BridgeError(code: "unavailable", message: "this device has no Bluetooth LE")
        default:
            return BridgeError(code: "unavailable", message: "Bluetooth is not ready")
        }
    }

    // MARK: - Scan

    func scan(_ request: ScanRequest) async throws -> JSONObject {
        try await ensureReady()
        guard scan == nil else {
            throw BridgeError(code: "busy", message: "a ble.scan is already running")
        }
        guard let central else { throw Self.stateError(.unknown)! }
        return try await withCheckedThrowingContinuation { continuation in
            let scan = Scan(stopOnName: request.stopOnName) { continuation.resume(with: $0) }
            self.scan = scan
            central.scanForPeripherals(withServices: request.services, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            scan.timer = DispatchScheduler().schedule(afterMs: request.timeoutMs) { [weak self, weak scan] in
                guard let self, let scan, self.scan === scan else { return }
                self.finishScan(.success(["devices": scan.results.json]))
            }
        }
    }

    /// `ble.stopScan`: the running scan answers with what it found.
    func stopScan() {
        guard let scan else { return }
        finishScan(.success(["devices": scan.results.json]))
    }

    private func finishScan(_ result: Result<JSONObject, BridgeError>) {
        guard let scan else { return }
        self.scan = nil
        scan.timer?.cancel()
        if central?.state == .poweredOn {
            central?.stopScan()
        }
        scan.completion(result)
    }

    // MARK: - Connect

    func connect(deviceId: String, timeoutMs: Int) async throws -> JSONObject {
        try await ensureReady()
        guard let central, let peripheral = known[deviceId] else {
            throw Self.unknownDevice(deviceId)
        }
        if let device = devices[deviceId] {
            guard device.isConnected else {
                throw BridgeError(code: "busy", message: "\(deviceId) is already connecting")
            }
            return device.connectionInfo
        }
        guard devices.count < Self.maxConnections else {
            throw BridgeError(code: "tooManyConnections", message: "at most \(Self.maxConnections) connections can be open")
        }
        let device = BLEDevice(deviceId: deviceId, peripheral: peripheral, operationTimeoutMs: Self.operationTimeoutMs)
        devices[deviceId] = device
        device.onNotification = { [weak self] params in
            self?.emit("ble.notification", params)
        }
        device.onOperationTimeout = { [weak self, weak device] in
            guard let self, let device else { return }
            self.disconnect(device, reason: "timeout", message: "a request got no answer within \(Self.operationTimeoutMs) ms")
        }
        device.onConnectFailed = { [weak self, weak device] error in
            guard let self, let device else { return }
            self.abandon(device, error)
        }
        return try await withCheckedThrowingContinuation { continuation in
            device.connecting = { result in continuation.resume(with: result) }
            device.connectTimer = DispatchScheduler().schedule(afterMs: timeoutMs) { [weak self, weak device] in
                guard let self, let device, !device.isConnected, self.devices[deviceId] === device else { return }
                self.abandon(device, BridgeError(code: "timeout", message: "not connected and discovered within \(timeoutMs) ms"))
            }
            central.connect(peripheral, options: nil)
        }
    }

    /// A connection attempt that didn't make it: answers `connect` and
    /// forgets the device, without events.
    private func abandon(_ device: BLEDevice, _ error: BridgeError) {
        guard devices[device.deviceId] === device else { return }
        devices.removeValue(forKey: device.deviceId)
        device.end(error)
        central?.cancelPeripheralConnection(device.peripheral)
    }

    /// `ble.disconnect`: idempotent. A connected device emits
    /// `ble.disconnected` with reason `requested` after the answer; one still
    /// connecting answers its `connect` with `notConnected`.
    func disconnect(deviceId: String) {
        guard let device = devices[deviceId] else { return }
        if device.isConnected {
            disconnect(device, reason: "requested", message: nil)
        } else {
            abandon(device, BridgeError(code: "notConnected", message: "disconnected before connecting finished"))
        }
    }

    /// Ends a connected device's connection, emits its last event, and
    /// answers what was waiting with `notConnected`.
    private func disconnect(_ device: BLEDevice, reason: String, message: String?) {
        guard devices[device.deviceId] === device else { return }
        devices.removeValue(forKey: device.deviceId)
        device.end(BridgeError(code: "notConnected", message: "the device disconnected"))
        central?.cancelPeripheralConnection(device.peripheral)
        var params: JSONObject = ["deviceId": device.deviceId, "reason": reason]
        if let message { params["message"] = message }
        emit("ble.disconnected", params)
    }

    // MARK: - GATT

    /// A connected device, or `unknownDevice` / `notConnected`.
    private func connectedDevice(_ deviceId: String) throws -> BLEDevice {
        if let device = devices[deviceId], device.isConnected {
            return device
        }
        if devices[deviceId] != nil || known[deviceId] != nil {
            throw BridgeError(code: "notConnected", message: "\(deviceId) is not connected")
        }
        throw Self.unknownDevice(deviceId)
    }

    func read(_ request: CharacteristicRequest) async throws -> JSONObject {
        try await ensureReady()
        return try await connectedDevice(request.deviceId).read(request)
    }

    func write(_ request: CharacteristicRequest, value: Data, withResponse: Bool) async throws -> JSONObject {
        try await ensureReady()
        return try await connectedDevice(request.deviceId).write(request, value: value, withResponse: withResponse)
    }

    func setNotify(_ enabled: Bool, _ request: CharacteristicRequest) async throws -> JSONObject {
        try await ensureReady()
        return try await connectedDevice(request.deviceId).setNotify(enabled, request)
    }

    // MARK: - Lifecycle

    /// A new page: every scan and connection ends without events, and the
    /// devices found are forgotten. Whatever was waiting is answered with
    /// `cancelled` (an answer the bridge drops).
    func pageDidChange() {
        let cancelled = BridgeError(code: "cancelled", message: "the page changed")
        finishScan(.failure(cancelled))
        let all = devices.values
        devices.removeAll()
        for device in all {
            device.end(cancelled)
            central?.cancelPeripheralConnection(device.peripheral)
        }
        known.removeAll()
        resumeStateWaiters()
    }

    /// The screen closes: as a page change, and the central manager goes.
    func shutDown() {
        pageDidChange()
        central?.delegate = nil
        central = nil
    }

    private func resumeStateWaiters() {
        let waiters = stateWaiters
        stateWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    nonisolated static func unknownDevice(_ deviceId: String) -> BridgeError {
        BridgeError(code: "unknownDevice", message: "\(deviceId) was not found by a ble.scan on this page")
    }

    /// One `ble.scan`.
    private final class Scan {
        var results: BLEScanResults
        let completion: (Result<JSONObject, BridgeError>) -> Void
        var timer: BLECancellable?

        init(stopOnName: String?, completion: @escaping (Result<JSONObject, BridgeError>) -> Void) {
            results = BLEScanResults(stopOnName: stopOnName)
            self.completion = completion
        }
    }
}

// MARK: - CBCentralManagerDelegate (main queue)

extension BluetoothService: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            guard central === self.central else { return }
            stateChanged(central.state)
        }
    }

    private func stateChanged(_ state: CBManagerState) {
        if state != .unknown, state != .resetting {
            resumeStateWaiters()
        }
        guard state != .poweredOn, let error = Self.stateError(state) else { return }
        // Bluetooth went off (or away): CoreBluetooth drops every connection
        // without telling each peripheral.
        if let scan {
            finishScan(.success(["devices": scan.results.json]))
        }
        let all = devices.values
        devices.removeAll()
        for device in all {
            if device.isConnected {
                device.end(error)
                emit("ble.disconnected", ["deviceId": device.deviceId, "reason": "error", "message": error.message])
            } else {
                device.end(error)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let deviceId = peripheral.identifier.uuidString
        let device = BLEScanDevice(deviceId: deviceId, cachedName: peripheral.name, rssi: RSSI.intValue, advertisementData: advertisementData)
        MainActor.assumeIsolated {
            guard central === self.central, let scan else { return }
            known[deviceId] = peripheral
            if scan.results.add(device) {
                finishScan(.success(["devices": scan.results.json]))
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            guard let device = devices[peripheral.identifier.uuidString], device.peripheral === peripheral else { return }
            device.didConnect()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            guard let device = devices[peripheral.identifier.uuidString], device.peripheral === peripheral else { return }
            abandon(device, BridgeError(code: "gatt", message: "could not connect: \(error?.localizedDescription ?? "no reason given")"))
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let reason = Self.disconnectReason(error)
        MainActor.assumeIsolated {
            guard let device = devices[peripheral.identifier.uuidString], device.peripheral === peripheral else { return }
            if device.isConnected {
                disconnect(device, reason: reason.reason, message: reason.message)
            } else {
                abandon(device, BridgeError(code: "gatt", message: "disconnected while connecting: \(reason.message ?? reason.reason)"))
            }
        }
    }

    /// `ble.disconnected`'s reason for a disconnection the page didn't ask
    /// for.
    nonisolated static func disconnectReason(_ error: Error?) -> (reason: String, message: String?) {
        guard let error else { return ("remote", nil) }
        let nsError = error as NSError
        if nsError.domain == CBErrorDomain {
            switch CBError.Code(rawValue: nsError.code) {
            case .peripheralDisconnected?:
                return ("remote", nsError.localizedDescription)
            case .connectionTimeout?:
                return ("timeout", nsError.localizedDescription)
            default:
                break
            }
        }
        return ("error", nsError.localizedDescription)
    }
}

/// One connecting or connected peripheral: discovery, the operation queue
/// and the peripheral's delegate callbacks.
@MainActor
final class BLEDevice: NSObject {
    let deviceId: String
    let peripheral: CBPeripheral
    private let queue: BLEOperationQueue
    /// Answers `ble.connect` once connected and discovered.
    var connecting: ((Result<JSONObject, BridgeError>) -> Void)?
    var connectTimer: BLECancellable?
    var onNotification: ((JSONObject) -> Void)?
    var onOperationTimeout: (() -> Void)?
    /// Discovery failed: the service abandons the attempt.
    var onConnectFailed: ((BridgeError) -> Void)?
    private(set) var isConnected = false
    private var servicesLeft = 0
    private var ended = false

    init(deviceId: String, peripheral: CBPeripheral, operationTimeoutMs: Int) {
        self.deviceId = deviceId
        self.peripheral = peripheral
        queue = BLEOperationQueue(timeoutMs: operationTimeoutMs)
        super.init()
        peripheral.delegate = self
        queue.onTimeout = { [weak self] in
            self?.onOperationTimeout?()
        }
    }

    /// Answers whatever waits with `error` and lets go of the peripheral.
    func end(_ error: BridgeError) {
        guard !ended else { return }
        ended = true
        connectTimer?.cancel()
        if let connecting {
            self.connecting = nil
            connecting(.failure(error))
        }
        queue.failAll(error)
        if peripheral.delegate === self {
            peripheral.delegate = nil
        }
    }

    // MARK: Connecting

    func didConnect() {
        peripheral.discoverServices(nil)
    }

    private func discovered(_ error: Error?) {
        guard connecting != nil else { return }
        if let error {
            onConnectFailed?(BridgeError(code: "gatt", message: "discovery failed: \(error.localizedDescription)"))
            return
        }
        guard servicesLeft == 0 else { return }
        connectTimer?.cancel()
        isConnected = true
        let connecting = self.connecting
        self.connecting = nil
        connecting?(.success(connectionInfo))
    }

    /// `ble.connect`'s answer: the MTU, the longest write without response,
    /// and every service with its characteristics.
    var connectionInfo: JSONObject {
        let maxWriteLength = peripheral.maximumWriteValueLength(for: .withoutResponse)
        let services: [JSONObject] = (peripheral.services ?? []).map { service in
            [
                "uuid": BLEUUID.string(service.uuid),
                "characteristics": (service.characteristics ?? []).map { characteristic in
                    ["uuid": BLEUUID.string(characteristic.uuid), "properties": BLEProperties.names(characteristic.properties)] as JSONObject
                },
            ]
        }
        return ["mtu": maxWriteLength + 3, "maxWriteLength": maxWriteLength, "services": services]
    }

    // MARK: Operations

    private func characteristic(_ request: BluetoothService.CharacteristicRequest) -> CBCharacteristic? {
        let service = BLEUUID.string(request.service)
        let characteristic = BLEUUID.string(request.characteristic)
        for candidate in peripheral.services ?? [] where BLEUUID.string(candidate.uuid) == service {
            if let match = candidate.characteristics?.first(where: { BLEUUID.string($0.uuid) == characteristic }) {
                return match
            }
        }
        return nil
    }

    private func perform(
        _ request: BluetoothService.CharacteristicRequest,
        _ body: @escaping (CBCharacteristic, BLEOperationQueue.Operation) -> Void
    ) async throws -> JSONObject {
        try await withCheckedThrowingContinuation { continuation in
            queue.enqueue(start: { [weak self] operation in
                guard let self else { return }
                guard let characteristic = self.characteristic(request) else {
                    self.queue.finish(operation, .failure(BridgeError(
                        code: "unknownCharacteristic",
                        message: "no characteristic \(BLEUUID.string(request.characteristic)) in service \(BLEUUID.string(request.service))"
                    )))
                    return
                }
                body(characteristic, operation)
            }, completion: { continuation.resume(with: $0) })
        }
    }

    func read(_ request: BluetoothService.CharacteristicRequest) async throws -> JSONObject {
        try await perform(request) { [weak self] characteristic, operation in
            guard let self else { return }
            guard characteristic.properties.contains(.read) else {
                self.queue.finish(operation, .failure(BridgeError(code: "notPermitted", message: "the characteristic can't be read")))
                return
            }
            operation.expectation = .read(ObjectIdentifier(characteristic))
            self.peripheral.readValue(for: characteristic)
        }
    }

    func write(_ request: BluetoothService.CharacteristicRequest, value: Data, withResponse: Bool) async throws -> JSONObject {
        try await perform(request) { [weak self] characteristic, operation in
            guard let self else { return }
            let maxWriteLength = self.peripheral.maximumWriteValueLength(for: .withoutResponse)
            if let refusal = BLEProperties.writeRefusal(byteCount: value.count, withResponse: withResponse, maxWriteLength: maxWriteLength, properties: characteristic.properties) {
                self.queue.finish(operation, .failure(refusal))
                return
            }
            if withResponse {
                // Longer than the MTU allows: CoreBluetooth makes it a long
                // (prepared) write.
                operation.expectation = .write(ObjectIdentifier(characteristic))
                self.peripheral.writeValue(value, for: characteristic, type: .withResponse)
                return
            }
            let send = { [weak self] in
                guard let self else { return }
                self.peripheral.writeValue(value, for: characteristic, type: .withoutResponse)
                self.queue.finish(operation, .success([:]))
            }
            if self.peripheral.canSendWriteWithoutResponse {
                send()
            } else {
                // Flow control: wait until CoreBluetooth takes another one.
                operation.expectation = .readyToWriteWithoutResponse
                operation.onReady = send
            }
        }
    }

    func setNotify(_ enabled: Bool, _ request: BluetoothService.CharacteristicRequest) async throws -> JSONObject {
        try await perform(request) { [weak self] characteristic, operation in
            guard let self else { return }
            guard characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) else {
                self.queue.finish(operation, .failure(BridgeError(code: "notPermitted", message: "the characteristic can't notify or indicate")))
                return
            }
            guard characteristic.isNotifying != enabled else {
                self.queue.finish(operation, .success([:]))
                return
            }
            // CoreBluetooth picks notifications, or indications when the
            // characteristic has only those.
            operation.expectation = .notificationState(ObjectIdentifier(characteristic))
            self.peripheral.setNotifyValue(enabled, for: characteristic)
        }
    }

    static func gattError(_ error: Error) -> BridgeError {
        let nsError = error as NSError
        return BridgeError(code: "gatt", message: "\(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))")
    }
}

// MARK: - CBPeripheralDelegate (main queue)

extension BLEDevice: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard connecting != nil else { return }
            if let error {
                discovered(error)
                return
            }
            let services = peripheral.services ?? []
            servicesLeft = services.count
            for service in services {
                peripheral.discoverCharacteristics(nil, for: service)
            }
            if services.isEmpty { discovered(nil) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            guard connecting != nil else { return }
            servicesLeft = max(0, servicesLeft - 1)
            discovered(error)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let value = characteristic.value ?? Data()
        let key = ObjectIdentifier(characteristic)
        let service = characteristic.service.map { BLEUUID.string($0.uuid) } ?? ""
        let uuid = BLEUUID.string(characteristic.uuid)
        MainActor.assumeIsolated {
            let answer: Result<JSONObject, BridgeError> = error.map { .failure(Self.gattError($0)) } ?? .success(["value": value.base64EncodedString()])
            // A read's answer, or else a notification or indication.
            guard !queue.finish(.read(key), answer), error == nil, isConnected else { return }
            onNotification?(["deviceId": deviceId, "service": service, "characteristic": uuid, "value": value.base64EncodedString()])
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let key = ObjectIdentifier(characteristic)
        MainActor.assumeIsolated {
            _ = queue.finish(.write(key), error.map { .failure(Self.gattError($0)) } ?? .success([:]))
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let key = ObjectIdentifier(characteristic)
        MainActor.assumeIsolated {
            _ = queue.finish(.notificationState(key), error.map { .failure(Self.gattError($0)) } ?? .success([:]))
        }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            queue.readyToWriteWithoutResponse()
        }
    }
}
