import Foundation

typealias JSONObject = [String: Any]

/// An error answered to the page as
/// `{ ok: false, error: { code, message, details? } }`. `code` is one of the
/// camelCase codes from PROTOCOL.md; `details` carries extra fields,
/// such as a `tls` error's `presentedFingerprint`.
struct BridgeError: Error, Equatable {
    let code: String
    let message: String
    var details: [String: String]?

    init(code: String, message: String, details: [String: String]? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }

    /// The `error` object of a response.
    var json: JSONObject {
        var object: JSONObject = ["code": code, "message": message]
        if let details { object["details"] = details }
        return object
    }

    static func invalidParams(_ message: String) -> BridgeError {
        BridgeError(code: "invalidParams", message: message)
    }

    static func unsupportedMethod(_ method: String) -> BridgeError {
        BridgeError(code: "unsupportedMethod", message: "unsupported method \(method)")
    }

    static func `internal`(_ message: String) -> BridgeError {
        BridgeError(code: "internal", message: message)
    }

    static func from(_ error: Error) -> BridgeError {
        if let bridgeError = error as? BridgeError { return bridgeError }
        if error is CancellationError { return BridgeError(code: "cancelled", message: "cancelled") }
        return .internal(String(describing: error))
    }
}

/// Typed, validating access to a request's `params` object. Every mismatch
/// throws `invalidParams`.
struct Params {
    let raw: JSONObject

    init(_ raw: JSONObject) {
        self.raw = raw
    }

    private func value(_ key: String) -> Any? {
        guard let value = raw[key], !(value is NSNull) else { return nil }
        return value
    }

    /// A required string, non-empty unless `allowEmpty`.
    func string(_ key: String, allowEmpty: Bool = false) throws -> String {
        guard let string = try optionalString(key), allowEmpty || !string.isEmpty else {
            throw BridgeError.invalidParams("\(key) is required and must be a \(allowEmpty ? "" : "non-empty ")string")
        }
        return string
    }

    func optionalString(_ key: String) throws -> String? {
        guard let value = value(key) else { return nil }
        guard let string = value as? String else {
            throw BridgeError.invalidParams("\(key) must be a string")
        }
        return string
    }

    func number(_ key: String) throws -> Double {
        guard let number = try optionalNumber(key) else {
            throw BridgeError.invalidParams("\(key) is required and must be a number")
        }
        return number
    }

    func optionalNumber(_ key: String) throws -> Double? {
        guard let value = value(key) else { return nil }
        guard let number = value as? NSNumber, !number.isBool, number.doubleValue.isFinite else {
            throw BridgeError.invalidParams("\(key) must be a number")
        }
        return number.doubleValue
    }

    func bool(_ key: String) throws -> Bool {
        guard let value = value(key) else {
            throw BridgeError.invalidParams("\(key) is required and must be a boolean")
        }
        guard let number = value as? NSNumber, number.isBool else {
            throw BridgeError.invalidParams("\(key) must be a boolean")
        }
        return number.boolValue
    }

    func optionalBool(_ key: String) throws -> Bool? {
        guard value(key) != nil else { return nil }
        return try bool(key)
    }

    func optionalObject(_ key: String) throws -> JSONObject? {
        guard let value = value(key) else { return nil }
        guard let object = value as? JSONObject else {
            throw BridgeError.invalidParams("\(key) must be an object")
        }
        return object
    }

    func stringArray(_ key: String) throws -> [String] {
        guard let array = try optionalStringArray(key) else {
            throw BridgeError.invalidParams("\(key) is required and must be an array of strings")
        }
        return array
    }

    func optionalStringArray(_ key: String) throws -> [String]? {
        guard let value = value(key) else { return nil }
        guard let array = value as? [Any] else {
            throw BridgeError.invalidParams("\(key) must be an array of strings")
        }
        return try array.map { element in
            guard let string = element as? String else {
                throw BridgeError.invalidParams("\(key) must be an array of strings")
            }
            return string
        }
    }

    /// A `Record<string, string>`; absent means empty.
    func stringMap(_ key: String) throws -> [String: String] {
        guard let object = try optionalObject(key) else { return [:] }
        var map: [String: String] = [:]
        for (name, value) in object {
            guard let string = value as? String else {
                throw BridgeError.invalidParams("\(key).\(name) must be a string")
            }
            map[name] = string
        }
        return map
    }

    /// A whole number in `range`, or nil when absent.
    func optionalInteger(_ key: String, in range: ClosedRange<Int>) throws -> Int? {
        guard let value = try optionalNumber(key) else { return nil }
        guard value.rounded() == value, value >= Double(range.lowerBound), value <= Double(range.upperBound) else {
            throw BridgeError.invalidParams("\(key) must be a whole number from \(range.lowerBound) to \(range.upperBound)")
        }
        return Int(value)
    }

    /// Standard base64 bytes (`=` padding optional); empty is no bytes.
    func base64(_ key: String) throws -> Data {
        guard let data = Base64.decode(try string(key, allowEmpty: true)) else {
            throw BridgeError.invalidParams("\(key) must be base64")
        }
        return data
    }

    /// A required positive `timeoutMs`, as whole milliseconds (rounded up),
    /// at most `Int32.max`.
    func timeoutMs(_ key: String = "timeoutMs") throws -> Int {
        let value = try number(key)
        guard value > 0 else {
            throw BridgeError.invalidParams("\(key) must be a positive number")
        }
        return Int(min(value.rounded(.up), Double(Int32.max)))
    }
}

/// Bytes in messages travel as standard base64.
enum Base64 {
    /// Standard base64, with or without `=` padding; nil for anything else
    /// (whitespace and the base64url alphabet included).
    static func decode(_ text: String) -> Data? {
        guard text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=") }) else {
            return nil
        }
        var padded = text
        if !padded.hasSuffix("=") {
            guard padded.count % 4 != 1 else { return nil }
            padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
        }
        return Data(base64Encoded: padded)
    }
}

extension NSNumber {
    /// JSONSerialization hands back booleans as NSNumber too; tell them apart.
    var isBool: Bool { CFGetTypeID(self) == CFBooleanGetTypeID() }
}

enum BridgeScript {
    /// `window.PlugchoiceLinkBridge.receive("<json>")`. The message is
    /// serialised to JSON, and that JSON text is then embedded as a JS string
    /// literal by a JSON encoder (a JSON string literal is a valid JS string
    /// literal), so nothing is escaped by hand.
    static func receive(_ message: JSONObject) throws -> String {
        guard JSONSerialization.isValidJSONObject(message) else {
            throw BridgeError.internal("message is not valid JSON")
        }
        let json = try JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])
        guard let text = String(data: json, encoding: .utf8) else {
            throw BridgeError.internal("message is not UTF-8")
        }
        let literal = String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
        return "window.PlugchoiceLinkBridge.receive(\(literal));"
    }
}

/// Runs `body` on the main actor: right away when already on the main thread
/// (callbacks of the main-queue URLSessions), otherwise on the next turn of
/// the main queue. Keeps callback order intact on the main queue.
func onMain(_ body: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(body)
    } else {
        DispatchQueue.main.async {
            MainActor.assumeIsolated(body)
        }
    }
}
