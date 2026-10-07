import XCTest
@testable import PlugchoiceSDK

/// `lan.discover` and `lan.address` (PROTOCOL §9.4).
@MainActor
final class LanTests: XCTestCase {
    // MARK: - Declared types

    func testBonjourServicesDeclaration() {
        XCTAssertEqual(LanDiscovery.declaredTypes(["_alfen._tcp", "_http._tcp."]), ["_alfen._tcp", "_http._tcp"])
        XCTAssertEqual(LanDiscovery.declaredTypes(["_alfen._tcp.", 42, "_alfen._tcp", ""]), ["_alfen._tcp"])
        XCTAssertEqual(LanDiscovery.declaredTypes(nil), [])
        XCTAssertEqual(LanDiscovery.declaredTypes("_alfen._tcp"), [])
        XCTAssertEqual(LanDiscovery.declaredServiceTypes, [], "the test host declares no Bonjour services")
    }

    // MARK: - lan.discover params

    private let alfen = ["_alfen._tcp"]

    func testDiscoverRequest() throws {
        let request = try Bridge.discoverRequest(
            Params(["types": ["_alfen._tcp", "_alfen._tcp"], "timeoutMs": 8000, "stopOnName": "ACE0870096"]),
            declared: alfen
        )
        XCTAssertEqual(request, Bridge.DiscoverRequest(types: ["_alfen._tcp"], timeoutMs: 8000, stopOnName: "ACE0870096"))
        XCTAssertNil(try Bridge.discoverRequest(Params(["types": ["_alfen._tcp"], "timeoutMs": 1]), declared: alfen).stopOnName)
        XCTAssertNil(try Bridge.discoverRequest(Params(["types": ["_alfen._tcp"], "timeoutMs": 1, "stopOnName": ""]), declared: alfen).stopOnName, "an empty stopOnName is none")
        XCTAssertEqual(try Bridge.discoverRequest(Params(["types": ["_alfen._tcp."], "timeoutMs": 1.5]), declared: alfen),
                       Bridge.DiscoverRequest(types: ["_alfen._tcp"], timeoutMs: 2, stopOnName: nil), "a trailing dot is fine")
    }

    func testDiscoverRejectsBadParams() {
        for params: JSONObject in [
            ["timeoutMs": 8000],
            ["types": [], "timeoutMs": 8000],
            ["types": "_alfen._tcp", "timeoutMs": 8000],
            ["types": ["_alfen._tcp", 1], "timeoutMs": 8000],
            ["types": ["_alfen._tcp"]],
            ["types": ["_alfen._tcp"], "timeoutMs": 0],
            ["types": ["_alfen._tcp"], "timeoutMs": "8000"],
            ["types": ["_alfen._tcp"], "timeoutMs": 8000, "stopOnName": 7],
            // Not service types (as on Android), declared or not.
            ["types": ["alfen"], "timeoutMs": 8000],
            ["types": ["_alfen._tcp.local."], "timeoutMs": 8000],
            ["types": ["_alfen"], "timeoutMs": 8000],
            ["types": ["_alfen._sctp"], "timeoutMs": 8000],
            ["types": ["_a b._tcp"], "timeoutMs": 8000],
        ] {
            assertCode("invalidParams", "\(params)") { _ = try Bridge.discoverRequest(Params(params), declared: alfen) }
        }
    }

    func testDiscoverTakesAnyDeclaredType() throws {
        let declared = ["_alfen._tcp", "_http._tcp", "_hap._tcp"]
        let request = try Bridge.discoverRequest(Params(["types": ["_http._tcp", "_hap._tcp", "_http._tcp"], "timeoutMs": 8000]), declared: declared)
        XCTAssertEqual(request.types, ["_http._tcp", "_hap._tcp"])
    }

    func testDiscoverRefusesUndeclaredTypes() {
        for type in ["_http._tcp", "_lolo3._http._tcp", "_alfen._udp", "_ALFEN._tcp"] {
            assertCode("undeclaredServiceType", type) {
                _ = try Bridge.discoverRequest(Params(["types": ["_alfen._tcp", type], "timeoutMs": 8000]), declared: alfen)
            }
        }
    }

    func testDiscoverNeedsTheHostsBonjourDeclaration() {
        assertCode("undeclaredServiceType") {
            _ = try Bridge.discoverRequest(Params(["types": ["_alfen._tcp"], "timeoutMs": 8000]), declared: [])
        }
        // The test host declares nothing, so the default is the same.
        assertCode("undeclaredServiceType") {
            _ = try Bridge.discoverRequest(Params(["types": ["_alfen._tcp"], "timeoutMs": 8000]))
        }
    }

    func testASecondDiscoverIsBusy() throws {
        let discovery = LanDiscovery()
        var answers = 0
        try discovery.discover(types: ["_alfen._tcp"], timeoutMs: 60_000, stopOnName: nil) { _ in answers += 1 }
        XCTAssertTrue(discovery.isRunning)
        assertCode("busy") {
            try discovery.discover(types: ["_alfen._tcp"], timeoutMs: 60_000, stopOnName: nil) { _ in }
        }
        discovery.cancel()
        XCTAssertFalse(discovery.isRunning)
        XCTAssertEqual(answers, 0, "cancel (the page went away) doesn't answer")
    }

