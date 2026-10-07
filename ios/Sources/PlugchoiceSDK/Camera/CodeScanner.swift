import AVFoundation
import UIKit

/// `camera.scanCode`: one QR code from a native full-screen scanner over the
/// page, on `AVCaptureSession` + `AVCaptureMetadataOutput` (every iOS 16
/// device, unlike VisionKit's `DataScannerViewController`).
///
/// The scanned value can hold secrets (a charger's setup card QR can carry
/// its hotspot password): it is never logged.
@MainActor
final class CodeScanner {
    struct Request: Equatable {
        let title: String?
        let hint: String?
    }

    /// The host's Info.plist has `NSCameraUsageDescription` (without it iOS
    /// kills the app on camera access) and the device has a camera.
    static var isAvailable: Bool {
        hasUsageDescription && AVCaptureDevice.default(for: .video) != nil
    }

    private static var hasUsageDescription: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil
    }

    private var showing: ScannerViewController?

    func scan(_ request: Request, from presenter: UIViewController?) async throws -> JSONObject {
        guard showing == nil else {
            throw Self.unavailable("a scan is already showing")
        }
        guard Self.hasUsageDescription else {
            throw Self.unavailable("the host app's Info.plist has no NSCameraUsageDescription")
        }
        guard let device = AVCaptureDevice.default(for: .video) else {
            throw Self.unavailable("no camera")
        }
        try await Self.ensureAccess()
        try Task.checkCancellation()
        guard let presenter, presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil else {
            throw Self.unavailable("nothing to show the scanner over")
        }

        let controller = ScannerViewController(capture: try Capture(device: device), request: request)
        showing = controller
        defer { showing = nil }
        let value = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                controller.onFinish = { continuation.resume(with: $0) }
                presenter.present(controller, animated: true)
            }
        } onCancel: {
            // The page went away or the screen is closing.
            Task { @MainActor in controller.cancel() }
        }
        return ["value": value, "format": "qr"]
    }

    private static func ensureAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .video) { return }
        default:
            break
        }
        throw BridgeError(code: "cameraPermissionDenied", message: "camera access is denied or restricted")
    }

    nonisolated fileprivate static func unavailable(_ message: String) -> BridgeError {
        BridgeError(code: "unavailable", message: message)
    }
}

/// The capture session with a QR metadata output. Started and stopped off the
/// main thread (`startRunning` blocks); immutable, so safe to hand over.
private final class Capture: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "com.plugchoice.link.camera")

    let session = AVCaptureSession()
    let output = AVCaptureMetadataOutput()

    init(device: AVCaptureDevice) throws {
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CodeScanner.unavailable("camera input: \(error.localizedDescription)")
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw CodeScanner.unavailable("the camera can't be configured")
        }
        session.addInput(input)
        session.addOutput(output)
        // Only valid once the output is in the session.
        guard output.availableMetadataObjectTypes.contains(.qr) else {
            throw CodeScanner.unavailable("QR codes are not supported on this camera")
        }
        output.metadataObjectTypes = [.qr]
    }

    func start() {
        Self.queue.async { [self] in
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        Self.queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }
}

/// The scanner screen: camera preview, a frame to aim with, the page's title
/// and hint, and a close button (`userCancelled`). Finishes with the first QR
/// code that has a text value.
private final class ScannerViewController: UIViewController {
    /// Called once, after the scanner is dismissed.
    var onFinish: ((Result<String, Error>) -> Void)?

    private let capture: Capture
    private let request: CodeScanner.Request
    private let metadataDelegate = MetadataDelegate()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var outcome: Result<String, Error>?

