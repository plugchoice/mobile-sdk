import Foundation
import Network

/// `udp.exchange` (PROTOCOL §9.7): one datagram to a unicast address on the
/// local network, and the replies that come back until `maxReplies` arrived
/// or `timeoutMs` passed.
///
/// - A connected `NWConnection`: replies come only from the address and
///   port the datagram went to.
/// - Multicast and broadcast never get this far (the host rules refuse
///   them); a subnet's directed broadcast fails with `network`, since iOS
///   needs Apple's multicast entitlement for it.
/// - A Local Network permission that is missing answers
///   `localNetworkDenied`; a failed send or connection before any reply
///   answers `network`. Nothing listening on the port is no error: the
///   exchange answers with no replies at `timeoutMs`.
@MainActor
final class UDPExchanges {
    nonisolated static let timeoutRange = 100...30_000
    /// What `maxReplies` may be.
    nonisolated static let maxRepliesRange = 1...1_000
    /// The largest UDP payload over IPv4.
    nonisolated static let maxDatagramBytes = 65_507

    struct Request {
        let host: String
        let port: Int
        let data: Data
        let timeoutMs: Int
        var maxReplies = 1
        var routeTraffic = false
    }

    typealias Completion = (Result<JSONObject, BridgeError>) -> Void

    private var running: [ObjectIdentifier: UDPExchange] = [:]

    var count: Int { running.count }

    func exchange(_ request: Request, completion: @escaping Completion) {
        let exchange = UDPExchange(request)
        let key = ObjectIdentifier(exchange)
        running[key] = exchange
        exchange.start { [weak self] result in
            self?.running.removeValue(forKey: key)
            completion(result)
        }
    }

    /// The page is gone: stops every exchange without answering.
    func cancelAll() {
        let all = running.values
        running.removeAll()
        all.forEach { $0.cancel() }
    }
}

/// One `udp.exchange`.
@MainActor
private final class UDPExchange {
    private let request: Request
    private let connection: NWConnection
    private var completion: UDPExchanges.Completion?
    private var timer: DispatchWorkItem?
    private var sent = false
    private var replies: [JSONObject] = []

    typealias Request = UDPExchanges.Request

    init(_ request: Request) {
        self.request = request
        let parameters = NWParameters.udp
        if request.routeTraffic {
            parameters.prohibitedInterfaceTypes = [.cellular]
        }
        connection = NWConnection(
            host: NWEndpoint.Host(request.host),
            port: NWEndpoint.Port(rawValue: UInt16(clamping: request.port)) ?? .any,
            using: parameters
        )
    }

    func start(completion: @escaping UDPExchanges.Completion) {
        self.completion = completion
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                self?.stateChanged(state)
            }
        }
        let timer = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.finish(.success(["replies": self.replies]))
            }
        }
        self.timer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(request.timeoutMs), execute: timer)
        connection.start(queue: .main)
    }

    func cancel() {
        completion = nil
        timer?.cancel()
        connection.cancel()
    }

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            guard !sent else { return }
            sent = true
            send()
        case .waiting(let error), .failed(let error):
            failed(error)
        default:
            break
        }
    }

    private func send() {
        connection.send(content: request.data, completion: .contentProcessed { [weak self] error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let error {
                    self.failed(error)
                } else {
                    self.receive()
                }
            }
        })
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, _, _, error in
            MainActor.assumeIsolated {
                guard let self, self.completion != nil else { return }
                if let data {
                    self.replies.append(["from": self.remoteHost, "port": self.remotePort, "data": data.base64EncodedString()])
                    if self.replies.count >= self.request.maxReplies {
                        self.finish(.success(["replies": self.replies]))
                        return
                    }
                }
                if let error {
                    self.failed(error)
                } else {
                    self.receive()
                }
            }
        }
    }

    /// Before any reply: `localNetworkDenied` or `network`. After one: the
    /// replies so far.
    private func failed(_ error: NWError) {
        guard completion != nil else { return }
        if !replies.isEmpty {
            finish(.success(["replies": replies]))
            return
        }
        if connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
            finish(.failure(DeviceConnection.localNetworkDenied))
        } else if case .dns(let code) = error, code == DeviceConnection.policyDenied {
            finish(.failure(DeviceConnection.localNetworkDenied))
        } else {
            finish(.failure(BridgeError(code: "network", message: error.localizedDescription)))
        }
    }

    private func finish(_ result: Result<JSONObject, BridgeError>) {
        guard let completion else { return }
        self.completion = nil
        timer?.cancel()
        connection.cancel()
        completion(result)
    }

    /// The address the datagram went to, without an IPv6 scope.
    private var remoteHost: String {
        if case .hostPort(let host, _)? = connection.currentPath?.remoteEndpoint {
            switch host {
            case .ipv4(let address):
                return "\(address)"
            case .ipv6(let address):
                return "\(address)".split(separator: "%").first.map(String.init) ?? "\(address)"
            case .name(let name, _):
                return name
            @unknown default:
                break
            }
        }
        return request.host
    }

    private var remotePort: Int {
        if case .hostPort(_, let port)? = connection.currentPath?.remoteEndpoint {
            return Int(port.rawValue)
        }
        return request.port
    }
}
