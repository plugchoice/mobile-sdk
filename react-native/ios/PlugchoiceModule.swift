import ExpoModulesCore
import PlugchoiceSDK
import UIKit

/// `@plugchoice/react-native` on iOS, over the Plugchoice SDK (the
/// PlugchoiceSDK pod: the same sources and module name as the Swift
/// package's).
///
/// - `openLink(action, options)` presents Link from the top view controller
///   (`plugchoice.link.present`) and resolves with the `LinkResult` once it is
///   dismissed. One at a time: a call while one is open rejects with
///   `ERR_LINK_ALREADY_OPEN`.
/// - The SDK's `fetchClientSecret` asks JavaScript, which holds the app's
///   callback: it sends `onClientSecretRequest { requestId, action }` and
///   waits for `provideClientSecret(requestId, secret)` or
///   `rejectClientSecret(requestId, message)`. The SDK stops waiting after
///   30 s (`clientSecretUnavailable` to the page).
/// - `getTransports()` is `Plugchoice.transports()`.
public final class PlugchoiceModule: Module {
    /// Main thread only.
    private var isOpen = false
    private let clientSecrets = ClientSecretRequests()

    public func definition() -> ModuleDefinition {
        Name("Plugchoice")

        Events(ClientSecretRequests.event)

        AsyncFunction("openLink") { (action: LinkActionRecord, options: OpenLinkOptions, promise: Promise) in
            MainActor.assumeIsolated {
                self.open(action.linkAction, options: options, promise: promise)
            }
        }
        .runOnQueue(.main)

        Function("provideClientSecret") { (requestId: String, clientSecret: String) in
            self.clientSecrets.answer(requestId, with: .success(clientSecret))
        }

        Function("rejectClientSecret") { (requestId: String, message: String) in
            self.clientSecrets.answer(requestId, with: .failure(ClientSecretRejected(message: message)))
        }

        AsyncFunction("getTransports") { () -> [String] in
            Plugchoice.transports()
        }

        OnDestroy {
            // JavaScript is going away (a reload): nobody is left to answer.
            self.clientSecrets.close()
        }
    }

    @MainActor
    private func open(_ action: LinkAction, options: OpenLinkOptions, promise: Promise) {
        guard !isOpen else {
            promise.reject("ERR_LINK_ALREADY_OPEN", "A Plugchoice Link screen is already open.")
            return
        }
        guard let presenter = appContext?.utilities?.currentViewController() else {
            promise.reject("ERR_LINK_CANNOT_PRESENT", "There is no view controller to present Plugchoice Link from.")
            return
        }
        isOpen = true
        clientSecrets.send = { [weak self] requestId, action in
            self?.sendEvent(ClientSecretRequests.event, [
                "requestId": requestId,
                "action": PlugchoiceModule.payload(action),
            ])
        }
        let clientSecrets = clientSecrets
        let plugchoice = Plugchoice(
            fetchClientSecret: { action in try await clientSecrets.request(for: action) },
            options: Plugchoice.Options(hostOverride: options.hostOverride)
        )
        plugchoice.link.present(action, from: presenter) { [weak self] result in
            self?.isOpen = false
            promise.resolve(PlugchoiceModule.payload(result))
        }
    }

    /// `{ action, chargerId?, siteId? }`.
    static func payload(_ action: LinkAction) -> [String: Any] {
        var payload: [String: Any] = ["action": action.action]
        if let chargerId = action.chargerId {
            payload["chargerId"] = chargerId
        }
        if let siteId = action.siteId {
            payload["siteId"] = siteId
        }
        return payload
    }

    /// `{ status, action, sessionId?, devices: [{ type, id }], error?: { code,
    /// message? } }`; the JavaScript side fills in what is left out.
    static func payload(_ result: LinkResult) -> [String: Any] {
        var payload: [String: Any] = [
            "status": result.status.rawValue,
            "action": result.action,
            "devices": result.devices.map { ["type": $0.type, "id": $0.id] },
        ]
        if let sessionId = result.sessionId {
            payload["sessionId"] = sessionId
        }
        if let error = result.error {
            var errorPayload: [String: Any] = ["code": error.code]
            if let message = error.message {
                errorPayload["message"] = message
            }
            payload["error"] = errorPayload
        }
        return payload
    }
}

/// The client secrets the SDK asks JavaScript for. Each request gets an id,
/// goes out as `onClientSecretRequest`, and waits until JavaScript answers
/// that id, the SDK cancels it (its 30 s deadline, or the screen closing), or
/// the module goes away. A late or unknown answer is dropped.
///
/// Thread-safe: the SDK asks from a background task; JavaScript answers on
/// its own thread. The secret only passes through, and is never logged.
final class ClientSecretRequests: @unchecked Sendable {
    static let event = "onClientSecretRequest"

    /// Sends the `onClientSecretRequest` event (the module sets it). Main
    /// thread only.
    var send: (@MainActor (_ requestId: String, _ action: LinkAction) -> Void)?

    private let lock = NSLock()
    private var waiting: [String: CheckedContinuation<String, Error>] = [:]
    private var closed = false

    /// Registers a request for `action`, sends it on the main actor, and waits
    /// for its answer.
    func request(for action: LinkAction) async throws -> String {
        let requestId = UUID().uuidString
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                lock.lock()
                if closed || Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: closed ? ClientSecretRejected.moduleGone : CancellationError())
                    return
                }
                waiting[requestId] = continuation
                lock.unlock()
                Task { @MainActor in self.send?(requestId, action) }
            }
        } onCancel: {
            self.answer(requestId, with: .failure(CancellationError()))
        }
    }

    /// Ends the request `requestId`, if it is still waiting.
    func answer(_ requestId: String, with result: Result<String, Error>) {
        lock.lock()
        let continuation = waiting.removeValue(forKey: requestId)
        lock.unlock()
        continuation?.resume(with: result)
    }

    /// Fails every waiting request, and every later one at once.
    func close() {
        lock.lock()
        closed = true
        let continuations = Array(waiting.values)
        waiting.removeAll()
        lock.unlock()
        for continuation in continuations {
            continuation.resume(throwing: ClientSecretRejected.moduleGone)
        }
    }
}

/// JavaScript couldn't give a secret: `fetchClientSecret` failed, or
/// JavaScript is gone. The SDK answers the page `clientSecretUnavailable`.
struct ClientSecretRejected: LocalizedError {
    static let moduleGone = ClientSecretRejected(message: "the React Native module is gone")

    let message: String

    var errorDescription: String? { message }
}

/// The action JavaScript opens Link with.
struct LinkActionRecord: Record {
    @Field var action: String = ""
    @Field var chargerId: String?
    @Field var siteId: String?

    /// Empty ids are left out, as on Android.
    var linkAction: LinkAction {
        LinkAction(
            action: action,
            chargerId: chargerId.flatMap { $0.isEmpty ? nil : $0 },
            siteId: siteId.flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

struct OpenLinkOptions: Record {
    /// Debug builds only; see `Plugchoice.Options.hostOverride`.
    @Field var hostOverride: String?
}
