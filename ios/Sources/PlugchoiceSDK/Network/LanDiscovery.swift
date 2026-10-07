import Foundation
import Network

/// `lan.discover` / `lan.stopDiscovery` (PROTOCOL §9.4): browses
/// DNS-SD on the network the phone is on and resolves what it finds.
///
/// Any service type, as long as the host app declares it in
/// `NSBonjourServices`: iOS refuses to browse anything else, so an
/// undeclared type answers `undeclaredServiceType` (`hello`'s
/// `lanServiceTypes` lists the declared ones).
///
/// NWBrowser browses: unlike NetServiceBrowser it reports a missing Local
/// Network permission (it waits with `kDNSServiceErr_PolicyDenied`, and
/// resumes when the user allows). NetService resolves each instance: it hands
/// over the addresses without opening a connection to the device, whose web
/// server may serve one client at a time.
@MainActor
final class LanDiscovery {
    /// The host's `NSBonjourServices`, in its order, without trailing dots.
    nonisolated static var declaredServiceTypes: [String] {
        declaredTypes(Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices"))
    }

    /// Whether `hello` lists `lan.discover`: the host declares at least one
    /// type.
    nonisolated static func isAvailable(declared: [String]) -> Bool {
        !declared.isEmpty
    }

    /// `NSBonjourServices` entries, with a trailing dot or not, each once.
    nonisolated static func declaredTypes(_ value: Any?) -> [String] {
        guard let entries = value as? [Any] else { return [] }
        var types: [String] = []
        for entry in entries {
            guard let type = entry as? String, !type.isEmpty else { continue }
            let trimmed = type.hasSuffix(".") ? String(type.dropLast()) : type
            if !trimmed.isEmpty, !types.contains(trimmed) {
                types.append(trimmed)
            }
        }
        return types
    }

    /// A DNS-SD service type: `_name._tcp` or `_name._udp` (subtype labels
    /// allowed), a trailing dot optional.
    nonisolated private static let serviceType = try! NSRegularExpression(pattern: "^(_[A-Za-z0-9][A-Za-z0-9-]{0,62}\\.)+_(tcp|udp)\\.?$")

    nonisolated static func isServiceType(_ type: String) -> Bool {
        serviceType.firstMatch(in: type, range: NSRange(type.startIndex..., in: type)) != nil
    }

    /// Checks `types`: each a service type (`invalidParams` otherwise),
    /// without its trailing dot, once; then against the host's declarations
    /// (`undeclaredServiceType`).
    nonisolated static func checkedTypes(_ types: [String], declared: [String] = declaredServiceTypes) throws -> [String] {
        guard !types.isEmpty else {
            throw BridgeError.invalidParams("types must not be empty")
        }
        var checked: [String] = []
        for type in types {
            guard isServiceType(type) else {
                throw BridgeError.invalidParams("\(type) is not a DNS-SD service type")
            }
            let trimmed = type.hasSuffix(".") ? String(type.dropLast()) : type
            if !checked.contains(trimmed) { checked.append(trimmed) }
        }
        for type in checked where !declared.contains(type) {
            throw BridgeError(code: "undeclaredServiceType", message: "\(type) is not in the host app's NSBonjourServices")
        }
        return checked
    }

    private var browse: Browse?

    var isRunning: Bool { browse != nil }

    /// Throws `busy` while another browse runs.
    func discover(
        types: [String],
        timeoutMs: Int,
        stopOnName: String?,
        completion: @escaping (Result<JSONObject, BridgeError>) -> Void
    ) throws {
        guard browse == nil else {
            throw BridgeError(code: "busy", message: "a lan.discover is already running")
        }
        let browse = Browse(types: types, stopOnName: stopOnName)
        self.browse = browse
        browse.start(timeoutMs: timeoutMs) { [weak self, weak browse] result in
            if let self, self.browse === browse { self.browse = nil }
            completion(result)
        }
    }

    /// `lan.stopDiscovery`: the running browse answers with what it found.
    func stop() {
        browse?.finish()
    }

    /// The page is gone: stops without answering.
    func cancel() {
        let running = browse
        browse = nil
        running?.cancel()
    }
}

/// What a browse found, in the order found. Pure, so tests can drive it.
struct DiscoveredServices {
    private struct Entry {
        let name: String
        var addresses: [String] = []
        var port = 0
        var txt: [String: String] = [:]
    }

    let stopOnName: String?
    private var keys: [String] = []
    private var entries: [String: Entry] = [:]

    init(stopOnName: String?) {
        self.stopOnName = stopOnName
    }

    var isEmpty: Bool { keys.isEmpty }