    init(capture: Capture, request: CodeScanner.Request) {
        self.capture = capture
        self.request = request
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        metadataDelegate.owner = self
        capture.output.setMetadataObjectsDelegate(metadataDelegate, queue: .main)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let previewLayer = AVCaptureVideoPreviewLayer(session: capture.session)
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        self.previewLayer = previewLayer

        let frame = UIView()
        frame.isUserInteractionEnabled = false
        frame.layer.borderColor = UIColor.white.cgColor
        frame.layer.borderWidth = 3
        frame.layer.cornerRadius = 24
        frame.layer.cornerCurve = .continuous

        let title = Self.label(
            request.title ?? "Scan the QR code",
            style: .title3,
            weight: .semibold,
            alpha: 1
        )
        title.accessibilityTraits = .header
        let hint = Self.label(request.hint, style: .subheadline, weight: .regular, alpha: 0.85)

        var closeConfiguration = UIButton.Configuration.gray()
        closeConfiguration.image = UIImage(
            systemName: "xmark",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)
        )
        closeConfiguration.cornerStyle = .capsule
        closeConfiguration.baseForegroundColor = .white
        closeConfiguration.baseBackgroundColor = UIColor.white.withAlphaComponent(0.2)
        closeConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 9, bottom: 9, trailing: 9)
        let close = UIButton(configuration: closeConfiguration, primaryAction: UIAction { [weak self] _ in
            self?.finish(.failure(BridgeError(code: "userCancelled", message: "the user closed the scanner")))
        })
        close.accessibilityLabel = "Cancel"

        for subview in [frame, title, hint, close] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        let guide = view.safeAreaLayoutGuide
        let side = frame.widthAnchor.constraint(equalTo: guide.widthAnchor, multiplier: 0.7)
        side.priority = .defaultHigh
        NSLayoutConstraint.activate([
            close.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            close.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -12),

            frame.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            frame.centerYAnchor.constraint(equalTo: guide.centerYAnchor),
            frame.heightAnchor.constraint(equalTo: frame.widthAnchor),
            frame.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            frame.heightAnchor.constraint(lessThanOrEqualTo: guide.heightAnchor, multiplier: 0.5),
            side,

            title.bottomAnchor.constraint(equalTo: frame.topAnchor, constant: -24),
            title.topAnchor.constraint(greaterThanOrEqualTo: close.bottomAnchor, constant: 8),
            title.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 24),
            title.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24),

            hint.topAnchor.constraint(equalTo: frame.bottomAnchor, constant: 24),
            hint.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 24),
            hint.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24),
        ])
    }

    private static func label(_ text: String?, style: UIFont.TextStyle, weight: UIFont.Weight, alpha: CGFloat) -> UILabel {
        let label = UILabel()
        label.text = text
        // The style's size at the default content size, scaled with Dynamic Type.
        let size = UIFont.preferredFont(
            forTextStyle: style,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
        ).pointSize
        label.font = UIFontMetrics(forTextStyle: style).scaledFont(for: .systemFont(ofSize: size, weight: weight))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = UIColor.white.withAlphaComponent(alpha)
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        capture.start()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Finished while it was still sliding in.
        if outcome != nil { leave() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        capture.stop()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        updatePreviewRotation()
    }

    /// Keeps the preview upright in every interface orientation (iPad).
    private func updatePreviewRotation() {
        guard let connection = previewLayer?.connection else { return }
        let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
        if #available(iOS 17.0, *) {
            let angle: CGFloat = switch orientation {
            case .landscapeRight: 0
            case .landscapeLeft: 180
            case .portraitUpsideDown: 270
            default: 90
            }
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        } else if connection.isVideoOrientationSupported {
            connection.videoOrientation = switch orientation {
            case .landscapeRight: .landscapeRight
            case .landscapeLeft: .landscapeLeft
            case .portraitUpsideDown: .portraitUpsideDown
            default: .portrait
            }
        }
    }

    // MARK: - Finishing

    fileprivate func found(_ value: String) {
        guard outcome == nil else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        finish(.success(value))
    }

    /// The scan's task was cancelled.
    func cancel() {
        finish(.failure(CancellationError()))
    }

    private func finish(_ outcome: Result<String, Error>) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        capture.output.setMetadataObjectsDelegate(nil, queue: nil)
        capture.stop()
        // A dismissal during the presentation would be ignored; viewDidAppear
        // leaves then.
        if !isBeingPresented { leave() }
    }

    /// Dismisses, then answers (so a retry from the page can show the scanner
    /// again).
    private func leave() {
        guard let outcome, let onFinish else { return }
        self.onFinish = nil
        // Already going away with the Link screen, or never shown.
        let leaving = isBeingDismissed || presentingViewController?.isBeingDismissed == true
        if presentingViewController != nil, !leaving {
            dismiss(animated: true) { onFinish(outcome) }
        } else {
            onFinish(outcome)
        }
    }
}

/// The metadata output retains its delegate; this proxy holds the scanner
/// weakly. Callbacks arrive on the main queue.
private final class MetadataDelegate: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    weak var owner: ScannerViewController?

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        let value = metadataObjects
            .compactMap { $0 as? AVMetadataMachineReadableCodeObject }
            .first { $0.type == .qr && !($0.stringValue ?? "").isEmpty }?
            .stringValue
        guard let value else { return }
        MainActor.assumeIsolated {
            owner?.found(value)
        }
    }
}
