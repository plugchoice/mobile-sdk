import XCTest
@testable import PlugchoiceSDK

/// The handshake (PROTOCOL §5), `session.close` (§6.1), `camera.scanCode`'s
/// params (§10) and the error shape (§4).
@MainActor
final class BridgeTests: XCTestCase {
    // MARK: - Messages

    func testMessagesAreJSONStrings() {
        XCTAssertEqual(Bridge.decode(#"{"type":"request","id":"r1","method":"hello","params":{}}"#)?["id"] as? String, "r1")
        XCTAssertNil(Bridge.decode(["type": "request", "id": "r1", "method": "hello"] as JSONObject), "an object, not a JSON string (as on Android)")
        XCTAssertNil(Bridge.decode("[1]"))
        XCTAssertNil(Bridge.decode("not json"))
    }

    // MARK: - hello

    func testTheBridgeIsVersion1() {
        XCTAssertEqual(Bridge.bridgeVersion, 1)
    }

    func testHelloResult() throws {
        let result = Bridge.helloResult()
        XCTAssertEqual(result["bridgeVersion"] as? Int, 1)
        XCTAssertEqual(result["sdkVersion"] as? String, Plugchoice.sdkVersion)
        XCTAssertEqual(result["platform"] as? String, "ios")
        XCTAssertNotNil(result["osVersion"] as? String)
        let capabilities = try XCTUnwrap(result["capabilities"] as? [String])
        XCTAssertEqual(
            capabilities,
            ["wifi.join", "http.request", "ws", "session.close", "ui.closeRequest", "lan.address", "http.session", "auth.clientSecret", "tcp", "udp", "trust.custom"],
            "the test host has no NSCameraUsageDescription, NSBonjourServices, NSBluetoothAlwaysUsageDescription or NSAccessorySetupKitSupports"
        )
        XCTAssertEqual(result["lanServiceTypes"] as? [String], [], "the test host declares none")
    }

    func testDiscoveryIsListedWhenTheHostDeclaresAnyBonjourType() throws {
        func capabilities(_ declared: [String]) throws -> [String] {
            try XCTUnwrap(Bridge.helloResult(declaredServiceTypes: declared)["capabilities"] as? [String])
        }
        XCTAssertTrue(try capabilities(["_http._tcp"]).contains("lan.discover"))
        XCTAssertTrue(try capabilities(["_alfen._tcp", "_http._tcp"]).contains("lan.discover"))
        XCTAssertFalse(try capabilities([]).contains("lan.discover"))
        XCTAssertEqual(Bridge.helloResult(declaredServiceTypes: ["_alfen._tcp", "_http._tcp"])["lanServiceTypes"] as? [String], ["_alfen._tcp", "_http._tcp"])
    }

    func testEachCapabilityOnce() throws {
        let capabilities = try XCTUnwrap(Bridge.helloResult(declaredServiceTypes: ["_http._tcp"], bluetoothAvailable: true)["capabilities"] as? [String])
        XCTAssertEqual(Set(capabilities).count, capabilities.count)
        XCTAssertTrue(Set(["lan.discover", "ble"]).isSubset(of: capabilities))
    }

    // MARK: - session.close

    private func close(_ params: JSONObject, opened: String = "add") throws -> Bridge.SessionClose {
        try Bridge.sessionClose(Params(params), openedAction: opened)
    }

    func testSessionClose() throws {
        let close = try close([
            "status": "success",
            "sessionId": "s1",
            "action": "reconnect",
            "devices": [["type": "charger", "id": "c1"], ["type": "meter", "id": "m1"]],
        ])
        XCTAssertEqual(close, Bridge.SessionClose(
            status: .success,
            action: "reconnect",
            sessionId: "s1",
            devices: [Device(type: "charger", id: "c1"), Device(type: "meter", id: "m1")],
            error: nil
        ))
    }

    func testSessionCloseWithoutARun() throws {
        let close = try close([
            "status": "error",
            "action": "add",
            "devices": [],
            "error": ["code": "clientSecretUnavailable"],
        ])
        XCTAssertNil(close.sessionId)
        XCTAssertEqual(close.devices, [])
        XCTAssertEqual(close.error, LinkError(code: "clientSecretUnavailable"))
        let failed = try self.close(["status": "error", "error": ["code": "chargerUnreachable", "message": "no answer"]])
        XCTAssertEqual(failed.error, LinkError(code: "chargerUnreachable", message: "no answer"))
    }

    func testWithoutAnActionTheOpenedOne() throws {
        XCTAssertEqual(try close(["status": "cancelled"], opened: "reconnect"), Bridge.SessionClose(
            status: .cancelled, action: "reconnect", sessionId: nil, devices: [], error: nil
        ))
        XCTAssertEqual(try close(["status": "cancelled", "action": "", "sessionId": ""], opened: "setup").action, "setup")
        XCTAssertNil(try close(["status": "cancelled", "sessionId": ""]).sessionId, "an empty sessionId is none")
    }

    func testDevicesPassThroughForEveryStatus() throws {
        for status in ["success", "cancelled", "error"] {
            let close = try close(["status": status, "action": "add", "devices": [["type": "charger", "id": "c1"]], "error": ["code": "x"]])
            XCTAssertEqual(close.devices, [Device(type: "charger", id: "c1")], status)
        }
    }

    func testOnlyDevicesAreRead() throws {
        // chargerIds is no part of the protocol: ignored like any unknown field.
        let close = try close(["status": "success", "action": "setup", "chargerIds": ["c1"]])
        XCTAssertEqual(close.action, "setup")
        XCTAssertEqual(close.devices, [])
    }

    func testSessionCloseRejectsBadParams() {
        for params: JSONObject in [
            [:],
            ["status": "done"],
            ["sessionId": "s1"],
            ["status": "success", "sessionId": 1],
            ["status": "success", "action": 1],
            ["status": "success", "devices": "c1"],
            ["status": "success", "devices": ["c1"]],
            ["status": "success", "devices": [["type": "charger"]]],
            ["status": "success", "devices": [["id": "c1"]]],
            ["status": "success", "devices": [["type": "", "id": "c1"]]],
            ["status": "success", "devices": [["type": "charger", "id": 1]]],
            ["status": "error", "error": ["message": "no code"]],
            ["status": "error", "error": ["code": "x", "message": 1]],
            ["status": "error", "error": "x"],
        ] {
            assertCode("invalidParams", "\(params)") { _ = try self.close(params) }
        }
    }

    // MARK: - camera.scanCode

    func testScanRequest() throws {
        XCTAssertEqual(
            try Bridge.scanRequest(Params(["formats": ["qr"], "title": "Scan the card", "hint": "On the back"])),
            CodeScanner.Request(title: "Scan the card", hint: "On the back")
        )
        XCTAssertEqual(try Bridge.scanRequest(Params(["formats": ["qr"], "title": ""])), CodeScanner.Request(title: nil, hint: nil))
        XCTAssertThrowsError(try Bridge.scanRequest(Params([:])))
        XCTAssertThrowsError(try Bridge.scanRequest(Params(["formats": []])))
        XCTAssertThrowsError(try Bridge.scanRequest(Params(["formats": ["qr", "ean13"]])))
        XCTAssertThrowsError(try Bridge.scanRequest(Params(["formats": "qr"])))
    }

    func testScanIsUnavailableWithoutACameraUsageDescription() async {
        // The test host has no NSCameraUsageDescription (and the simulator no
        // camera): answer `unavailable`, never touch the camera.
        do {
            _ = try await CodeScanner().scan(CodeScanner.Request(title: nil, hint: nil), from: nil)
            XCTFail("expected unavailable")
        } catch {
            XCTAssertEqual((error as? BridgeError)?.code, "unavailable")
        }
    }

    // MARK: - Errors

    func testErrorsCarryDetailsOnlyWhenSet() {
        XCTAssertEqual(BridgeError(code: "network", message: "x").json as NSDictionary, ["code": "network", "message": "x"])
        let tls = BridgeError(code: "tls", message: "x", details: ["presentedFingerprint": "sha256/abc="])
        XCTAssertEqual(tls.json as NSDictionary, ["code": "tls", "message": "x", "details": ["presentedFingerprint": "sha256/abc="]])
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
