import XCTest
@testable import PlugchoiceSDK

/// The params of the local-network calls (PROTOCOL §9): host rules, trust
/// objects, timeouts and limits.
@MainActor
final class RequestParamsTests: XCTestCase {
    private let pinned: JSONObject = ["fingerprints": [TrustTests.ecFingerprint]]

    // MARK: - http.session.open

    func testOpenRequest() throws {
        let request = try Bridge.sessionOpenRequest(Params(["host": "192.168.1.10", "trust": pinned]))
        XCTAssertEqual(request.host, "192.168.1.10")
        XCTAssertEqual(request.port, 443)
        XCTAssertEqual(request.trust?.fingerprints.count, 1)
        XCTAssertEqual(try Bridge.sessionOpenRequest(Params(["host": "[::1]", "port": 8443])).host, "::1")
        XCTAssertEqual(try Bridge.sessionOpenRequest(Params(["host": "charger.local", "port": 8443])).port, 8443)
    }

    func testOpenTimeoutIsOptionalAndClamped() throws {
        func timeout(_ value: Any?) throws -> Int {
            var params: JSONObject = ["host": "10.0.0.2"]
            params["timeoutMs"] = value
            return try Bridge.sessionOpenRequest(Params(params)).timeoutMs
        }
        XCTAssertEqual(try timeout(nil), 10_000)
        XCTAssertEqual(try timeout(NSNull()), 10_000)
        XCTAssertEqual(try timeout(2_500), 2_500, "a subnet-sweep probe")
        XCTAssertEqual(try timeout(2_500.2), 2_501)
        XCTAssertEqual(try timeout(100), 500, "at least 500 ms")
        XCTAssertEqual(try timeout(60_000), 30_000, "at most 30 s")
        XCTAssertEqual(try timeout(1e300), 30_000)
        for bad: Any in [0, -1, "2500", true] {
            assertCode("invalidParams", "\(bad)") { _ = try timeout(bad) }
        }
    }

    func testOpenFollowsRouteTraffic() throws {
        let params = Params(["host": "192.168.50.10"])
        XCTAssertFalse(try Bridge.sessionOpenRequest(params).routeTraffic)
        XCTAssertTrue(try Bridge.sessionOpenRequest(params, routeTraffic: true).routeTraffic)
    }

    func testOpenUsesTheHostAllowListOfHTTPRequest() {
        for host in ["10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.50.10", "169.254.1.1", "127.0.0.1", "localhost", "ng910-60623-ace0870096.local"] {
            XCTAssertNoThrow(try Bridge.sessionOpenRequest(Params(["host": host])), host)
        }
        for host in ["8.8.8.8", "172.32.0.1", "example.com", "plugchoice.com", "192.168.1", "010.0.0.1", "167772161", "192.168.1.10:443", "fe80::1"] {
            assertCode("forbiddenHost", host) { _ = try Bridge.sessionOpenRequest(Params(["host": host])) }
        }
    }

    func testOpenRejectsBadParams() {
        for params: JSONObject in [
            [:],
            ["host": ""],
            ["host": 10],
            ["host": "10.0.0.1", "trust": "system"],
            ["host": "10.0.0.1", "trust": "none"],
            // No trust names: the page passes a CA itself.
            ["host": "10.0.0.1", "trust": "alfen"],
            ["host": "10.0.0.1", "port": 0],
            ["host": "10.0.0.1", "port": 65_536],
            ["host": "10.0.0.1", "port": 443.5],
            ["host": "10.0.0.1", "port": "443"],
            // A bad trust is invalidParams before the host is looked at.
            ["host": "8.8.8.8", "trust": "system"],
        ] {
            assertCode("invalidParams", "\(params)") { _ = try Bridge.sessionOpenRequest(Params(params)) }
        }
    }

    // MARK: - http.session.request

    private func requestParams(_ overrides: JSONObject = [:]) -> JSONObject {
        var params: JSONObject = ["sessionId": "s1", "method": "GET", "path": "/api/info", "headers": [:], "timeoutMs": 2500]
        for (key, value) in overrides { params[key] = value }
        return params
    }

