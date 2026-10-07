import SwiftUI
import UIKit

/// The Plugchoice SDK. Create one with a callback that fetches a client
/// secret from your server, then open Link, its onboarding screen, with an
/// action:
///
/// ```swift
/// let plugchoice = Plugchoice(fetchClientSecret: { try await backend.plugchoiceClientSecret() })
/// plugchoice.link.present(.addCharger(), from: viewController) { result in … }
/// ```
///
/// Your server gets the client secret from `POST /sdk/v1/client-sessions`
/// (with its own credentials, never in the app), scoped to the action's
/// charger or site. The SDK calls the callback with the action when the
/// screen opens, and again whenever the page's secret has expired.
public final class Plugchoice: Sendable {
    /// The SDK release, the same on iOS and Android (`hello`'s `sdkVersion`).
    public static let sdkVersion = "0.3.0" // x-release-please-version

    /// Fetches a client secret (`cs_test_…` or `cs_live_…`) for `action`
    /// from the host app's server, which scopes it to the action's charger or
    /// site. Throwing, returning an empty string or taking longer than 30 s
    /// counts as unavailable; the page then offers to try again.
    public typealias FetchClientSecret = @Sendable (_ action: LinkAction) async throws -> String

    public struct Options: Sendable {
        /// Debug builds only: `scheme://host[:port]` of a hosted UI to load
        /// instead of `https://connect.plugchoice.com`, for example
        /// `http://192.168.1.20:5173`. It becomes the only allowed origin.
        /// Ignored, with a log line, in release builds (and when it isn't of
        /// that form).
        public var hostOverride: String?

        public init(hostOverride: String? = nil) {
            self.hostOverride = hostOverride
        }
    }

    public let options: Options
    /// Link, the onboarding screen.
    public let link: Link
    let fetchClientSecret: FetchClientSecret

    public init(fetchClientSecret: @escaping FetchClientSecret, options: Options = .init()) {
        self.fetchClientSecret = fetchClientSecret
        self.options = options
        link = Link(fetchClientSecret: fetchClientSecret, options: options)
    }

    /// The transports this device and app can run: any of `wifi`, `http`,
    /// `socket`, `lan` and `ble`, matching the `needs` of a device's
    /// capabilities in the Plugchoice API. Asks for no permission.
    ///
    /// - `wifi`, `http`, `socket`: always.
    /// - `lan`: the app's Info.plist declares at least one service type in
    ///   `NSBonjourServices` (iOS browses only declared types).
    /// - `ble`: the device has Bluetooth LE (not the simulator) and the app's
    ///   Info.plist has `NSBluetoothAlwaysUsageDescription`.
    public static func transports() -> [String] {
        var transports = ["wifi", "http", "socket"]
        if !LanDiscovery.declaredServiceTypes.isEmpty {
            transports.append("lan")
        }
        if BluetoothSupport.isAvailable {
            transports.append("ble")
        }
        return transports
    }

    /// The package builds from source with the host app's configuration, so
    /// this follows the app's Debug/Release.
    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Opens Link, the onboarding screen.
    public final class Link: Sendable {
        let fetchClientSecret: FetchClientSecret
        let options: Options

        init(fetchClientSecret: @escaping FetchClientSecret, options: Options) {
            self.fetchClientSecret = fetchClientSecret
            self.options = options
        }

        /// Shows Link for `action` in a sheet and calls `completion` once
        /// with the outcome, on the main thread, after the screen is
        /// dismissed.
        ///
        /// - Parameters:
        ///   - action: What to do, such as `.addCharger()` or
        ///     `.network(chargerId:)`.
        ///   - presenter: The view controller to present from.
        ///   - completion: Called with the result.
        @MainActor
        public func present(
            _ action: LinkAction,
            from presenter: UIViewController,
            completion: @escaping (LinkResult) -> Void
        ) {
            presenter.present(makeController(action, completion: completion), animated: true)
        }

        @MainActor
        func makeController(_ action: LinkAction, completion: @escaping (LinkResult) -> Void) -> LinkViewController {
            let target = LinkTarget(action: action, hostOverride: options.hostOverride, honourOverride: Plugchoice.isDebugBuild)
            let controller = LinkViewController(target: target, secrets: ClientSecrets(action: action, fetch: fetchClientSecret))
            controller.onFinish = completion
            return controller
        }
    }
}

/// What Link opens for: an action and the ids it needs. The action is an
/// open string; the hosted page decides what it means. `fetchClientSecret`
/// gets it too, so your server can scope the client secret.
public struct LinkAction: Sendable, Equatable, Hashable {
    /// `add`, `network`, `setup`, `reconnect`, or a later one.
    public let action: String
    public let chargerId: String?
    public let siteId: String?

    public init(action: String, chargerId: String? = nil, siteId: String? = nil) {
        self.action = action
        self.chargerId = chargerId
        self.siteId = siteId
    }

    /// Set up a new charger, optionally at one of the user's sites.
    public static func addCharger(siteId: String? = nil) -> LinkAction {
        LinkAction(action: "add", siteId: siteId)
    }

