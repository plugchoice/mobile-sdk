import Foundation
import Network
import Security

/// TLS on a connection to a device: whose trust (nil: the system's), and
/// the name to send and check instead of the host (`tcp.open`'s
/// `tls.serverName`).
struct DeviceTLS {
    let trust: Trust?
    let serverName: String?
}

/// The byte stream under an `http.session` or a `tcp` socket.
@MainActor
protocol SessionConnection: AnyObject {
    func send(_ data: Data, completion: @escaping (BridgeError?) -> Void)
    /// The next bytes; `isComplete` once the device closed its side.
    func receive(completion: @escaping (Result<(data: Data, isComplete: Bool), BridgeError>) -> Void)
    func cancel()
}

/// Opens connections to devices (the TCP handshake, and the TLS one with
/// `tls`).
@MainActor
protocol SessionConnector {
    func connect(
        host: String,
        port: Int,
        tls: DeviceTLS?,
        timeoutMs: Int,
        routeTraffic: Bool,
        completion: @escaping (Result<SessionConnection, BridgeError>) -> Void
    ) -> SessionConnectAttempt
}

/// A connection attempt that can be abandoned.
@MainActor
protocol SessionConnectAttempt: AnyObject {
    func cancel()
}

/// TCP, optionally with TLS, over Network.framework.
@MainActor
struct NetworkConnector: SessionConnector {
    func connect(
        host: String,
        port: Int,
        tls: DeviceTLS?,
        timeoutMs: Int,
        routeTraffic: Bool,
        completion: @escaping (Result<SessionConnection, BridgeError>) -> Void
    ) -> SessionConnectAttempt {
        let connection = DeviceConnection(host: host, port: port, tls: tls, routeTraffic: routeTraffic)
        connection.start(timeoutMs: timeoutMs, completion: completion)
        return connection
    }
}

/// One `NWConnection` to a device. It must be ready (TCP, and TLS when
/// asked) within the open's timeout; a connection waiting for the Local
/// Network permission answers `localNetworkDenied` at once, a refused or
/// unreachable one `network`, a certificate the trust refused `tls`.
@MainActor
final class DeviceConnection: SessionConnection, SessionConnectAttempt {
    /// kDNSServiceErr_PolicyDenied: the Local Network permission is missing.
    static let policyDenied: Int32 = -65570
    private static let receiveChunk = 64 * 1024

    private let connection: NWConnection
    /// What the TLS verify block decided.
    private let verification: TLSVerification
    private var opening: ((Result<SessionConnection, BridgeError>) -> Void)?
    private var timer: DispatchWorkItem?
    /// The connection failed after it was ready.
    private var broken: BridgeError?

