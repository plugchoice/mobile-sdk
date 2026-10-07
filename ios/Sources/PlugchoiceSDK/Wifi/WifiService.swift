import CoreLocation
import Foundation
import NetworkExtension
import UIKit

#if canImport(AccessorySetupKit)
// Weak: AccessorySetupKit only exists on iOS 18+, and some of its symbols
// (ASErrorDomain) carry no availability, so a plain import would link the
// framework strongly and the app would not launch on iOS 16/17.
@_weakLinked import AccessorySetupKit
#endif

/// `wifi.*`: join the charger's own access point, leave it, read the SSID.
///
/// iOS 18+ with `NSAccessorySetupKitSupports: [WiFi]` in the host app joins
/// through AccessorySetupKit (one picker per charger, silent rejoins after
/// that); everything else uses a `joinOnce` NEHotspotConfiguration (the
/// system "Join network?" sheet on every join).
@MainActor
final class WifiService {
    struct JoinRequest {
        let ssid: String
        let password: String
        let timeoutMs: Int
        let displayName: String?
        let productImageUrl: String?
    }

    private static let pollInterval: TimeInterval = 1

    private let location = LocationPermission()

    /// iOS 18+, AccessorySetupKit present, and the host's Info.plist lists
    /// `WiFi` under `NSAccessorySetupKitSupports`.
    static var accessoryJoinAvailable: Bool {
        #if canImport(AccessorySetupKit)
        if #available(iOS 18.0, *) {
            let supports = Bundle.main.object(forInfoDictionaryKey: "NSAccessorySetupKitSupports") as? [String] ?? []
            return supports.contains("WiFi")
        }
        #endif
        return false
    }

    // MARK: wifi.ensurePermissions

    /// Nothing is required up front on iOS. Location is only needed to read
    /// the SSID of a network this app did not configure, but asking now puts
    /// the prompt before the join sheet rather than in the middle of the
    /// flow. Denial is not an error here.
    func ensurePermissions() async -> JSONObject {
        await location.requestWhenInUseIfUndetermined()
        return [:]
    }

    // MARK: wifi.currentSsid

    func currentSsid() async -> String? {
        await withCheckedContinuation { continuation in
            NEHotspotNetwork.fetchCurrent { network in
                let ssid = network?.ssid
                continuation.resume(returning: (ssid?.isEmpty ?? true) ? nil : ssid)
            }
        }
    }

    // MARK: wifi.leave

    /// Best effort; never fails.
    func leave(ssid: String) {
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
    }

    // MARK: wifi.join

    /// Resolves only once the phone is on `ssid`.
    func join(_ request: JoinRequest) async throws -> JSONObject {
        let useAccessory = Self.accessoryJoinAvailable

        // Already there (joined earlier, or by hand in Settings): re-applying
        // a configuration for the current network only fails with "already
        // associated", and the picker would be a needless prompt.
        if await currentSsid() == request.ssid {
            let paired = useAccessory ? await accessoryIsPaired(ssid: request.ssid) : false
            return Self.joinResult(via: useAccessory ? "accessory" : "configuration", pickerShown: false, silentRejoin: paired)
        }

        let via: String
        let pickerShown: Bool
        let silentRejoin: Bool
        if useAccessory {
            pickerShown = try await joinWithAccessory(request)
            via = "accessory"
            silentRejoin = true
        } else {
            try await joinWithConfiguration(request)
            via = "configuration"
            pickerShown = false
            silentRejoin = false
        }

        // iOS only promises to try; wait until the phone is really on it.
        try await waitUntilOn(ssid: request.ssid, timeoutMs: request.timeoutMs)
        return Self.joinResult(via: via, pickerShown: pickerShown, silentRejoin: silentRejoin)
    }

    private static func joinResult(via: String, pickerShown: Bool, silentRejoin: Bool) -> JSONObject {
        ["via": via, "pickerShown": pickerShown, "silentRejoin": silentRejoin]
    }

    private func joinWithConfiguration(_ request: JoinRequest) async throws {
        let configuration = request.password.isEmpty
            ? NEHotspotConfiguration(ssid: request.ssid)
            : NEHotspotConfiguration(ssid: request.ssid, passphrase: request.password, isWEP: false)
        configuration.joinOnce = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NEHotspotConfigurationManager.shared.apply(configuration) { error in
                guard let error else {
                    continuation.resume()
                    return
                }
                let nsError = error as NSError
                if HotspotError.isAlreadyAssociated(nsError) {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: HotspotError.from(configurationError: nsError).bridgeError)
                }
            }
        }
    }

    /// Returns whether the accessory picker was shown.
    private func joinWithAccessory(_ request: JoinRequest) async throws -> Bool {
        #if canImport(AccessorySetupKit)
        if #available(iOS 18.0, *) {
            let imageUrl = request.productImageUrl
            return try await withCheckedThrowingContinuation { continuation in
                AccessoryHotspots.shared.join(
                    ssid: request.ssid,
                    passphrase: request.password,
                    displayName: request.displayName ?? request.ssid,
                    productImage: { deliver in
                        Task { @MainActor in
                            deliver(await ProductImage.load(from: imageUrl))
                        }
                    },
                    completion: { result in
                        switch result {
                        case .success(let pickerShown):
                            continuation.resume(returning: pickerShown)
                        case .failure(let error):
                            continuation.resume(throwing: error.bridgeError)
                        }
                    }
                )
            }
        }
        #endif
        throw BridgeError(code: "unavailableForOSVersion", message: "AccessorySetupKit needs iOS 18")
    }

    private func accessoryIsPaired(ssid: String) async -> Bool {
        #if canImport(AccessorySetupKit)
        if #available(iOS 18.0, *) {
            return await withCheckedContinuation { continuation in
                AccessoryHotspots.shared.isPaired(ssid: ssid) { continuation.resume(returning: $0) }
            }
        }
        #endif
        return false
    }

    /// Polls the current SSID about once a second until it is `ssid` or
    /// `timeoutMs` has passed since the system join call returned.
    private func waitUntilOn(ssid: String, timeoutMs: Int) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000)
        var current: String?
        while true {
            current = await currentSsid()
            if current == ssid { return }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            try await Task.sleep(nanoseconds: UInt64(min(Self.pollInterval, remaining) * 1_000_000_000))
        }
        if let current {
            throw BridgeError(code: "unableToConnect", message: "on \(current) instead of \(ssid) \(timeoutMs) ms after the join")
        }
        throw BridgeError(code: "timeoutOccurred", message: "not on \(ssid) \(timeoutMs) ms after the join")
    }
}

