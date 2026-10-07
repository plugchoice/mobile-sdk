import Foundation

/// HTTP/1.1 framing for `http.session` (PROTOCOL §9.5): requests go out on
/// one kept-alive TLS connection, so the shell writes and reads the messages
/// itself instead of handing them to URLSession (which pools connections and
/// silently opens new ones).
enum HTTP1 {
    /// Headers the shell writes itself; the page's values for them are
    /// dropped. A page-supplied `Connection: close` would end the session, and
    /// a second `Content-Length` would corrupt the framing.
    static let shellOwnedHeaders: Set<String> = ["host", "content-length", "transfer-encoding", "connection"]

    /// Largest header section and body accepted from a device.
    static let maxHeaderBytes = 64 * 1024
    static let maxBodyBytes = 16 * 1024 * 1024

    struct Response: Equatable {
        let status: Int
        /// Lower-cased names; repeated headers joined with ", ".
        let headers: [String: String]
        let body: Data
        /// The device closes the connection after this response.
        let closesConnection: Bool

        var json: JSONObject {
            ["status": status, "headers": headers, "body": String(decoding: body, as: UTF8.self)]
        }
    }

    // MARK: - Requests

    /// `GET`/`POST`/`PUT` with an origin-form `path`. POST and PUT always
    /// carry an explicit `Content-Length` (0 without a body); the device
    /// rejects chunked bodies, so there never is one.
    static func encodeRequest(method: String, path: String, host: String, port: Int, headers: [String: String], body: Data?) -> Data {
        var head = "\(method) \(path) HTTP/1.1\r\n"
        head += "Host: \(hostHeader(host: host, port: port))\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key })
        where !shellOwnedHeaders.contains(name.lowercased()) {
            head += "\(name): \(value)\r\n"
        }
        let payload = body ?? Data()
        if method != "GET" {
            head += "Content-Length: \(payload.count)\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        if method != "GET" {
            data.append(payload)
        }
        return data
    }

    static func hostHeader(host: String, port: Int) -> String {
        let name = host.contains(":") ? "[\(host)]" : host
        return port == 443 ? name : "\(name):\(port)"
    }

    /// An origin-form request target: starts with `/`, printable ASCII, no
    /// spaces and no fragment.
    static func isValidPath(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        return path.utf8.allSatisfy { $0 > 0x20 && $0 < 0x7F && $0 != UInt8(ascii: "#") }
    }

    /// A header name is an RFC 9110 token.
    static func isValidHeaderName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.allSatisfy { byte in
            (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
                || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
                || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                || "!#$%&'*+-.^_`|~".utf8.contains(byte)
        }
    }

    /// Visible ASCII, spaces and tabs: no control characters (CR and LF
    /// would split the header section) and nothing a client library would
    /// encode its own way.
    static func isValidHeaderValue(_ value: String) -> Bool {
        value.utf8.allSatisfy { $0 == 0x09 || (0x20...0x7E).contains($0) }
    }

    // MARK: - Responses

    struct ParseError: Error, Equatable {
        let message: String
    }

    /// Reads one response from the bytes of a connection, fed as they
    /// arrive. Bodies framed by `Content-Length`, chunked, or by the end of
    /// the connection; 1xx interim responses are skipped.
    struct ResponseParser {
        private enum State {
            case head
            case fixed(remaining: Int)
            case chunkSize
            case chunkData(remaining: Int)
            case chunkDataEnd
            case trailers
            case untilClose
        }

        private var buffer: [UInt8] = []
        private var state = State.head
        private var status = 0
        private var headers: [String: String] = [:]
        private var closes = false
        private var body: [UInt8] = []

        /// Feeds received bytes; returns the response once it is complete.
        /// Bytes after it stay buffered for the next one.
        mutating func feed(_ data: Data) throws -> Response? {
            buffer.append(contentsOf: data)
            return try advance()
        }

        /// The connection ended: completes a body read until the close, and
        /// fails anything else that is unfinished.
        mutating func finish() throws -> Response {
            if case .untilClose = state {
                body.append(contentsOf: buffer)
                buffer.removeAll()
                return try complete()
            }
            throw ParseError(message: "the device closed the connection before the response was complete")
        }

