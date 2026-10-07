import CoreBluetooth
import Foundation

/// Whether this device and app can use Bluetooth LE, without asking for
/// anything: `hello`'s `ble` capability and `Plugchoice.transports()`.
enum BluetoothSupport {
    /// The host's Info.plist has `NSBluetoothAlwaysUsageDescription`. Without
    /// it iOS ends the app as soon as CoreBluetooth is used, so the shell
    /// never touches CoreBluetooth then.
    static var hasUsageDescription: Bool {
        let text = Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") as? String
        return !(text?.isEmpty ?? true)
    }

    /// Every iPhone and iPad that runs iOS 16 has Bluetooth LE; the
    /// simulator has none.
    static var deviceHasBluetoothLE: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }

    static var isAvailable: Bool {
        isAvailable(hasUsageDescription: hasUsageDescription, hasBluetoothLE: deviceHasBluetoothLE)
    }

    static func isAvailable(hasUsageDescription: Bool, hasBluetoothLE: Bool) -> Bool {
        hasUsageDescription && hasBluetoothLE
    }
}

/// Bluetooth UUIDs (PROTOCOL §11): params take the full 128-bit form or a
/// 16-bit (or 32-bit) short form; answers always carry the full form in
/// lower case.
enum BLEUUID {
    /// The Bluetooth base UUID after the first 32 bits.
    private static let baseSuffix = "-0000-1000-8000-00805f9b34fb"

    /// Parses a UUID param; `invalidParams` for anything else (CBUUID raises
    /// an exception on a malformed string, so it is checked first).
    static func parse(_ text: String, key: String) throws -> CBUUID {
        guard let full = normalized(text) else {
            throw BridgeError.invalidParams("\(key) must be a Bluetooth UUID (\"a002\" or the full 128-bit form)")
        }
        return CBUUID(string: full)
    }

    /// The full lower-case form of a UUID param, or nil.
    static func normalized(_ text: String) -> String? {
        let lower = text.lowercased()
        let isHex: (Substring) -> Bool = { part in part.allSatisfy { $0.isHexDigit && $0.isASCII } }
        switch lower.count {
        case 4 where isHex(lower[...]):
            return "0000" + lower + baseSuffix
        case 8 where isHex(lower[...]):
            return lower + baseSuffix
        case 36:
            let parts = lower.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.map(\.count) == [8, 4, 4, 4, 12], parts.allSatisfy(isHex) else { return nil }
            return lower
        default:
            return nil
        }
    }

    /// The full lower-case form of a CBUUID, whatever length CoreBluetooth
    /// keeps it in.
    static func string(_ uuid: CBUUID) -> String {
        let bytes = [UInt8](uuid.data)
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        switch bytes.count {
        case 2: return "0000" + hex + baseSuffix
        case 4: return hex + baseSuffix
        case 16:
            let characters = Array(hex)
            let groups = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(characters[$0]) }
            return groups.joined(separator: "-")
        default:
            return uuid.uuidString.lowercased()
        }
    }
}

/// A device seen by `ble.scan`: `BleDevice` of PROTOCOL §11.
struct BLEScanDevice: Equatable {
    struct ManufacturerData: Equatable {
        let companyId: Int
        let data: Data
    }

    struct ServiceData: Equatable {
        let uuid: String
        let data: Data
    }

    let deviceId: String
    var name: String?
    var rssi: Int
    var serviceUuids: [String]
    var manufacturerData: [ManufacturerData]
    var serviceData: [ServiceData]
    var connectable: Bool?

    /// CoreBluetooth's RSSI when it has none.
    static let rssiUnavailable = 127

