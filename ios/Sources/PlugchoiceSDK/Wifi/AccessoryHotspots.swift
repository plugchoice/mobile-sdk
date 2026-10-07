import Foundation
import NetworkExtension
import UIKit

#if canImport(AccessorySetupKit)
// Weak: AccessorySetupKit only exists on iOS 18+, and some of its symbols
// (ASErrorDomain) carry no availability, so a plain import would link the
// framework strongly and the app would not launch on iOS 16/17.
@_weakLinked import AccessorySetupKit
#endif

/// An error with a PROTOCOL.md `wifi.join` code.
struct HotspotError: Error {
    let code: String
    let message: String

    var bridgeError: BridgeError { BridgeError(code: code, message: message) }

    /// NEHotspotConfiguration errors to PROTOCOL.md codes. Malformed
    /// SSIDs/configurations answer `invalidParams` (`invalidSSID` is not a
    /// protocol code).
    static func from(configurationError error: NSError) -> HotspotError {
        guard error.domain == NEHotspotConfigurationErrorDomain,
              let known = NEHotspotConfigurationError(rawValue: error.code)
        else {
            return HotspotError(code: "unableToConnect", message: "\(error.localizedDescription) (\(error.domain) \(error.code))")
        }
        let code: String
        switch known {
        case .userDenied: code = "userDenied"
        case .invalidWPAPassphrase, .invalidWEPPassphrase: code = "invalidPassphrase"
        case .invalid, .invalidSSID, .invalidSSIDPrefix: code = "invalidParams"
        default: code = "unableToConnect"
        }
        return HotspotError(code: code, message: "\(error.localizedDescription) (NEHotspotConfigurationError \(error.code))")
    }

    static func isAlreadyAssociated(_ error: NSError) -> Bool {
        error.domain == NEHotspotConfigurationErrorDomain
            && error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue
    }
}

#if canImport(AccessorySetupKit)

/// Joins a charger's setup hotspot through AccessorySetupKit. The user picks
/// the charger once in the system accessory picker; after that every join of
/// its SSID happens without the "Join network?" sheet, which matters because
/// the charger's hotspot drops whenever it reboots during commissioning.
///
/// The product image comes from a provider that is only asked when the
/// picker is actually shown (it may download it), and error codes go through
/// `HotspotError.from(configurationError:)`.
///
/// One instance per process (the session and its pairings are app-wide).
/// Everything runs on the main queue.
@available(iOS 18.0, *)
final class AccessoryHotspots {
    static let shared = AccessoryHotspots()

    /// Hands the picker its product image; called at most once per pick.
    typealias ImageProvider = (@escaping (UIImage) -> Void) -> Void

    private var session: ASAccessorySession?
    private var activated = false
    private var activationWaiters: [(Result<ASAccessorySession, HotspotError>) -> Void] = []
    private var pendingPick: PendingPick?

    private final class PendingPick {
        let ssid: String
        let completion: (Result<ASAccessory, HotspotError>) -> Void
        var accessory: ASAccessory?
        var finished = false

        init(ssid: String, completion: @escaping (Result<ASAccessory, HotspotError>) -> Void) {
            self.ssid = ssid
            self.completion = completion
        }

        func finish(_ result: Result<ASAccessory, HotspotError>) {
            if finished { return }
            finished = true
            completion(result)
        }
    }

    func isPaired(ssid: String, completion: @escaping (Bool) -> Void) {
        withSession { result in
            switch result {
            case .success(let session):
                completion(Self.accessory(in: session, ssid: ssid) != nil)
            case .failure:
                completion(false)
            }
        }
    }

