import AuthenticationServices
import UIKit

/// `auth.webSession` (PROTOCOL.md §7.1): Google or Apple sign-in in the
/// system's sign-in sheet, since Google refuses an embedded web view. The
/// sheet closes on the `plugchoice-link` scheme; that URL goes back to the
/// page. It holds a one-time code: never logged.
@MainActor
final class WebSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let callbackScheme = "plugchoice-link"

    private var showing: ASWebAuthenticationSession?
    private weak var anchor: UIWindow?

    func signIn(url: URL, from presenter: UIViewController?) async throws -> JSONObject {
        guard showing == nil else {
            throw BridgeError(code: "unavailable", message: "a sign-in is already showing")
        }
        guard let window = presenter?.viewIfLoaded?.window else {
            throw BridgeError(code: "unavailable", message: "nothing to show the sign-in over")
        }
        anchor = window
        defer { showing = nil }

        let callback = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let session = ASWebAuthenticationSession(url: url, callbackURLScheme: Self.callbackScheme) { callbackURL, error in
                    if let callbackURL {
                        continuation.resume(returning: callbackURL)
                    } else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                        continuation.resume(throwing: BridgeError(code: "userCancelled", message: "sign-in closed"))
                    } else {
                        continuation.resume(throwing: BridgeError(code: "unavailable", message: "sign-in failed: \(error.map { String(describing: type(of: $0)) } ?? "unknown")"))
                    }
                }
                session.presentationContextProvider = self
                // Shares Safari's cookies: someone signed in to Google there picks their account in one tap.
                session.prefersEphemeralWebBrowserSession = false
                showing = session
                if !session.start() {
                    showing = nil
                    continuation.resume(throwing: BridgeError(code: "unavailable", message: "the sign-in sheet didn't start"))
                }
            }
        } onCancel: {
            // The page went away or the screen is closing: the session's
            // completion answers with canceledLogin.
            Task { @MainActor in self.showing?.cancel() }
        }
        return ["callbackUrl": callback.absoluteString]
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { anchor ?? ASPresentationAnchor() }
    }
}