    /// From one advertisement: the advertised local name, else the name
    /// CoreBluetooth cached for the peripheral.
    init(deviceId: String, cachedName: String?, rssi: Int, advertisementData: [String: Any]) {
        self.deviceId = deviceId
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        name = (localName?.isEmpty == false ? localName : nil) ?? (cachedName?.isEmpty == false ? cachedName : nil)
        self.rssi = rssi
        var uuids: [String] = []
        for key in [CBAdvertisementDataServiceUUIDsKey, CBAdvertisementDataOverflowServiceUUIDsKey] {
            for uuid in advertisementData[key] as? [CBUUID] ?? [] {
                let text = BLEUUID.string(uuid)
                if !uuids.contains(text) { uuids.append(text) }
            }
        }
        serviceUuids = uuids
        manufacturerData = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data).flatMap(Self.manufacturerData).map { [$0] } ?? []
        serviceData = (advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:])
            .map { ServiceData(uuid: BLEUUID.string($0.key), data: $0.value) }
            .sorted { $0.uuid < $1.uuid }
        connectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue
    }

    /// Splits manufacturer data into its little-endian company id and the
    /// rest; nil when it is shorter than the id.
    static func manufacturerData(_ raw: Data) -> ManufacturerData? {
        let bytes = [UInt8](raw)
        guard bytes.count >= 2 else { return nil }
        return ManufacturerData(companyId: Int(bytes[0]) | Int(bytes[1]) << 8, data: Data(bytes[2...]))
    }

    /// A later advertisement of the same device: the latest RSSI and name
    /// (a nameless one keeps the name), service UUIDs and data added up.
    mutating func merge(_ newer: BLEScanDevice) {
        name = newer.name ?? name
        if newer.rssi != Self.rssiUnavailable || rssi == Self.rssiUnavailable {
            rssi = newer.rssi
        }
        for uuid in newer.serviceUuids where !serviceUuids.contains(uuid) {
            serviceUuids.append(uuid)
        }
        if !newer.manufacturerData.isEmpty {
            manufacturerData = newer.manufacturerData
        }
        for entry in newer.serviceData {
            serviceData.removeAll { $0.uuid == entry.uuid }
            serviceData.append(entry)
        }
        serviceData.sort { $0.uuid < $1.uuid }
        connectable = newer.connectable ?? connectable
    }

    var json: JSONObject {
        [
            "deviceId": deviceId,
            "name": name.map { $0 as Any } ?? NSNull(),
            "rssi": rssi,
            "serviceUuids": serviceUuids,
            "manufacturerData": manufacturerData.map { ["companyId": $0.companyId, "data": $0.data.base64EncodedString()] as JSONObject },
            "serviceData": serviceData.map { ["uuid": $0.uuid, "data": $0.data.base64EncodedString()] as JSONObject },
            "connectable": connectable.map { $0 as Any } ?? NSNull(),
        ]
    }
}

/// What a scan found, each device once, in the order first seen.
struct BLEScanResults {
    let stopOnName: String?
    private var order: [String] = []
    private var devices: [String: BLEScanDevice] = [:]

    init(stopOnName: String?) {
        self.stopOnName = stopOnName
    }

    var isEmpty: Bool { order.isEmpty }

    /// Adds an advertisement. Returns true when the scan should stop: the
    /// device's lower-cased name contains the lower-cased `stopOnName`.
    mutating func add(_ device: BLEScanDevice) -> Bool {
        if devices[device.deviceId] == nil {
            order.append(device.deviceId)
            devices[device.deviceId] = device
        } else {
            devices[device.deviceId]?.merge(device)
        }
        guard let stopOnName, let name = devices[device.deviceId]?.name else { return false }
        return DiscoveredServices.matches(name: name, stopOnName: stopOnName)
    }

    var json: [JSONObject] {
        order.compactMap { devices[$0]?.json }
    }
}

/// Characteristic properties as PROTOCOL §11 names them.
enum BLEProperties {
    static func names(_ properties: CBCharacteristicProperties) -> [String] {
        var names: [String] = []
        if properties.contains(.read) { names.append("read") }
        if properties.contains(.write) { names.append("write") }
        if properties.contains(.writeWithoutResponse) { names.append("writeWithoutResponse") }
        if properties.contains(.notify) { names.append("notify") }
        if properties.contains(.indicate) { names.append("indicate") }
        return names
    }

    /// Why `ble.write` can't go ahead, or nil (§11): a write without
    /// response must fit `maxWriteLength` and needs that property; one with
    /// response needs `write` and may be a long write, up to 512 bytes.
    static func writeRefusal(byteCount: Int, withResponse: Bool, maxWriteLength: Int, properties: CBCharacteristicProperties) -> BridgeError? {
        if withResponse {
            guard properties.contains(.write) else {
                return BridgeError(code: "notPermitted", message: "the characteristic can't be written with a response")
            }
        } else {
            guard properties.contains(.writeWithoutResponse) else {
                return BridgeError(code: "notPermitted", message: "the characteristic can't be written without a response")
            }
            guard byteCount <= maxWriteLength else {
                return BridgeError.invalidParams("a write without response takes at most \(maxWriteLength) bytes here")
            }
        }
        return nil
    }
}