    /// Completes with whether the picker had to be shown (the only prompt on
    /// this path), after iOS accepted the join request. The caller still
    /// verifies the joined SSID.
    func join(
        ssid: String,
        passphrase: String,
        displayName: String,
        productImage: @escaping ImageProvider,
        completion: @escaping (Result<Bool, HotspotError>) -> Void
    ) {
        withSession { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let session):
                if let accessory = Self.accessory(in: session, ssid: ssid) {
                    Self.joinHotspot(accessory, passphrase: passphrase) { completion($0.map { false }) }
                    return
                }
                productImage { image in
                    self.pick(ssid: ssid, displayName: displayName, image: image, session: session) { picked in
                        switch picked {
                        case .failure(let error):
                            completion(.failure(error))
                        case .success(let accessory):
                            Self.joinHotspot(accessory, passphrase: passphrase) { completion($0.map { true }) }
                        }
                    }
                }
            }
        }
    }

    private func withSession(_ body: @escaping (Result<ASAccessorySession, HotspotError>) -> Void) {
        if activated, let session {
            body(.success(session))
            return
        }
        activationWaiters.append(body)
        if session != nil { return }
        let session = ASAccessorySession()
        self.session = session
        session.activate(on: .main) { [weak self] event in
            self?.handle(event)
        }
    }

    private func handle(_ event: ASAccessoryEvent) {
        switch event.eventType {
        case .activated:
            activated = true
            guard let session else { return }
            let waiters = activationWaiters
            activationWaiters = []
            waiters.forEach { $0(.success(session)) }
        case .invalidated:
            // An invalidated session is unusable; the next call starts a new one.
            activated = false
            session = nil
            let error = HotspotError(code: "unableToConnect", message: "accessory session invalidated")
            let waiters = activationWaiters
            activationWaiters = []
            waiters.forEach { $0(.failure(error)) }
            pendingPick?.finish(.failure(error))
            pendingPick = nil
        case .accessoryAdded, .accessoryChanged:
            if let pending = pendingPick, let accessory = event.accessory, accessory.ssid == pending.ssid {
                pending.accessory = accessory
            }
        case .pickerSetupFailed:
            if let pending = pendingPick {
                pendingPick = nil
                pending.finish(.failure(Self.pickerError(event.error)))
            }
        case .pickerDidDismiss:
            guard let pending = pendingPick else { return }
            if let accessory = pending.accessory {
                pendingPick = nil
                pending.finish(.success(accessory))
                return
            }
            // The added event can trail the dismissal; give it a moment before
            // treating the dismissal as a cancel.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.pendingPick === pending else { return }
                self.pendingPick = nil
                if let accessory = pending.accessory ?? self.session.flatMap({ Self.accessory(in: $0, ssid: pending.ssid) }) {
                    pending.finish(.success(accessory))
                } else {
                    pending.finish(.failure(HotspotError(code: "userDenied", message: "accessory picker dismissed")))
                }
            }
        default:
            break
        }
    }

    private func pick(
        ssid: String,
        displayName: String,
        image: UIImage,
        session: ASAccessorySession,
        completion: @escaping (Result<ASAccessory, HotspotError>) -> Void
    ) {
        if pendingPick != nil {
            completion(.failure(HotspotError(code: "unableToConnect", message: "accessory picker already showing")))
            return
        }
        let pending = PendingPick(ssid: ssid, completion: completion)
        pendingPick = pending

        let descriptor = ASDiscoveryDescriptor()
        descriptor.ssid = ssid
        let item = ASPickerDisplayItem(name: displayName, productImage: image, descriptor: descriptor)
        session.showPicker(for: [item]) { [weak self] error in
            DispatchQueue.main.async {
                guard let error, let self, self.pendingPick === pending else { return }
                self.pendingPick = nil
                pending.finish(.failure(Self.pickerError(error)))
            }
        }
    }

    private static func accessory(in session: ASAccessorySession, ssid: String) -> ASAccessory? {
        session.accessories.first { $0.ssid == ssid && $0.state == .authorized }
    }

    private static func joinHotspot(
        _ accessory: ASAccessory,
        passphrase: String,
        completion: @escaping (Result<Void, HotspotError>) -> Void
    ) {
        let handler: (Error?) -> Void = { error in
            DispatchQueue.main.async {
                guard let error else {
                    completion(.success(()))
                    return
                }
                let nsError = error as NSError
                if HotspotError.isAlreadyAssociated(nsError) {
                    completion(.success(()))
                    return
                }
                completion(.failure(HotspotError.from(configurationError: nsError)))
            }
        }
        if passphrase.isEmpty {
            NEHotspotConfigurationManager.shared.joinAccessoryHotspotWithoutSecurity(accessory, completionHandler: handler)
        } else {
            NEHotspotConfigurationManager.shared.joinAccessoryHotspot(accessory, passphrase: passphrase, completionHandler: handler)
        }
    }

    private static func pickerError(_ error: Error?) -> HotspotError {
        guard let error else {
            return HotspotError(code: "unableToConnect", message: "accessory setup failed")
        }
        let nsError = error as NSError
        if nsError.domain == ASErrorDomain,
           nsError.code == ASError.Code.userCancelled.rawValue
            || nsError.code == ASError.Code.userRestricted.rawValue {
            return HotspotError(code: "userDenied", message: nsError.localizedDescription)
        }
        if nsError.domain == ASErrorDomain, nsError.code == ASError.Code.discoveryTimeout.rawValue {
            return HotspotError(code: "didNotFindNetwork", message: nsError.localizedDescription)
        }
        return HotspotError(code: "unableToConnect", message: "\(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))")
    }
}

#endif