    /// Change a charger's network connection.
    public static func network(chargerId: String) -> LinkAction {
        LinkAction(action: "network", chargerId: chargerId)
    }

    /// Set up a charger's electrical settings.
    public static func setup(chargerId: String) -> LinkAction {
        LinkAction(action: "setup", chargerId: chargerId)
    }

    /// Reconnect a charger to Plugchoice.
    public static func reconnect(chargerId: String) -> LinkAction {
        LinkAction(action: "reconnect", chargerId: chargerId)
    }

    /// An action this SDK version doesn't name yet.
    public static func custom(_ action: String, chargerId: String? = nil) -> LinkAction {
        LinkAction(action: action, chargerId: chargerId)
    }
}

/// A device a Link run finished, such as `charger`. Ignore types you don't
/// know: later ones (meters) need no SDK release.
public struct Device: Sendable, Equatable, Hashable {
    public let type: String
    public let id: String

    public init(type: String, id: String) {
        self.type = type
        self.id = id
    }
}

/// Why a Link run ended in `error`: a `code` and free text for logs. The
/// code is one of the SDK's own: `clientSecretUnavailable` (your callback
/// gave no secret), `pageLoadFailed` (the user left the "Try again" screen)
/// or `internal`. Otherwise it's a problem code from the page, such as
/// `not-found`.
public struct LinkError: Error, Sendable, Equatable {
    public let code: String
    public let message: String?

    public init(code: String, message: String? = nil) {
        self.code = code
        self.message = message
    }
}

extension LinkError: CustomStringConvertible {
    public var description: String {
        message.map { "\(code): \($0)" } ?? code
    }
}

/// The outcome of a Link run. A convenience for the app's UI: your server
/// confirms with `GET /sdk/v1/link-sessions/{id}`.
public struct LinkResult: Sendable, Equatable {
    public enum Status: String, Sendable {
        case success
        case cancelled
        case error
    }

    /// From the page, or `cancelled` / `error` when the screen closed without
    /// it (the user left before the page was ready, the page hung, the page
    /// didn't load).
    public let status: Status
    /// The action the run did: the page's, else the one Link opened with.
    public let action: String
    /// The run, when the page started one.
    public let sessionId: String?
    /// The devices the page reports, as it sends them for any status (on
    /// `success`, the devices the run finished). Empty when the screen
    /// closed by itself.
    public let devices: [Device]
    /// Set on `error` when the page or the SDK says why.
    public let error: LinkError?

    public init(status: Status, action: String, sessionId: String? = nil, devices: [Device] = [], error: LinkError? = nil) {
        self.status = status
        self.action = action
        self.sessionId = sessionId
        self.devices = devices
        self.error = error
    }
}

extension LinkResult: CustomStringConvertible {
    public var description: String {
        var parts = ["status: \(status.rawValue)", "action: \(action)", "sessionId: \(sessionId ?? "null")"]
        parts.append("devices: [\(devices.map { "\($0.type) \($0.id)" }.joined(separator: ", "))]")
        if let error { parts.append("error: \(error)") }
        return parts.joined(separator: "\n")
    }
}

// MARK: - SwiftUI

extension View {
    /// Presents Link for `action` while `isPresented` is true and calls
    /// `onCompletion` once with the outcome. Setting `isPresented` to false
    /// closes it with `cancelled`.
    ///
    /// The screen is presented through UIKit from an invisible anchor, so it
    /// is the same sheet with the same close handling as
    /// `plugchoice.link.present(_:from:completion:)`.
    public func plugchoiceLink(
        isPresented: Binding<Bool>,
        plugchoice: Plugchoice,
        action: LinkAction,
        onCompletion: @escaping (LinkResult) -> Void
    ) -> some View {
        background(
            LinkPresenter(isPresented: isPresented, link: plugchoice.link, action: action, onCompletion: onCompletion)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
    }
}

private struct LinkPresenter: UIViewControllerRepresentable {
    let isPresented: Binding<Bool>
    let link: Plugchoice.Link
    let action: LinkAction
    let onCompletion: (LinkResult) -> Void

    @MainActor
    final class Coordinator {
        var isOpen = false
        weak var screen: LinkViewController?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ anchor: UIViewController, context: Context) {
        let coordinator = context.coordinator
        if isPresented.wrappedValue {
            guard !coordinator.isOpen else { return }
            coordinator.isOpen = true
            let isPresented = isPresented
            let onCompletion = onCompletion
            let controller = link.makeController(action) { result in
                coordinator.isOpen = false
                coordinator.screen = nil
                isPresented.wrappedValue = false
                onCompletion(result)
            }
            coordinator.screen = controller
            // Next turn: the anchor may not be in a window yet.
            DispatchQueue.main.async {
                // Closed again before it showed.
                guard coordinator.screen === controller else { return }
                anchor.present(controller, animated: true)
            }
        } else if coordinator.isOpen, let screen = coordinator.screen {
            screen.closeForHost()
        }
    }
}