    func testStopDiscoveryAnswersWithWhatWasFound() throws {
        let discovery = LanDiscovery()
        var answer: Result<JSONObject, BridgeError>?
        try discovery.discover(types: ["_alfen._tcp"], timeoutMs: 60_000, stopOnName: nil) { answer = $0 }
        discovery.stop()
        XCTAssertFalse(discovery.isRunning)
        switch try XCTUnwrap(answer) {
        case .success(let result):
            XCTAssertNotNil(result["services"] as? [JSONObject])
        case .failure(let error):
            // The simulator may not browse at all; then it says why.
            XCTAssertTrue(["localNetworkDenied", "network"].contains(error.code), error.code)
        }
        // A new browse can start once the last one answered.
        try discovery.discover(types: ["_alfen._tcp"], timeoutMs: 60_000, stopOnName: nil) { _ in }
        discovery.cancel()
    }

    // MARK: - stopOnName

    func testStopOnNameMatchesALowerCasedSubstring() {
        XCTAssertTrue(DiscoveredServices.matches(name: "ng910-60623-ace0870096", stopOnName: "ace0870096"))
        XCTAssertTrue(DiscoveredServices.matches(name: "ng910-60623-ace0870096", stopOnName: "ACE0870096"))
        XCTAssertTrue(DiscoveredServices.matches(name: "NG910-60623-ACE0870096", stopOnName: "60623-ace"))
        XCTAssertFalse(DiscoveredServices.matches(name: "ng910-60623-ace0870096", stopOnName: "ace0870097"))
        XCTAssertFalse(DiscoveredServices.matches(name: "ng910-60623-ace0870096", stopOnName: nil))
    }

    func testStopsOnlyOnceTheMatchHasAnIPv4Address() {
        var services = DiscoveredServices(stopOnName: "ACE0870096")
        services.found(name: "ng910-60623-ace0870096", type: "_alfen._tcp")
        XCTAssertFalse(services.resolved(name: "ng910-60623-ace0870096", type: "_alfen._tcp", addresses: [], port: 443, txt: nil))
        XCTAssertFalse(services.resolved(name: "ng910-60623-ace0870096", type: "_alfen._tcp", addresses: ["fe80::1"], port: 443, txt: nil))
        XCTAssertFalse(services.resolved(name: "ng910-11111-ace0000001", type: "_alfen._tcp", addresses: ["10.0.0.9"], port: 443, txt: nil))
        XCTAssertTrue(services.resolved(name: "ng910-60623-ace0870096", type: "_alfen._tcp", addresses: ["10.206.2.88"], port: 443, txt: nil))
    }

    func testWithoutStopOnNameNothingStops() {
        var services = DiscoveredServices(stopOnName: nil)
        XCTAssertFalse(services.resolved(name: "ng910-60623-ace0870096", type: "_alfen._tcp", addresses: ["10.0.0.2"], port: 443, txt: nil))
    }

    func testServicesListEverythingFoundInOrder() throws {
        var services = DiscoveredServices(stopOnName: nil)
        services.found(name: "b-unresolved", type: "_alfen._tcp", txt: ["Identity": "LIB_1"])
        _ = services.resolved(name: "a", type: "_alfen._tcp", addresses: ["fe80::1", "10.0.0.2"], port: 443, txt: ["FWVersion": "7.4.4"])
        _ = services.resolved(name: "a", type: "_alfen._tcp", addresses: ["10.0.0.2", "10.0.0.3"], port: 443, txt: nil)
        let list = services.services
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0]["name"] as? String, "b-unresolved")
        XCTAssertEqual(list[0]["addresses"] as? [String], [])
        XCTAssertEqual(list[0]["port"] as? Int, 0)
        XCTAssertEqual(list[0]["txt"] as? [String: String], ["Identity": "LIB_1"])
        XCTAssertEqual(list[1]["addresses"] as? [String], ["10.0.0.2", "10.0.0.3", "fe80::1"], "IPv4 first, no duplicates")
        XCTAssertEqual(list[1]["txt"] as? [String: String], ["FWVersion": "7.4.4"], "a resolve without TXT keeps the earlier one")
    }

    // MARK: - lan.address

    func testLanAddressAlwaysHasBothKeys() throws {
        let address = SocketAddress.wifiAddress()
        XCTAssertEqual(Set(address.keys), ["ip", "netmask"])
        if let ip = address["ip"] as? String {
            XCTAssertNotNil(LocalHostPolicy.ipv4Octets(ip))
            XCTAssertNotNil(LocalHostPolicy.ipv4Octets(try XCTUnwrap(address["netmask"] as? String)))
        } else {
            XCTAssertTrue(address["ip"] is NSNull)
            XCTAssertTrue(address["netmask"] is NSNull)
        }
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