    /// An instance turned up (not resolved yet). `txt` from the browse, when
    /// it carries one.
    mutating func found(name: String, type: String, txt: [String: String]? = nil) {
        let key = Self.key(name: name, type: type)
        if entries[key] == nil {
            keys.append(key)
            entries[key] = Entry(name: name)
        }
        if let txt, !txt.isEmpty { entries[key]?.txt = txt }
    }

    /// An instance resolved (possibly again, with more addresses). Returns
    /// true when the browse should stop: its name matches `stopOnName` and
    /// it has an IPv4 address.
    mutating func resolved(name: String, type: String, addresses: [String], port: Int, txt: [String: String]?) -> Bool {
        found(name: name, type: type, txt: txt)
        let key = Self.key(name: name, type: type)
        var entry = entries[key]!
        for address in addresses where !entry.addresses.contains(address) {
            entry.addresses.append(address)
        }
        entry.addresses = Self.ipv4First(entry.addresses)
        if port > 0 { entry.port = port }
        entries[key] = entry
        return Self.matches(name: name, stopOnName: stopOnName) && entry.addresses.contains(where: Self.isIPv4)
    }

    /// `{ name, addresses, port, txt }` for each instance; `addresses` is
    /// empty and `port` 0 when resolving failed.
    var services: [JSONObject] {
        keys.compactMap { entries[$0] }.map { entry in
            ["name": entry.name, "addresses": entry.addresses, "port": entry.port, "txt": entry.txt]
        }
    }

    /// The lower-cased name contains the lower-cased `stopOnName`.
    static func matches(name: String, stopOnName: String?) -> Bool {
        guard let stopOnName else { return false }
        return name.lowercased().contains(stopOnName.lowercased())
    }

    static func isIPv4(_ address: String) -> Bool {
        LocalHostPolicy.ipv4Octets(address) != nil
    }

    private static func ipv4First(_ addresses: [String]) -> [String] {
        addresses.filter(isIPv4) + addresses.filter { !isIPv4($0) }
    }

    private static func key(name: String, type: String) -> String {
        "\(type)\u{0}\(name)"
    }
}

/// One `lan.discover` run.
@MainActor
private final class Browse {
    private static let resolveTimeout: TimeInterval = 5
    /// kDNSServiceErr_PolicyDenied.
    private static let policyDenied: Int32 = -65570

    private enum BrowserState {
        case starting
        case browsing
        case waitingForPermission
        case failed(String)
    }

    private let types: [String]
    private var results: DiscoveredServices
    private var browsers: [NWBrowser] = []
    private var states: [String: BrowserState] = [:]
    private var resolvers: [String: NetService] = [:]
    private let resolveDelegate = ResolveDelegate()
    private var completion: ((Result<JSONObject, BridgeError>) -> Void)?
    private var timer: DispatchWorkItem?

    init(types: [String], stopOnName: String?) {
        self.types = types
        results = DiscoveredServices(stopOnName: stopOnName)
    }