    func testSessionRequest() throws {
        let (sessionId, request) = try Bridge.sessionRequest(Params(requestParams([
            "method": "post",
            "path": "/api/prop?ids=2053_0,20F0_3",
            "headers": ["Content-Type": "application/json", "Accept": "application/json"],
            "body": "{\"a\":1}",
        ])))
        XCTAssertEqual(sessionId, "s1")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/prop?ids=2053_0,20F0_3")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        XCTAssertEqual(request.body, "{\"a\":1}")
        XCTAssertEqual(request.timeoutMs, 2500)
        // An empty body on GET is no body.
        XCTAssertNil(try Bridge.sessionRequest(Params(requestParams(["body": ""]))).request.body)
        // headers may be left out.
        var noHeaders = requestParams()
        noHeaders.removeValue(forKey: "headers")
        XCTAssertEqual(try Bridge.sessionRequest(Params(noHeaders)).request.headers, [:])
        // The body comes as text unless asked for as base64.
        XCTAssertEqual(request.responseBody, .text)
        XCTAssertEqual(try Bridge.sessionRequest(Params(requestParams(["responseBody": "base64"]))).request.responseBody, .base64)
        XCTAssertEqual(try Bridge.sessionRequest(Params(requestParams(["responseBody": "text"]))).request.responseBody, .text)
        for bad: Any in ["binary", "BASE64", 1, true] {
            assertCode("invalidParams", "\(bad)") { _ = try Bridge.sessionRequest(Params(requestParams(["responseBody": bad]))) }
        }
    }

    func testSessionRequestRejectsBadParams() {
        var missingSession = requestParams()
        missingSession.removeValue(forKey: "sessionId")
        var missingTimeout = requestParams()
        missingTimeout.removeValue(forKey: "timeoutMs")
        for params in [
            missingSession,
            missingTimeout,
            requestParams(["method": "PATCH"]),
            requestParams(["method": "DELETE"]),
            requestParams(["path": "api/info"]),
            requestParams(["path": "https://192.168.1.10/api/info"]),
            requestParams(["path": "/api info"]),
            requestParams(["path": "/api#info"]),
            requestParams(["path": "/api/\u{e9}"]),
            requestParams(["headers": ["X-Evil": "a\r\nHost: elsewhere"]]),
            requestParams(["headers": ["Bad Name": "x"]]),
            requestParams(["headers": ["Accept": 1]]),
            requestParams(["body": "{}"]),
            requestParams(["method": "POST", "body": 1]),
            requestParams(["timeoutMs": -1]),
        ] {
            assertCode("invalidParams", "\(params)") { _ = try Bridge.sessionRequest(Params(params)) }
        }
    }

    // MARK: - Trust objects (§9.8)

    func testSessionOpenTakesATrustObjectOrNone() throws {
        let pinned = try Bridge.sessionOpenRequest(Params(["host": "10.0.0.2", "trust": ["fingerprints": [TrustTests.ecFingerprint]]]))
        XCTAssertEqual(pinned.trust?.fingerprints.count, 1)
        XCTAssertNil(try Bridge.sessionOpenRequest(Params(["host": "10.0.0.2"])).trust, "the system's trust")
        for trust: Any in [[:] as JSONObject, ["anchors": ["x"]] as JSONObject, "alfen", "system", 1] {
            assertCode("invalidParams", "\(trust)") { _ = try Bridge.sessionOpenRequest(Params(["host": "10.0.0.2", "trust": trust])) }
        }
        // A bad trust is invalidParams before the host is looked at.
        assertCode("invalidParams") { _ = try Bridge.sessionOpenRequest(Params(["host": "8.8.8.8", "trust": [:] as JSONObject])) }
        // A page's anchor never reaches the open internet.
        assertCode("forbiddenHost") {
            _ = try Bridge.sessionOpenRequest(Params(["host": "8.8.8.8", "trust": ["fingerprints": [TrustTests.ecFingerprint]]]))
        }
    }

    private func httpParams(_ overrides: JSONObject = [:]) -> JSONObject {
        var params: JSONObject = ["requestId": "r1", "url": "https://192.168.1.10/api", "method": "GET", "headers": [:], "timeoutMs": 2500]
        for (key, value) in overrides { params[key] = value }
        return params
    }