    init(host: String, port: Int, tls: DeviceTLS?, routeTraffic: Bool) {
        let verification = TLSVerification(pageTrust: tls?.trust != nil)
        self.verification = verification
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? .https,
            using: Self.parameters(host: host, tls: tls, routeTraffic: routeTraffic, verification: verification)
        )
    }

    /// TCP with no delay and no proxy; with `tls`, a verify block that
    /// replaces the system's check (`Trust.evaluate`, or the system's trust
    /// for the server name). With `routeTraffic`, never over cellular: the
    /// charger network is Wi-Fi.
    static func parameters(host: String, tls: DeviceTLS?, routeTraffic: Bool, verification: TLSVerification = TLSVerification(pageTrust: false)) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters: NWParameters
        if let tls {
            let options = NWProtocolTLS.Options()
            let name = tls.serverName ?? host
            if let serverName = tls.serverName {
                sec_protocol_options_set_tls_server_name(options.securityProtocolOptions, serverName)
            }
            let trust = tls.trust
            sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, secTrust, complete in
                let serverTrust = sec_trust_copy_ref(secTrust).takeRetainedValue()
                let evaluation = trust?.evaluate(serverTrust, host: name) ?? Trust.evaluateSystem(serverTrust, host: name)
                if !evaluation.trusted {
                    verification.reject(presentedFingerprint: evaluation.presentedFingerprint)
                }
                complete(evaluation.trusted)
            }, .main)
            parameters = NWParameters(tls: options, tcp: tcp)
        } else {
            parameters = NWParameters(tls: nil, tcp: tcp)
        }
        parameters.preferNoProxies = true
        if routeTraffic {
            parameters.prohibitedInterfaceTypes = [.cellular]
        }
        return parameters
    }

    /// The answer for an attempt that can't connect (waiting) or failed:
    /// `tls` when the trust refused the certificate, `localNetworkDenied`
    /// when the Local Network permission is the reason, otherwise what the
    /// error says (refused, unreachable).
    static func openFailure(
        _ error: NWError,
        unsatisfiedReason: NWPath.UnsatisfiedReason?,
        verification: TLSVerification
    ) -> BridgeError {
        if !verification.rejected {
            if unsatisfiedReason == .localNetworkDenied {
                return localNetworkDenied
            }
            if case .dns(let code) = error, code == policyDenied {
                return localNetworkDenied
            }
        }
        return failure(error, verification: verification)
    }

    static let localNetworkDenied = BridgeError(code: "localNetworkDenied", message: "the Local Network permission is not granted")

    func start(timeoutMs: Int, completion: @escaping (Result<SessionConnection, BridgeError>) -> Void) {
        opening = completion
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                self?.stateChanged(state)
            }
        }
        let timer = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.openFailed(BridgeError(code: "timeout", message: "not connected within \(timeoutMs) ms"))
            }
        }
        self.timer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(timeoutMs), execute: timer)
        connection.start(queue: .main)
    }

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            guard let opening else { return }
            self.opening = nil
            timer?.cancel()
            opening(.success(self))
        case .waiting(let error), .failed(let error):
            if opening != nil {
                // Refused, unreachable, refused certificate or no Local
                // Network permission: fail now rather than wait for the
                // deadline.
                openFailed(Self.openFailure(error, unsatisfiedReason: connection.currentPath?.unsatisfiedReason, verification: verification))
            } else {
                broken = broken ?? map(error)
            }
        default:
            break
        }
    }

    private func openFailed(_ error: BridgeError) {
        guard let opening else { return }
        self.opening = nil
        timer?.cancel()
        connection.cancel()
        opening(.failure(error))
    }

    private func map(_ error: NWError) -> BridgeError {
        Self.failure(error, verification: verification)
    }

    private static func failure(_ error: NWError, verification: TLSVerification) -> BridgeError {
        if verification.rejected {
            return Trust.rejection(pageTrust: verification.pageTrust, presentedFingerprint: verification.presentedFingerprint)
        }
        switch error {
        case .posix(.ETIMEDOUT):
            return BridgeError(code: "timeout", message: error.localizedDescription)
        case .tls(let status):
            return BridgeError(code: "network", message: "TLS handshake failed (OSStatus \(status))")
        default:
            return BridgeError(code: "network", message: error.localizedDescription)
        }
    }

    func send(_ data: Data, completion: @escaping (BridgeError?) -> Void) {
        if let broken {
            completion(broken)
            return
        }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            MainActor.assumeIsolated {
                completion(error.map { self?.map($0) ?? BridgeError(code: "network", message: $0.localizedDescription) })
            }
        })
    }

    func receive(completion: @escaping (Result<(data: Data, isComplete: Bool), BridgeError>) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.receiveChunk) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                if let error, data?.isEmpty ?? true {
                    completion(.failure(self?.map(error) ?? BridgeError(code: "network", message: error.localizedDescription)))
                } else {
                    completion(.success((data ?? Data(), isComplete)))
                }
            }
        }
    }

    func cancel() {
        timer?.cancel()
        opening = nil
        connection.cancel()
    }
}

/// What the TLS verify block decided, read on the main queue (the block runs
/// there too).
final class TLSVerification: @unchecked Sendable {
    /// A page's trust object decides, rather than the system's trust.
    let pageTrust: Bool
    private(set) var rejected = false
    private(set) var presentedFingerprint: String?

    init(pageTrust: Bool) {
        self.pageTrust = pageTrust
    }

    func reject(presentedFingerprint: String?) {
        rejected = true
        self.presentedFingerprint = presentedFingerprint
    }
}
