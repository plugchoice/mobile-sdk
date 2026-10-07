import UIKit
import WebKit

/// The Link screen: a sheet with a WKWebView showing the hosted page, a
/// native close button until the page has answered `hello`, and the bridge.
/// Keeps the screen awake while shown (iOS drops a `joinOnce` hotspot soon
/// after the phone locks).
///
/// The sheet can't be swiped away (`isModalInPresentation`): a swipe, like
/// the close button, goes through `CloseGuard`, which lets the page decide
/// once it has answered `hello` (PROTOCOL §6.2).
///
/// When the page doesn't load it shows "Try again" with the native close
/// button; leaving from there reports `error` / `pageLoadFailed`.
///
/// The client secret is fetched from the host app when the screen opens, in
/// parallel with loading the page (`ClientSecrets`).
@MainActor
final class LinkViewController: UIViewController {
    static let messageHandlerName = "plugchoiceLink"
    static let pageLoadFailedCode = "pageLoadFailed"

    /// Called exactly once with the outcome, after the screen is dismissed.
    var onFinish: ((LinkResult) -> Void)?

    private let target: LinkTarget
    private let secrets: ClientSecrets
    private let allowList: OriginAllowList
    private let bridge: Bridge
    private let closeGuard = CloseGuard()
    private let messageProxy = WeakScriptMessageHandler()
    private var webView: WKWebView!
    private let closeButton = UIButton(type: .system)
    private var errorView: UIView?
    /// Why the page didn't load, while the load-error screen shows.
    private var loadErrorMessage: String?
    private var finished = false
    private var tornDown = false
    private var idleTimerHeld = false
    private var idleTimerWasDisabled = false

    init(target: LinkTarget, secrets: ClientSecrets) {
        self.target = target
        self.secrets = secrets
        allowList = OriginAllowList([target.allowedOrigin])
        bridge = Bridge(allowList: allowList, secrets: secrets)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        isModalInPresentation = true
        presentationController?.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - View

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(messageProxy, name: Self.messageHandlerName)
        configuration.allowsInlineMediaPlayback = true
        messageProxy.target = self

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        #if DEBUG
        if #available(iOS 16.4, *) {
            // Safari's Develop menu, in debug builds of the host app only: the
            // page holds the session's credential.
            webView.isInspectable = true
        }
        #endif
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        bridge.webView = webView
        bridge.presenter = self
        bridge.onHello = { [weak self] in
            self?.helloAnswered()
        }
        bridge.onCloseHandled = { [weak self] in
            self?.closeGuard.pageAnswered()
        }
        bridge.onSessionClose = { [weak self] close in
            self?.finish(LinkResult(
                status: close.status,
                action: close.action,
                sessionId: close.sessionId,
                devices: close.devices,
                error: close.error
            ))
        }
        closeGuard.onAskPage = { [weak self] in
            self?.bridge.emit("ui.closeRequested", [:])
        }
        closeGuard.onClose = { [weak self] in
            self?.finishForUser()
        }