    func testHTTPRequestTakesAResponseBody() throws {
        XCTAssertEqual(try Bridge.httpRequest(Params(httpParams())).responseBody, .text)
        XCTAssertEqual(try Bridge.httpRequest(Params(httpParams(["responseBody": "base64"]))).responseBody, .base64)
        assertCode("invalidParams", "binary") { _ = try Bridge.httpRequest(Params(httpParams(["responseBody": "binary"]))) }
    }

    func testHTTPRequestTakesATrust() throws {
        XCTAssertNil(try Bridge.httpRequest(Params(httpParams())).trust)
        let request = try Bridge.httpRequest(Params(httpParams(["trust": ["fingerprints": [TrustTests.ecFingerprint]], "method": "post", "body": "{}"])))
        XCTAssertEqual(request.trust?.fingerprints.count, 1)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.body, "{}")
        XCTAssertEqual(request.url.absoluteString, "https://192.168.1.10/api")
        for bad: JSONObject in [
            ["trust": "alfen"],
            ["trust": [:] as JSONObject],
            ["trust": ["anchors": [1]]],
            ["method": "HEAD"],
            ["timeoutMs": 0],
            ["requestId": 1],
            ["requestId": ""],
            ["headers": ["a": 1]],
            ["headers": ["Bad Name": "x"]],
            ["headers": ["X-Evil": "a\r\nHost: elsewhere"]],
            // A GET has no body (as on Android).
            ["body": "x"],
            ["url": "not a url"],
            ["url": "/relative"],
        ] {
            assertCode("invalidParams", "\(bad)") { _ = try Bridge.httpRequest(Params(self.httpParams(bad))) }
        }
        XCTAssertNil(try Bridge.httpRequest(Params(httpParams(["body": ""]))).body, "an empty body on GET is no body")
        for url in ["ftp://192.168.1.10/", "ws://192.168.1.10/", "http://%31%30.0.0.1/", "http://010.0.0.1/"] {
            assertCode("forbiddenHost", url) { _ = try Bridge.httpRequest(Params(self.httpParams(["url": url]))) }
        }
        assertCode("forbiddenHost") {
            _ = try Bridge.httpRequest(Params(self.httpParams(["url": "https://8.8.8.8/", "trust": ["fingerprints": [TrustTests.ecFingerprint]]])))
        }
    }

    func testWebSocketOpenTakesATrust() throws {
        let request = try Bridge.webSocketOpenRequest(Params([
            "socketId": "s1", "url": "wss://charger.local/ws", "headers": ["Cookie": "a=1"],
            "trust": ["anchors": [try TrustTests.pem("test-device-ca")], "ignoreHostname": true],
        ]))
        XCTAssertEqual(request.socketId, "s1")
        XCTAssertEqual(request.headers, ["Cookie": "a=1"])
        XCTAssertEqual(request.trust?.ignoreHostname, true)
        XCTAssertNil(try Bridge.webSocketOpenRequest(Params(["socketId": "s1", "url": "ws://10.0.0.2/ws"])).trust)
        assertCode("invalidParams") { _ = try Bridge.webSocketOpenRequest(Params(["socketId": "s1", "url": "wss://10.0.0.2/", "trust": "x"])) }
        assertCode("forbiddenHost") { _ = try Bridge.webSocketOpenRequest(Params(["socketId": "s1", "url": "wss://example.com/"])) }
    }

    // MARK: - tcp (§9.6)

    func testTCPOpenRequest() throws {
        let plain = try Bridge.tcpOpenRequest(Params(["socketId": "s1", "host": "192.168.1.20", "port": 502]))
        XCTAssertEqual(plain.socketId, "s1")
        XCTAssertEqual(plain.host, "192.168.1.20")
        XCTAssertEqual(plain.port, 502)
        XCTAssertEqual(plain.timeoutMs, 10_000)
        XCTAssertNil(plain.tls)
        XCTAssertFalse(plain.routeTraffic)

        let tls = try Bridge.tcpOpenRequest(Params([
            "socketId": "s2", "host": "[::1]", "port": 8883, "timeoutMs": 100,
            "tls": ["serverName": "charger.local", "trust": ["fingerprints": [TrustTests.ecFingerprint]]],
        ]), routeTraffic: true)
        XCTAssertEqual(tls.host, "::1")
        XCTAssertEqual(tls.timeoutMs, 500, "clamped to 500 ms")
        XCTAssertEqual(tls.tls?.serverName, "charger.local")
        XCTAssertEqual(tls.tls?.trust?.fingerprints.count, 1)
        XCTAssertTrue(tls.routeTraffic)

        let systemTrust = try Bridge.tcpOpenRequest(Params(["socketId": "s3", "host": "charger.local", "port": 443, "tls": [:] as JSONObject, "timeoutMs": 60_000]))
        XCTAssertNotNil(systemTrust.tls)
        XCTAssertNil(systemTrust.tls?.trust)
        XCTAssertEqual(systemTrust.timeoutMs, 30_000)
    }

    func testTCPOpenRejectsBadParams() {
        let base: JSONObject = ["socketId": "s1", "host": "10.0.0.2", "port": 502]
        func with(_ overrides: JSONObject, without: [String] = []) -> JSONObject {
            var params = base
            for (key, value) in overrides { params[key] = value }
            for key in without { params.removeValue(forKey: key) }
            return params
        }
        for params in [
            with([:], without: ["socketId"]),
            with(["socketId": ""]),
            with(["socketId": 1]),
            with([:], without: ["port"]),
            with(["port": 0]),
            with(["port": 70_000]),
            with(["port": "502"]),
            with(["timeoutMs": 0]),
            with(["tls": true]),
            with(["tls": ["serverName": "bad name"]]),
            with(["tls": ["serverName": ""]]),
            with(["tls": ["trust": "alfen"]]),
            with(["tls": ["trust": [:] as JSONObject]]),
            // Params before the host.
            with(["host": "8.8.8.8", "port": 0]),
        ] {
            assertCode("invalidParams", "\(params)") { _ = try Bridge.tcpOpenRequest(Params(params)) }
        }
        for host in ["8.8.8.8", "example.com", "172.32.0.1", "fe80::1", "224.0.0.251"] {
            assertCode("forbiddenHost", host) { _ = try Bridge.tcpOpenRequest(Params(with(["host": host]))) }
        }
    }

    func testTCPWriteNeedsBase64() throws {
        XCTAssertEqual(try Params(["data": "AAEC"]).base64("data"), Data([0, 1, 2]))
        XCTAssertEqual(try Params(["data": "AAE"]).base64("data"), Data([0, 1]), "padding optional")
        XCTAssertEqual(try Params(["data": ""]).base64("data"), Data())
        for bad: Any in ["A", "AA E", "AA-_", "%%", 1] {
            assertCode("invalidParams", "\(bad)") { _ = try Params(["data": bad]).base64("data") }
        }
    }

    // MARK: - udp (§9.7)

    func testUDPExchangeRequest() throws {
        let request = try Bridge.udpExchangeRequest(Params(["host": "192.168.1.30", "port": 7090, "data": "cmVwb3J0IDE=", "timeoutMs": 2000]))
        XCTAssertEqual(request.host, "192.168.1.30")
        XCTAssertEqual(request.port, 7090)
        XCTAssertEqual(String(decoding: request.data, as: UTF8.self), "report 1")
        XCTAssertEqual(request.timeoutMs, 2000)
        XCTAssertEqual(request.maxReplies, 1)
        func timeout(_ value: Double) throws -> Int {
            try Bridge.udpExchangeRequest(Params(["host": "10.0.0.2", "port": 1, "data": "", "timeoutMs": value])).timeoutMs
        }
        XCTAssertEqual(try timeout(10), 100, "at least 100 ms")
        XCTAssertEqual(try timeout(99_999), 30_000, "at most 30 s")
        let many = try Bridge.udpExchangeRequest(Params(["host": "charger.local", "port": 1, "data": "", "timeoutMs": 500, "maxReplies": 1_000]), routeTraffic: true)
        XCTAssertEqual(many.maxReplies, 1_000)
        XCTAssertTrue(many.routeTraffic)
    }

    func testUDPIsUnicastOnly() {
        for host in ["224.0.0.251", "239.255.255.250", "255.255.255.255", "240.0.0.1", "8.8.8.8", "example.com", "ff02::1"] {
            assertCode("forbiddenHost", host) {
                _ = try Bridge.udpExchangeRequest(Params(["host": host, "port": 5353, "data": "AA==", "timeoutMs": 500]))
            }
        }
    }

    func testUDPExchangeRejectsBadParams() {
        let base: JSONObject = ["host": "10.0.0.2", "port": 7090, "data": "AA==", "timeoutMs": 500]
        for (key, value) in [
            ("port", 0), ("port", "7090"), ("data", "not base64!"), ("data", 1), ("timeoutMs", 0), ("timeoutMs", "500"),
            ("maxReplies", 0), ("maxReplies", 1.5), ("maxReplies", "2"), ("maxReplies", 1_001), ("maxReplies", 1e9),
        ] as [(String, Any)] {
            var params = base
            params[key] = value
            assertCode("invalidParams", "\(key): \(value)") { _ = try Bridge.udpExchangeRequest(Params(params)) }
        }
        var noTimeout = base
        noTimeout.removeValue(forKey: "timeoutMs")
        assertCode("invalidParams") { _ = try Bridge.udpExchangeRequest(Params(noTimeout)) }
        var tooBig = base
        tooBig["data"] = Data(count: UDPExchanges.maxDatagramBytes + 1).base64EncodedString()
        assertCode("invalidParams") { _ = try Bridge.udpExchangeRequest(Params(tooBig)) }
    }

    // MARK: - Shared rules (the same cases as Android's ParamsTest)

    func testLocalHostsAreAllowed() {
        for host in [
            "10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.50.10", "169.254.1.1", "127.0.0.1", "localhost", "localhost.",
            "charger.local", "CHARGER.local", "charger.local.", "ng910-60623-ace0870096.local", "a_b.local", "::1", "[::1]",
        ] {
            XCTAssertTrue(LocalHostPolicy.isAllowedHost(host), host)
        }
    }

    func testEverythingElseIsRefused() {
        for host in [
            "8.8.8.8", "172.32.0.1", "example.com", "plugchoice.com", "192.168.1", "010.0.0.1", "10.0.0.01", "167772161",
            "192.168.1.10:443", "", "fe80::1", "fe80::1%en0", ".local", "a..local", "char ger.local", "charger%2elocal", "10.0.0.1.",
        ] {
            XCTAssertFalse(LocalHostPolicy.isAllowedHost(host), host)
        }
    }

    func testHeadersAreTokensWithVisibleASCIIValues() throws {
        XCTAssertEqual(
            try Bridge.checkedHeaders(Params(["headers": ["Cookie": "a=1; b=2", "X-Tab": "a\tb"]])),
            ["Cookie": "a=1; b=2", "X-Tab": "a\tb"]
        )
        XCTAssertEqual(try Bridge.checkedHeaders(Params([:])), [:])
        for bad: JSONObject in [
            ["Bad Name": "x"],
            ["": "x"],
            ["X-Evil": "a\r\nHost: elsewhere"],
            ["X-Accent": "caf\u{e9}"],
            ["X-Control": "a\u{1}"],
            ["Accept": 1],
            ["Accept": true],
        ] {
            assertCode("invalidParams", "\(bad)") { _ = try Bridge.checkedHeaders(Params(["headers": bad])) }
        }
    }

    func testTimeoutsArePositiveAndRoundedUp() throws {
        XCTAssertEqual(try Params(["t": 0.5]).timeoutMs("t"), 1)
        XCTAssertEqual(try Params(["t": 2_500.2]).timeoutMs("t"), 2_501)
        XCTAssertEqual(try Params(["t": 1e300]).timeoutMs("t"), Int(Int32.max))
        for bad: Any in [0, -1, "1000", true] {
            assertCode("invalidParams", "\(bad)") { _ = try Params(["t": bad]).timeoutMs("t") }
        }
        assertCode("invalidParams") { _ = try Params([:]).timeoutMs("t") }
    }

    func testIdsAreNonEmptyStrings() throws {
        assertCode("invalidParams") { _ = try Params(["requestId": ""]).string("requestId") }
        assertCode("invalidParams") { _ = try Params(["requestId": 1]).string("requestId") }
        XCTAssertEqual(try Params(["password": ""]).string("password", allowEmpty: true), "")
    }

    // MARK: - Helpers

    func assertCode(_ code: String, _ message: String = "", file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void) {
        do {
            try body()
            XCTFail("expected \(code) \(message)", file: file, line: line)
        } catch {
            XCTAssertEqual((error as? BridgeError)?.code, code, message, file: file, line: line)
        }
    }
}
