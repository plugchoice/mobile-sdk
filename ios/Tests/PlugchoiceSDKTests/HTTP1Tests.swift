import XCTest
@testable import PlugchoiceSDK

/// The HTTP/1.1 framing under `http.session`.
final class HTTP1Tests: XCTestCase {
    private func parse(_ chunks: [String], end: Bool = false) throws -> HTTP1.Response? {
        var parser = HTTP1.ResponseParser()
        for chunk in chunks {
            if let response = try parser.feed(Data(chunk.utf8)) { return response }
        }
        return end ? try parser.finish() : nil
    }

    func testContentLengthBodyAcrossReads() throws {
        let response = try XCTUnwrap(try parse(["HTTP/1.1 200 OK\r\nContent-Length: 11\r\n", "\r\nhello", " world"]))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "hello world")
        XCTAssertFalse(response.closesConnection)
    }

    func testChunkedBodyWithExtensionsAndTrailers() throws {
        let response = try XCTUnwrap(try parse([
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
            "5;name=value\r\nhello\r\n",
            "6\r\n world\r\n0\r\nX-Trailer: 1\r\n\r\n",
        ]))
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "hello world")
    }

    func testBodyUntilClose() throws {
        XCTAssertNil(try parse(["HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nall of it"]))
        let response = try XCTUnwrap(try parse(["HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nall ", "of it"], end: true))
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "all of it")
        XCTAssertTrue(response.closesConnection)
    }

    func testNoBodyResponses() throws {
        XCTAssertEqual(try parse(["HTTP/1.1 204 No Content\r\n\r\n"])?.body, Data())
        XCTAssertEqual(try parse(["HTTP/1.1 304 Not Modified\r\nContent-Length: 10\r\n\r\n"])?.status, 304)
        XCTAssertEqual(try parse(["HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n"])?.status, 401)
    }

    func testInterimResponsesAreSkipped() throws {
        let response = try XCTUnwrap(try parse(["HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 201 Created\r\nContent-Length: 2\r\n\r\nok"]))
        XCTAssertEqual(response.status, 201)
    }

    func testHeadersAreLowerCasedAndRepeatsJoined() throws {
        let response = try XCTUnwrap(try parse(["HTTP/1.1 200 OK\r\nSet-Cookie: a=1\r\nset-cookie: b=2\r\nX-Thing:  spaced \r\nContent-Length: 0\r\n\r\n"]))
        XCTAssertEqual(response.headers["set-cookie"], "a=1, b=2")
        XCTAssertEqual(response.headers["x-thing"], "spaced")
        XCTAssertEqual(response.headers["content-length"], "0")
    }

    func testConnectionClose() throws {
        XCTAssertEqual(try parse(["HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"])?.closesConnection, true)
        XCTAssertEqual(try parse(["HTTP/1.0 200 OK\r\nContent-Length: 0\r\n\r\n"])?.closesConnection, true)
        XCTAssertEqual(try parse(["HTTP/1.0 200 OK\r\nConnection: keep-alive\r\nContent-Length: 0\r\n\r\n"])?.closesConnection, false)
        XCTAssertEqual(try parse(["HTTP/1.1 200 OK\r\nConnection: Keep-Alive\r\nContent-Length: 0\r\n\r\n"])?.closesConnection, false)
    }

    func testBytesAfterAResponseStayForTheNextOne() throws {
        var parser = HTTP1.ResponseParser()
        let first = try parser.feed(Data("HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\naHTTP/1.1 202 Accepted\r\nContent-Length: 1\r\n\r\n".utf8))
        XCTAssertEqual(first?.status, 200)
        let second = try parser.feed(Data("b".utf8))
        XCTAssertEqual(second?.status, 202)
        XCTAssertEqual(second?.body, Data("b".utf8))
    }

    func testMalformedResponses() {
        XCTAssertThrowsError(try parse(["SSH-2.0-OpenSSH_9.0\r\n\r\n"]))
        XCTAssertThrowsError(try parse(["HTTP/1.1 2000 OK\r\n\r\n"]))
        XCTAssertThrowsError(try parse(["HTTP/1.1 200 OK\r\nno colon here\r\n\r\n"]))
        XCTAssertThrowsError(try parse(["HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n"]))
        XCTAssertThrowsError(try parse(["HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n"]))
        XCTAssertThrowsError(try parse(["HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n"]))
        XCTAssertThrowsError(try parse(["HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort"], end: true), "closed before the body was complete")
        XCTAssertThrowsError(try parse(["HTTP/1.1 200 OK\r\nContent-Le"], end: true))
    }

    func testRequestEncoding() {
        let get = HTTP1.encodeRequest(method: "GET", path: "/api/info", host: "10.206.2.88", port: 443, headers: ["Accept": "application/json"], body: nil)
        XCTAssertEqual(String(decoding: get, as: UTF8.self), "GET /api/info HTTP/1.1\r\nHost: 10.206.2.88\r\nAccept: application/json\r\n\r\n")
        let put = HTTP1.encodeRequest(method: "PUT", path: "/x", host: "::1", port: 8443, headers: ["transfer-encoding": "chunked"], body: Data("héllo".utf8))
        XCTAssertEqual(String(decoding: put, as: UTF8.self), "PUT /x HTTP/1.1\r\nHost: [::1]:8443\r\nContent-Length: 6\r\n\r\nhéllo")
    }

    func testRequestValidation() {
        XCTAssertTrue(HTTP1.isValidPath("/"))
        XCTAssertTrue(HTTP1.isValidPath("/api/prop?ids=2053_0,20F0_3&offset=32"))
        XCTAssertFalse(HTTP1.isValidPath(""))
        XCTAssertFalse(HTTP1.isValidPath("api"))
        XCTAssertFalse(HTTP1.isValidPath("/a\r\nHost: x"))
        XCTAssertTrue(HTTP1.isValidHeaderName("Content-Type"))
        XCTAssertFalse(HTTP1.isValidHeaderName("Content Type"))
        XCTAssertFalse(HTTP1.isValidHeaderName(""))
        XCTAssertFalse(HTTP1.isValidHeaderName("X:Y"))
        XCTAssertTrue(HTTP1.isValidHeaderValue("application/json; charset=utf-8"))
        XCTAssertFalse(HTTP1.isValidHeaderValue("a\nb"))
    }
}
