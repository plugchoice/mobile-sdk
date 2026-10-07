import CoreBluetooth
import XCTest
@testable import PlugchoiceSDK

/// Bluetooth (PROTOCOL §11) without a radio: UUIDs, advertisements, scan
/// results, the per-device operation queue, params, and the guard that keeps
/// CoreBluetooth untouched without a usage description.
@MainActor
final class BluetoothTests: XCTestCase {
    // MARK: - UUIDs

    func testUUIDParams() throws {
        XCTAssertEqual(BLEUUID.normalized("a002"), "0000a002-0000-1000-8000-00805f9b34fb")
        XCTAssertEqual(BLEUUID.normalized("A002"), "0000a002-0000-1000-8000-00805f9b34fb")
        XCTAssertEqual(BLEUUID.normalized("0000A002"), "0000a002-0000-1000-8000-00805f9b34fb")
        XCTAssertEqual(BLEUUID.normalized("6E400001-B5A3-F393-E0A9-E50E24DCCA9E"), "6e400001-b5a3-f393-e0a9-e50e24dcca9e")
        for bad in ["", "a00", "a0021", "g002", "6E400001B5A3F393E0A9E50E24DCCA9E", "6E400001-B5A3-F393-E0A9-E50E24DCCA9", "6E400001-B5A3-F393-E0A9E-50E24DCCA9E", "+a02"] {
            XCTAssertNil(BLEUUID.normalized(bad), bad)
            XCTAssertThrowsCode("invalidParams") { _ = try BLEUUID.parse(bad, key: "service") }
        }
    }

    func testUUIDsAreAnsweredInFull() throws {
        XCTAssertEqual(BLEUUID.string(CBUUID(string: "180F")), "0000180f-0000-1000-8000-00805f9b34fb")
        XCTAssertEqual(BLEUUID.string(CBUUID(string: "0000180F-0000-1000-8000-00805F9B34FB")), "0000180f-0000-1000-8000-00805f9b34fb")
        XCTAssertEqual(BLEUUID.string(CBUUID(data: Data([0x12, 0x34, 0x56, 0x78]))), "12345678-0000-1000-8000-00805f9b34fb")
        XCTAssertEqual(BLEUUID.string(CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")), "6e400001-b5a3-f393-e0a9-e50e24dcca9e")
        XCTAssertEqual(BLEUUID.string(try BLEUUID.parse("a002", key: "x")), "0000a002-0000-1000-8000-00805f9b34fb")
    }

    // MARK: - Advertisements

    func testManufacturerDataIsSplitAfterTheCompanyId() throws {
        let apple = try XCTUnwrap(BLEScanDevice.manufacturerData(Data([0x4C, 0x00, 0x02, 0x15, 0xAA])))
        XCTAssertEqual(apple.companyId, 0x004C)
        XCTAssertEqual(apple.data, Data([0x02, 0x15, 0xAA]))
        let littleEndian = try XCTUnwrap(BLEScanDevice.manufacturerData(Data([0x34, 0x12])))
        XCTAssertEqual(littleEndian.companyId, 0x1234)
        XCTAssertEqual(littleEndian.data, Data())
        XCTAssertNil(BLEScanDevice.manufacturerData(Data([0x4C])))
        XCTAssertNil(BLEScanDevice.manufacturerData(Data()))
    }

    func testADeviceFromAnAdvertisement() throws {
        let device = BLEScanDevice(deviceId: "D1", cachedName: "Cached", rssi: -61, advertisementData: [
            CBAdvertisementDataLocalNameKey: "VT-One 1234",
            CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: "A002"), CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")],
            CBAdvertisementDataOverflowServiceUUIDsKey: [CBUUID(string: "A002"), CBUUID(string: "180F")],
            CBAdvertisementDataManufacturerDataKey: Data([0xFF, 0xFF, 0x01, 0x02]),
            CBAdvertisementDataServiceDataKey: [CBUUID(string: "FEAA"): Data([0x10]), CBUUID(string: "180A"): Data([0x20, 0x21])],
            CBAdvertisementDataIsConnectable: NSNumber(value: true),
        ])
        let json = device.json
        XCTAssertEqual(json["deviceId"] as? String, "D1")
        XCTAssertEqual(json["name"] as? String, "VT-One 1234", "the advertised name wins")
        XCTAssertEqual(json["rssi"] as? Int, -61)
        XCTAssertEqual(json["serviceUuids"] as? [String], [
            "0000a002-0000-1000-8000-00805f9b34fb",
            "6e400001-b5a3-f393-e0a9-e50e24dcca9e",
            "0000180f-0000-1000-8000-00805f9b34fb",
        ])
        XCTAssertEqual(json["manufacturerData"] as? [NSDictionary], [["companyId": 0xFFFF, "data": "AQI="]])
        XCTAssertEqual(json["serviceData"] as? [NSDictionary], [
            ["uuid": "0000180a-0000-1000-8000-00805f9b34fb", "data": "ICE="],
            ["uuid": "0000feaa-0000-1000-8000-00805f9b34fb", "data": "EA=="],
        ])
        XCTAssertEqual(json["connectable"] as? Bool, true)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(json))
    }