/// Requests when-in-use location once, if the host app can ask for it.
@MainActor
private final class LocationPermission: NSObject, CLLocationManagerDelegate {
    private var manager: CLLocationManager?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func requestWhenInUseIfUndetermined() async {
        // Without the usage description iOS ignores the request and never
        // calls back, so don't wait for it.
        guard Bundle.main.object(forInfoDictionaryKey: "NSLocationWhenInUseUsageDescription") != nil else { return }
        let manager = self.manager ?? CLLocationManager()
        self.manager = manager
        guard manager.authorizationStatus == .notDetermined else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            if waiters.count == 1 {
                manager.delegate = self
                manager.requestWhenInUseAuthorization()
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        onMain { [weak self] in
            guard let self, status != .notDetermined else { return }
            let waiters = self.waiters
            self.waiters = []
            waiters.forEach { $0.resume() }
        }
    }
}

/// The picker's product image: downloaded from `productImageUrl` with a short
/// timeout, or a generic charger symbol.
enum ProductImage {
    private static let timeout: TimeInterval = 5

    @MainActor
    static func load(from urlString: String?) async -> UIImage {
        if let urlString,
           let url = URL(string: urlString),
           let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = timeout
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            let session = URLSession(configuration: configuration)
            defer { session.finishTasksAndInvalidate() }
            if let loaded = try? await session.data(from: url),
               let http = loaded.1 as? HTTPURLResponse, (200..<300).contains(http.statusCode),
               let image = UIImage(data: loaded.0) {
                return image
            }
        }
        return fallback()
    }

    /// `ev.charger` drawn into a bitmap (a bare symbol image renders tiny and
    /// tinted wrong in the picker).
    static func fallback() -> UIImage {
        let configuration = UIImage.SymbolConfiguration(pointSize: 96, weight: .regular)
        guard let symbol = UIImage(systemName: "ev.charger", withConfiguration: configuration)
            ?? UIImage(systemName: "bolt.fill", withConfiguration: configuration)
        else { return UIImage() }
        let tinted = symbol.withTintColor(.systemGray, renderingMode: .alwaysOriginal)
        let canvas = CGSize(width: 180, height: 180)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        return UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
            let size = tinted.size
            let scale = min(canvas.width / size.width, canvas.height / size.height, 1)
            let drawn = CGSize(width: size.width * scale, height: size.height * scale)
            tinted.draw(in: CGRect(
                x: (canvas.width - drawn.width) / 2,
                y: (canvas.height - drawn.height) / 2,
                width: drawn.width,
                height: drawn.height
            ))
        }
    }
}