        private mutating func advance() throws -> Response? {
            while true {
                switch state {
                case .head:
                    guard let end = find([0x0D, 0x0A, 0x0D, 0x0A]) else {
                        if buffer.count > HTTP1.maxHeaderBytes {
                            throw ParseError(message: "response header section is too large")
                        }
                        return nil
                    }
                    let head = Array(buffer[0..<end])
                    buffer.removeFirst(end + 4)
                    if let response = try parseHead(head) {
                        return response
                    }
                case .fixed(let remaining):
                    let count = min(remaining, buffer.count)
                    body.append(contentsOf: buffer[0..<count])
                    buffer.removeFirst(count)
                    if remaining - count > 0 {
                        state = .fixed(remaining: remaining - count)
                        return nil
                    }
                    return try complete()
                case .chunkSize:
                    guard let line = takeLine() else { return nil }
                    let sizeText = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
                        .trimmingCharacters(in: .whitespaces)
                    guard let size = Int(sizeText, radix: 16), size >= 0 else {
                        throw ParseError(message: "bad chunk size")
                    }
                    guard body.count + size <= HTTP1.maxBodyBytes else {
                        throw ParseError(message: "response body is too large")
                    }
                    state = size == 0 ? .trailers : .chunkData(remaining: size)
                case .chunkData(let remaining):
                    let count = min(remaining, buffer.count)
                    body.append(contentsOf: buffer[0..<count])
                    buffer.removeFirst(count)
                    if remaining - count > 0 {
                        state = .chunkData(remaining: remaining - count)
                        return nil
                    }
                    state = .chunkDataEnd
                case .chunkDataEnd:
                    guard let line = takeLine() else { return nil }
                    guard line.isEmpty else { throw ParseError(message: "bad chunk framing") }
                    state = .chunkSize
                case .trailers:
                    guard let line = takeLine() else { return nil }
                    if line.isEmpty { return try complete() }
                case .untilClose:
                    body.append(contentsOf: buffer)
                    buffer.removeAll()
                    if body.count > HTTP1.maxBodyBytes {
                        throw ParseError(message: "response body is too large")
                    }
                    return nil
                }
            }
        }

        /// Parses a status line and headers. Returns the response when it has
        /// no body.
        private mutating func parseHead(_ head: [UInt8]) throws -> Response? {
            let text = String(decoding: head, as: UTF8.self)
            var lines = text.components(separatedBy: "\r\n")
            let statusLine = lines.removeFirst()
            let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."),
                  parts[1].count == 3, let code = Int(parts[1]), (100...999).contains(code)
            else {
                throw ParseError(message: "not an HTTP/1.x response")
            }
            var parsed: [String: String] = [:]
            for line in lines where !line.isEmpty {
                guard let colon = line.firstIndex(of: ":") else {
                    throw ParseError(message: "bad header line")
                }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if let existing = parsed[name] {
                    parsed[name] = existing + ", " + value
                } else {
                    parsed[name] = value
                }
            }
            // Interim responses (100 Continue and the like): the real one follows.
            if (100..<200).contains(code), code != 101 {
                return nil
            }
            status = code
            headers = parsed
            body = []
            let connection = Set((parsed["connection"] ?? "").lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            let http10 = parts[0] == "HTTP/1.0"
            closes = connection.contains("close") || (http10 && !connection.contains("keep-alive"))

            if code == 204 || code == 304 || (100..<200).contains(code) {
                return try complete()
            }
            if let encoding = parsed["transfer-encoding"]?.lowercased(), encoding.contains("chunked") {
                state = .chunkSize
                return nil
            }
            if let lengthText = parsed["content-length"] {
                // Repeated identical values are joined above ("5, 5").
                let values = Set(lengthText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
                guard values.count == 1, let length = Int(values.first!), length >= 0 else {
                    throw ParseError(message: "bad Content-Length")
                }
                guard length <= HTTP1.maxBodyBytes else {
                    throw ParseError(message: "response body is too large")
                }
                if length == 0 { return try complete() }
                state = .fixed(remaining: length)
                return nil
            }
            // No length: the body runs until the device closes the connection.
            closes = true
            state = .untilClose
            return nil
        }

        private mutating func complete() throws -> Response {
            let response = Response(status: status, headers: headers, body: Data(body), closesConnection: closes)
            state = .head
            status = 0
            headers = [:]
            body = []
            closes = false
            return response
        }

        /// One CRLF-terminated line without its CRLF, or nil if incomplete.
        private mutating func takeLine() -> String? {
            guard let end = find([0x0D, 0x0A]) else { return nil }
            let line = String(decoding: buffer[0..<end], as: UTF8.self)
            buffer.removeFirst(end + 2)
            return line
        }

        private func find(_ pattern: [UInt8]) -> Int? {
            guard buffer.count >= pattern.count else { return nil }
            var index = 0
            while index <= buffer.count - pattern.count {
                if buffer[index] == pattern[0], Array(buffer[index..<(index + pattern.count)]) == pattern {
                    return index
                }
                index += 1
            }
            return nil
        }
    }
}