    func testANamelessAdvertisement() {
        let cached = BLEScanDevice(deviceId: "D1", cachedName: "Cached", rssi: -70, advertisementData: [:])
        XCTAssertEqual(cached.name, "Cached")
        let json = BLEScanDevice(deviceId: "D2", cachedName: nil, rssi: -70, advertisementData: [CBAdvertisementDataLocalNameKey: ""]).json
        XCTAssertTrue(json["name"] is NSNull)
        XCTAssertTrue(json["connectable"] is NSNull, "null when the platform doesn't say")
        XCTAssertEqual(json["serviceUuids"] as? [String], [])
        XCTAssertEqual((json["manufacturerData"] as? [JSONObject])?.count, 0)
    }

    // MARK: - Scan results

    func testScanResultsListEachDeviceOnceWithTheLatestRSSIAndName() {
        var results = BLEScanResults(stopOnName: nil)
        XCTAssertFalse(results.add(BLEScanDevice(deviceId: "A", cachedName: nil, rssi: -80, advertisementData: [:])))
        _ = results.add(BLEScanDevice(deviceId: "B", cachedName: "Bee", rssi: -50, advertisementData: [:]))
        _ = results.add(BLEScanDevice(deviceId: "A", cachedName: nil, rssi: -60, advertisementData: [
            CBAdvertisementDataLocalNameKey: "Ay", CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: "A002")],
        ]))
        _ = results.add(BLEScanDevice(deviceId: "A", cachedName: nil, rssi: BLEScanDevice.rssiUnavailable, advertisementData: [
            CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: "A003")],
        ]))
        let json = results.json
        XCTAssertEqual(json.map { $0["deviceId"] as? String }, ["A", "B"], "in the order first seen")
        XCTAssertEqual(json[0]["name"] as? String, "Ay", "a nameless advertisement keeps the name")
        XCTAssertEqual(json[0]["rssi"] as? Int, -60, "an unavailable RSSI keeps the last one")
        XCTAssertEqual((json[0]["serviceUuids"] as? [String])?.count, 2)
    }

    func testStopOnNameMatchesALowerCasedSubstring() {
        var results = BLEScanResults(stopOnName: "one 12")
        XCTAssertFalse(results.add(BLEScanDevice(deviceId: "A", cachedName: nil, rssi: -60, advertisementData: [:])))
        XCTAssertFalse(results.add(BLEScanDevice(deviceId: "B", cachedName: "VT-One 9999", rssi: -60, advertisementData: [:])))
        XCTAssertTrue(results.add(BLEScanDevice(deviceId: "A", cachedName: nil, rssi: -60, advertisementData: [CBAdvertisementDataLocalNameKey: "VT-ONE 1234"])))
        XCTAssertFalse(BLEScanResults(stopOnName: nil).isEmpty == false)
    }

    // MARK: - Characteristics

    func testPropertiesNames() {
        XCTAssertEqual(BLEProperties.names([.read, .write, .writeWithoutResponse, .notify, .indicate, .broadcast]), [
            "read", "write", "writeWithoutResponse", "notify", "indicate",
        ])
        XCTAssertEqual(BLEProperties.names([]), [])
    }

    func testWriteRules() {
        XCTAssertNil(BLEProperties.writeRefusal(byteCount: 512, withResponse: true, maxWriteLength: 20, properties: [.write]), "a long write")
        XCTAssertEqual(BLEProperties.writeRefusal(byteCount: 1, withResponse: true, maxWriteLength: 20, properties: [.writeWithoutResponse])?.code, "notPermitted")
        XCTAssertNil(BLEProperties.writeRefusal(byteCount: 20, withResponse: false, maxWriteLength: 20, properties: [.writeWithoutResponse]))
        XCTAssertEqual(BLEProperties.writeRefusal(byteCount: 21, withResponse: false, maxWriteLength: 20, properties: [.writeWithoutResponse])?.code, "invalidParams")
        XCTAssertEqual(BLEProperties.writeRefusal(byteCount: 1, withResponse: false, maxWriteLength: 20, properties: [.write])?.code, "notPermitted")
    }

    // MARK: - Operation queue

    private final class Probe {}

    func testOperationsRunOneAtATimeInOrder() {
        let scheduler = FakeScheduler()
        let queue = BLEOperationQueue(timeoutMs: 10_000, scheduler: scheduler)
        let first = ObjectIdentifier(Probe.self), second = ObjectIdentifier(BLEOperationQueue.self)
        var started: [String] = []
        let answers = Answers()
        queue.enqueue(start: { operation in
            started.append("read")
            operation.expectation = .read(first)
        }, completion: answers.add)
        queue.enqueue(start: { operation in
            started.append("write")
            operation.expectation = .write(second)
        }, completion: answers.add)
        XCTAssertEqual(started, ["read"], "the next waits for the answer")
        XCTAssertEqual(queue.count, 2)

        XCTAssertFalse(queue.finish(.read(second), .success(["value": "x"])), "another characteristic: a notification")
        XCTAssertFalse(queue.finish(.write(first), .success([:])), "another kind of callback")
        XCTAssertTrue(queue.finish(.read(first), .success(["value": "AQ=="])))
        XCTAssertEqual(started, ["read", "write"])
        XCTAssertTrue(queue.finish(.write(second), .success([:])))
        XCTAssertEqual(answers.results.count, 2)
        XCTAssertEqual(try answers.results[0].get()["value"] as? String, "AQ==")
        XCTAssertEqual(queue.count, 0)
        XCTAssertTrue(scheduler.items.allSatisfy(\.cancelled), "answered operations cancel their timers")
    }

    func testAnOperationCanEndAtOnce() {
        let queue = BLEOperationQueue(scheduler: FakeScheduler())
        let answers = Answers()
        queue.enqueue(start: { operation in
            queue.finish(operation, .failure(BridgeError(code: "unknownCharacteristic", message: "")))
        }, completion: answers.add)
        queue.enqueue(start: { operation in queue.finish(operation, .success([:])) }, completion: answers.add)
        XCTAssertEqual(answers.results.count, 2)
        XCTAssertEqual(answers.errorCodes, ["unknownCharacteristic"])
    }

    func testATimeoutAnswersAndCallsOnTimeout() {
        let scheduler = FakeScheduler()
        let queue = BLEOperationQueue(timeoutMs: 10_000, scheduler: scheduler)
        let key = ObjectIdentifier(Probe.self)
        var timeouts = 0
        queue.onTimeout = {
            timeouts += 1
            // The device disconnects: the rest answers notConnected.
            queue.failAll(BridgeError(code: "notConnected", message: ""))
        }
        let answers = Answers()
        queue.enqueue(start: { $0.expectation = .read(key) }, completion: answers.add)
        queue.enqueue(start: { $0.expectation = .read(key) }, completion: answers.add)
        XCTAssertEqual(scheduler.items.first?.afterMs, 10_000, "the shell's 10 s operation timeout")
        scheduler.fireAll()
        XCTAssertEqual(answers.errorCodes, ["timeout", "notConnected"])
        XCTAssertEqual(timeouts, 1)
        XCTAssertFalse(queue.finish(.read(key), .success([:])), "a late answer goes nowhere")
        XCTAssertEqual(answers.results.count, 2)
    }

    func testATimeoutWithoutADisconnectMovesOn() {
        let scheduler = FakeScheduler()
        let queue = BLEOperationQueue(scheduler: scheduler)
        let key = ObjectIdentifier(Probe.self)
        var started = 0
        let answers = Answers()
        queue.enqueue(start: { started += 1; $0.expectation = .read(key) }, completion: answers.add)
        queue.enqueue(start: { started += 1; $0.expectation = .read(key) }, completion: answers.add)
        scheduler.fire(0)
        XCTAssertEqual(started, 2)
        XCTAssertTrue(queue.finish(.read(key), .success([:])))
        XCTAssertEqual(answers.errorCodes, ["timeout"])
        XCTAssertEqual(answers.results.count, 2)
    }

    func testWritesWithoutResponseWaitUntilTheyFit() {
        let queue = BLEOperationQueue(scheduler: FakeScheduler())
        var written = 0
        let answers = Answers()
        queue.enqueue(start: { operation in
            operation.expectation = .readyToWriteWithoutResponse
            operation.onReady = {
                written += 1
                queue.finish(operation, .success([:]))
            }
        }, completion: answers.add)
        XCTAssertEqual(written, 0)
        queue.readyToWriteWithoutResponse()
        XCTAssertEqual(written, 1)
        XCTAssertEqual(answers.results.count, 1)
        queue.readyToWriteWithoutResponse()
        XCTAssertEqual(written, 1)
    }

    func testFailAllAnswersEverything() {
        let queue = BLEOperationQueue(scheduler: FakeScheduler())
        let answers = Answers()
        for _ in 0..<3 {
            queue.enqueue(start: { $0.expectation = .read(ObjectIdentifier(Probe.self)) }, completion: answers.add)
        }
        queue.failAll(BridgeError(code: "bluetoothOff", message: ""))
        XCTAssertEqual(answers.errorCodes, ["bluetoothOff", "bluetoothOff", "bluetoothOff"])
        XCTAssertEqual(queue.count, 0)
    }

    // MARK: - Params

    func testScanParams() throws {
        let request = try Bridge.bleScanRequest(Params(["services": ["a002", "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"], "timeoutMs": 8000, "stopOnName": "One"]))
        XCTAssertEqual(request.services?.map(BLEUUID.string), ["0000a002-0000-1000-8000-00805f9b34fb", "6e400001-b5a3-f393-e0a9-e50e24dcca9e"])
        XCTAssertEqual(request.timeoutMs, 8000)
        XCTAssertEqual(request.stopOnName, "One")
        XCTAssertNil(try Bridge.bleScanRequest(Params(["services": [], "timeoutMs": 8000])).services, "empty: every device")
        XCTAssertNil(try Bridge.bleScanRequest(Params(["timeoutMs": 8000])).services)
        XCTAssertEqual(try Bridge.bleScanRequest(Params(["timeoutMs": 10])).timeoutMs, 1_000, "at least 1 s")
        XCTAssertEqual(try Bridge.bleScanRequest(Params(["timeoutMs": 600_000])).timeoutMs, 60_000, "at most 60 s")
        for params: JSONObject in [
            [:], ["timeoutMs": 0], ["timeoutMs": "1000"], ["timeoutMs": 1000, "services": "a002"],
            ["timeoutMs": 1000, "services": ["zz"]], ["timeoutMs": 1000, "stopOnName": 1],
        ] {
            assertCode("invalidParams", "\(params)") { _ = try Bridge.bleScanRequest(Params(params)) }
        }
    }

    func testConnectParams() throws {
        let request = try Bridge.bleConnectRequest(Params(["deviceId": "D1", "timeoutMs": 15_000, "mtu": 247]))
        XCTAssertEqual(request.deviceId, "D1")
        XCTAssertEqual(request.timeoutMs, 15_000)
        XCTAssertEqual(try Bridge.bleConnectRequest(Params(["deviceId": "D1", "timeoutMs": 100_000])).timeoutMs, 60_000)
        for params: JSONObject in [
            ["timeoutMs": 1000], ["deviceId": "D1"], ["deviceId": 1, "timeoutMs": 1000],
            ["deviceId": "D1", "timeoutMs": 1000, "mtu": 10], ["deviceId": "D1", "timeoutMs": 1000, "mtu": 600],
            ["deviceId": "D1", "timeoutMs": 1000, "mtu": 247.5],
        ] {
            assertCode("invalidParams", "\(params)") { _ = try Bridge.bleConnectRequest(Params(params)) }
        }
    }

    func testCharacteristicParams() throws {
        let request = try Bridge.bleCharacteristicRequest(Params(["deviceId": "D1", "service": "a002", "characteristic": "A003"]))
        XCTAssertEqual(request.deviceId, "D1")
        XCTAssertEqual(BLEUUID.string(request.service), "0000a002-0000-1000-8000-00805f9b34fb")
        XCTAssertEqual(BLEUUID.string(request.characteristic), "0000a003-0000-1000-8000-00805f9b34fb")
        for params: JSONObject in [
            ["service": "a002", "characteristic": "a003"],
            ["deviceId": "D1", "characteristic": "a003"],
            ["deviceId": "D1", "service": "a002"],
            ["deviceId": "D1", "service": "nope", "characteristic": "a003"],
            ["deviceId": "D1", "service": "a002", "characteristic": 3],
        ] {
            assertCode("invalidParams", "\(params)") { _ = try Bridge.bleCharacteristicRequest(Params(params)) }
        }
    }

    func testWriteParams() throws {
        let base: JSONObject = ["deviceId": "D1", "service": "a002", "characteristic": "a003", "value": "AQID", "withResponse": true]
        let (_, value, withResponse) = try Bridge.bleWriteRequest(Params(base))
        XCTAssertEqual(value, Data([1, 2, 3]))
        XCTAssertTrue(withResponse)
        var longest = base
        longest["value"] = Data(count: 512).base64EncodedString()
        XCTAssertNoThrow(try Bridge.bleWriteRequest(Params(longest)), "a long write of 512 bytes")
        for (key, bad) in [
            ("value", Data(count: 513).base64EncodedString()), ("value", "not base64"), ("value", 1),
            ("withResponse", "true"), ("withResponse", 1),
        ] as [(String, Any)] {
            var params = base
            params[key] = bad
            assertCode("invalidParams", "\(key)") { _ = try Bridge.bleWriteRequest(Params(params)) }
        }
        var noFlag = base
        noFlag.removeValue(forKey: "withResponse")
        assertCode("invalidParams") { _ = try Bridge.bleWriteRequest(Params(noFlag)) }
    }

    // MARK: - hello

    func testBLEIsListedWhenAvailable() {
        func lists(available: Bool) -> Bool {
            (Bridge.helloResult(bluetoothAvailable: available)["capabilities"] as? [String] ?? []).contains("ble")
        }
        XCTAssertTrue(lists(available: true))
        XCTAssertFalse(lists(available: false))
    }

    // MARK: - Without a usage description

    func testEveryCallIsUnavailableWithoutTheUsageDescription() async {
        // The test host has no NSBluetoothAlwaysUsageDescription: iOS would
        // end it if CoreBluetooth were touched.
        let service = BluetoothService { _, _ in }
        let characteristic = try! Bridge.bleCharacteristicRequest(Params(["deviceId": "D1", "service": "a002", "characteristic": "a003"]))
        let calls: [(String, () async throws -> Void)] = [
            ("ensurePermissions", { try await service.ensureReady() }),
            ("scan", { _ = try await service.scan(BluetoothService.ScanRequest(services: nil, timeoutMs: 1_000, stopOnName: nil)) }),
            ("connect", { _ = try await service.connect(deviceId: "D1", timeoutMs: 1_000) }),
            ("read", { _ = try await service.read(characteristic) }),
            ("write", { _ = try await service.write(characteristic, value: Data([1]), withResponse: true) }),
            ("subscribe", { _ = try await service.setNotify(true, characteristic) }),
        ]
        for (name, call) in calls {
            do {
                try await call()
                XCTFail("\(name) should be unavailable")
            } catch {
                XCTAssertEqual((error as? BridgeError)?.code, "unavailable", name)
            }
        }
        // Nothing to stop or disconnect: answered without CoreBluetooth.
        service.stopScan()
        service.disconnect(deviceId: "D1")
        service.shutDown()
        XCTAssertEqual(service.connectionCount, 0)
    }

    func testStateErrors() {
        XCTAssertNil(BluetoothService.stateError(.poweredOn))
        XCTAssertEqual(BluetoothService.stateError(.poweredOff)?.code, "bluetoothOff")
        XCTAssertEqual(BluetoothService.stateError(.unauthorized)?.code, "bluetoothPermissionDenied")
        XCTAssertEqual(BluetoothService.stateError(.unsupported)?.code, "unavailable")
    }

    func testDisconnectReasons() {
        XCTAssertEqual(BluetoothService.disconnectReason(nil).reason, "remote")
        XCTAssertEqual(BluetoothService.disconnectReason(NSError(domain: CBErrorDomain, code: CBError.Code.peripheralDisconnected.rawValue)).reason, "remote")
        XCTAssertEqual(BluetoothService.disconnectReason(NSError(domain: CBErrorDomain, code: CBError.Code.connectionTimeout.rawValue)).reason, "timeout")
        let other = BluetoothService.disconnectReason(NSError(domain: CBErrorDomain, code: CBError.Code.unknown.rawValue))
        XCTAssertEqual(other.reason, "error")
        XCTAssertNotNil(other.message)
    }

    // MARK: - Helpers

    private func assertCode(_ code: String, _ message: String = "", file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void) {
        do {
            try body()
            XCTFail("expected \(code) \(message)", file: file, line: line)
        } catch {
            XCTAssertEqual((error as? BridgeError)?.code, code, message, file: file, line: line)
        }
    }
}

/// Runs scheduled blocks only when told to.
@MainActor
final class FakeScheduler: BLEScheduler {
    final class Item: BLECancellable {
        let afterMs: Int
        let body: @MainActor () -> Void
        private(set) var cancelled = false
        private(set) var fired = false

        init(afterMs: Int, body: @escaping @MainActor () -> Void) {
            self.afterMs = afterMs
            self.body = body
        }

        func cancel() {
            cancelled = true
        }

        @MainActor
        func fire() {
            guard !cancelled, !fired else { return }
            fired = true
            body()
        }
    }

    private(set) var items: [Item] = []

    func schedule(afterMs: Int, _ body: @escaping @MainActor () -> Void) -> BLECancellable {
        let item = Item(afterMs: afterMs, body: body)
        items.append(item)
        return item
    }

    func fire(_ index: Int) {
        items[index].fire()
    }

    /// Fires every pending block, including ones scheduled meanwhile.
    func fireAll() {
        var index = 0
        while index < items.count {
            items[index].fire()
            index += 1
        }
    }
}