        setUpCloseButton()
        secrets.prefetch()
        webView.load(URLRequest(url: target.url))
    }

    private func setUpCloseButton() {
        var configuration = UIButton.Configuration.gray()
        configuration.image = UIImage(
            systemName: "xmark",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)
        )
        configuration.cornerStyle = .capsule
        configuration.baseForegroundColor = .label
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 9, bottom: 9, trailing: 9)
        closeButton.configuration = configuration
        closeButton.accessibilityLabel = "Close"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        holdIdleTimer()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Dismissed by someone other than us (the host app, a parent
        // controller going away): report it as a cancel.
        if isBeingDismissed || isMovingFromParent {
            hostDidDismiss()
        }
    }

    // MARK: - Handshake and closing

    /// The page draws its own close control, and decides about native
    /// closes from now on.
    private func helloAnswered() {
        closeGuard.pageDecides = true
        closeButton.isHidden = true
    }

    /// The page is gone (new document, load error): back to the native close
    /// button that closes at once.
    private func resetHandshake() {
        closeGuard.pageChanged()
        closeButton.isHidden = false
    }

    @objc private func closeTapped() {
        closeGuard.userWantsToClose()
    }

    /// The host app closed it (SwiftUI binding set to false).
    func closeForHost() {
        finishCancelled()
    }

    private func finishCancelled() {
        finish(LinkResult(status: .cancelled, action: target.action))
    }

    /// The user left natively (or a hung page ran out its deadline):
    /// `cancelled`, or `pageLoadFailed` from the load-error screen.
    private func finishForUser() {
        finish(Self.ownResult(action: target.action, loadErrorMessage: loadErrorMessage))
    }

    /// The result when the shell closes by itself (PROTOCOL §6.3): the action
    /// it opened, no run and no devices. `clientSecretUnavailable` is the
    /// page's to report, never the shell's.
    static func ownResult(action: String, loadErrorMessage: String?) -> LinkResult {
        if let loadErrorMessage {
            return LinkResult(status: .error, action: action, error: LinkError(code: pageLoadFailedCode, message: loadErrorMessage))
        }
        return LinkResult(status: .cancelled, action: action)
    }

    /// Ends the session once: tears the bridge down, dismisses and hands the
    /// result to the host app.
    func finish(_ result: LinkResult) {
        guard !finished else { return }
        finished = true
        tearDown()
        let callback = onFinish
        onFinish = nil
        // From the presenter, so a scanner on top goes too.
        if let presenter = presentingViewController {
            presenter.dismiss(animated: true) { callback?(result) }
        } else {
            callback?(result)
        }
    }

    /// Stops the bridge and the page, and lets the screen sleep again. Safe to
    /// call more than once.
    func tearDown() {
        guard !tornDown else { return }
        tornDown = true
        releaseIdleTimer()
        closeGuard.stop()
        secrets.discard()
        bridge.shutDown()
        messageProxy.target = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.messageHandlerName)
        webView?.stopLoading()
    }

    /// The screen went away without `finish` (the host dismissed it): report
    /// a cancel. No-op after `finish`.
    func hostDidDismiss() {
        guard !finished else { return }
        finished = true
        tearDown()
        let callback = onFinish
        onFinish = nil
        callback?(LinkResult(status: .cancelled, action: target.action))
    }

    private func holdIdleTimer() {
        guard !idleTimerHeld, !tornDown else { return }
        idleTimerHeld = true
        idleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func releaseIdleTimer() {
        guard idleTimerHeld else { return }
        idleTimerHeld = false
        UIApplication.shared.isIdleTimerDisabled = idleTimerWasDisabled
    }

    // MARK: - Load errors

    private func showLoadError(_ error: Error) {
        errorView?.removeFromSuperview()
        resetHandshake()
        loadErrorMessage = "Could not load \(target.allowedOrigin): \(error.localizedDescription)"

        let title = UILabel()
        title.text = "The page did not load"
        title.font = .preferredFont(forTextStyle: .headline)
        title.textAlignment = .center
        title.numberOfLines = 0

        let detail = UILabel()
        // The origin only: the fragment carries the action and its ids.
        detail.text = "\(target.allowedOrigin)\n\(error.localizedDescription)"
        detail.font = .preferredFont(forTextStyle: .footnote)
        detail.textColor = .secondaryLabel
        detail.textAlignment = .center
        detail.numberOfLines = 0

        var retryConfiguration = UIButton.Configuration.filled()
        retryConfiguration.title = "Try again"
        let retry = UIButton(configuration: retryConfiguration, primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            self.errorView?.removeFromSuperview()
            self.errorView = nil
            self.loadErrorMessage = nil
            self.webView.load(URLRequest(url: self.target.url))
        })

        let stack = UIStackView(arrangedSubviews: [title, detail, retry])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .center

        let container = UIView()
        container.backgroundColor = .systemBackground
        container.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        view.insertSubview(container, belowSubview: closeButton)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: view.topAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: container.layoutMarginsGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.layoutMarginsGuide.trailingAnchor, constant: -16),
        ])
        errorView = container
    }
}

// MARK: - WKScriptMessageHandler

extension LinkViewController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        bridge.didReceive(message)
    }
}

// MARK: - UIAdaptivePresentationControllerDelegate

extension LinkViewController: UIAdaptivePresentationControllerDelegate {
    /// A swipe down (or a tap outside on iPad) on the sheet.
    func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
        closeGuard.userWantsToClose()
    }
}

// MARK: - WKNavigationDelegate

extension LinkViewController: WKNavigationDelegate {
    /// The main frame stays on the allowed origin. Elsewhere, and new windows,
    /// open in the browser when the user tapped a link; anything else is
    /// dropped. Subframes load (the bridge ignores them).
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let opensWindow = navigationAction.targetFrame == nil
        let inMainFrame = navigationAction.targetFrame?.isMainFrame ?? false
        let url = navigationAction.request.url
        if !opensWindow, !inMainFrame || allowList.allows(url: url) {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        guard let url, let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto", "tel"].contains(scheme),
              opensWindow || navigationAction.navigationType == .linkActivated
        else {
            Bridge.log("blocked a navigation off the allowed origin")
            return
        }
        UIApplication.shared.open(url)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // A new document in the main frame: drop what the previous one started,
        // and wait for its hello again.
        bridge.pageDidChange()
        resetHandshake()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        showLoadError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        Bridge.log("navigation failed: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !tornDown else { return }
        Bridge.log("web content process terminated; reloading")
        webView.reload()
    }
}

/// WKUserContentController retains its handlers strongly; this proxy keeps
/// the controller → web view → handler chain from becoming a cycle.
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