    func start(timeoutMs: Int, completion: @escaping (Result<JSONObject, BridgeError>) -> Void) {
        self.completion = completion
        resolveDelegate.owner = self
        for type in types {
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: "local."), using: NWParameters())
            states[type] = .starting
            browser.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    self?.browser(type, changedTo: state)
                }
            }
            browser.browseResultsChangedHandler = { [weak self] _, changes in
                MainActor.assumeIsolated {
                    self?.browser(type, changed: changes)
                }
            }
            browsers.append(browser)
            browser.start(queue: .main)
        }
        let timer = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.finish()
            }
        }
        self.timer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(timeoutMs), execute: timer)
    }

    /// Answers with what was found; `localNetworkDenied` or `network` when
    /// nothing was found because the browse couldn't run.
    func finish() {
        guard let completion else { return }
        self.completion = nil
        stopEverything()
        if results.isEmpty {
            let states = types.compactMap { self.states[$0] }
            if states.contains(where: { if case .waitingForPermission = $0 { return true } else { return false } }) {
                completion(.failure(BridgeError(code: "localNetworkDenied", message: "the Local Network permission is not granted")))
                return
            }
            let failures = states.compactMap { state -> String? in
                if case .failed(let message) = state { return message } else { return nil }
            }
            if !states.isEmpty, failures.count == states.count {
                completion(.failure(BridgeError(code: "network", message: failures.joined(separator: "; "))))
                return
            }
        }
        completion(.success(["services": results.services]))
    }

    func cancel() {
        completion = nil
        stopEverything()
    }

    private func stopEverything() {
        timer?.cancel()
        timer = nil
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
        resolvers.values.forEach { $0.stop() }
        resolvers.removeAll()
        resolveDelegate.owner = nil
    }

    // MARK: Browsing

    private func browser(_ type: String, changedTo state: NWBrowser.State) {
        guard completion != nil else { return }
        switch state {
        case .ready:
            states[type] = .browsing
        case .waiting(let error):
            // Denied, or the prompt is still up: keep browsing until the
            // deadline, it resumes if the user allows.
            if case .dns(let code) = error, code == Self.policyDenied {
                states[type] = .waitingForPermission
            }
        case .failed(let error):
            if case .dns(let code) = error, code == Self.policyDenied {
                states[type] = .waitingForPermission
            } else {
                states[type] = .failed("\(type): \(error.localizedDescription)")
            }
            // Nothing more to wait for when every browser failed.
            let failed = types.allSatisfy { if case .failed = states[$0] { return true } else { return false } }
            if failed { finish() }
        default:
            break
        }
    }

    private func browser(_ type: String, changed changes: Set<NWBrowser.Result.Change>) {
        guard completion != nil else { return }
        states[type] = .browsing
        for change in changes {
            let result: NWBrowser.Result
            switch change {
            case .added(let added): result = added
            case .changed(_, let new, _): result = new
            default: continue
            }
            guard case .service(let name, _, let domain, _) = result.endpoint else { continue }
            var txt: [String: String]?
            if case .bonjour(let record) = result.metadata {
                txt = record.dictionary
            }
            results.found(name: name, type: type, txt: txt)
            resolve(name: name, type: type, domain: domain)
        }
    }

    // MARK: Resolving

    private func resolve(name: String, type: String, domain: String) {
        let key = "\(type)\u{0}\(name)"
        guard resolvers[key] == nil else { return }
        let service = NetService(domain: domain.isEmpty ? "local." : domain, type: type.hasSuffix(".") ? type : "\(type).", name: name)
        service.delegate = resolveDelegate
        resolvers[key] = service
        resolveDelegate.types[ObjectIdentifier(service)] = type
        service.resolve(withTimeout: Self.resolveTimeout)
    }

    fileprivate func resolved(_ service: NetService, type: String) {
        guard completion != nil else { return }
        let addresses = (service.addresses ?? []).compactMap(SocketAddress.string)
        var txt: [String: String]?
        if let record = service.txtRecordData() {
            txt = NetService.dictionary(fromTXTRecord: record).mapValues { String(decoding: $0, as: UTF8.self) }
        }
        if results.resolved(name: service.name, type: type, addresses: addresses, port: service.port, txt: txt) {
            finish()
        }
    }
}

/// NetService's delegate (it calls on the main run loop) for the browse.
private final class ResolveDelegate: NSObject, NetServiceDelegate {
    weak var owner: Browse?
    var types: [ObjectIdentifier: String] = [:]

    func netServiceDidResolveAddress(_ sender: NetService) {
        MainActor.assumeIsolated {
            guard let type = types[ObjectIdentifier(sender)] else { return }
            owner?.resolved(sender, type: type)
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        // It stays in the results with no addresses.
    }
}

/// Text forms of socket addresses and of the phone's own address.
enum SocketAddress {
    /// "192.168.1.10" or "fe80::1" (no scope) from a `sockaddr` in `data`.
    static func string(_ data: Data) -> String? {
        data.withUnsafeBytes { raw -> String? in
            guard let base = raw.baseAddress, raw.count >= MemoryLayout<sockaddr>.size else { return nil }
            switch Int32(base.assumingMemoryBound(to: sockaddr.self).pointee.sa_family) {
            case AF_INET:
                guard raw.count >= MemoryLayout<sockaddr_in>.size else { return nil }
                var address = base.assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                return text(AF_INET, &address, Int(INET_ADDRSTRLEN))
            case AF_INET6:
                guard raw.count >= MemoryLayout<sockaddr_in6>.size else { return nil }
                var address = base.assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                return text(AF_INET6, &address, Int(INET6_ADDRSTRLEN))
            default:
                return nil
            }
        }
    }

    private static func text(_ family: Int32, _ address: UnsafeRawPointer, _ length: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: length)
        guard inet_ntop(family, address, &buffer, socklen_t(length)) != nil else { return nil }
        return String(cString: buffer)
    }

    /// `lan.address` (PROTOCOL §9.4): the IPv4 address and netmask of the
    /// Wi-Fi interface (en0), or both null off Wi-Fi.
    static func wifiAddress() -> JSONObject {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else {
            return ["ip": NSNull(), "netmask": NSNull()]
        }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard String(cString: entry.ifa_name) == "en0",
                  let address = entry.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  let mask = entry.ifa_netmask,
                  let ip = ipv4(address), let netmask = ipv4(mask)
            else { continue }
            return ["ip": ip, "netmask": netmask]
        }
        return ["ip": NSNull(), "netmask": NSNull()]
    }

    private static func ipv4(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
        var inAddress = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        return text(AF_INET, &inAddress, Int(INET_ADDRSTRLEN))
    }
}
