import Foundation

/// What we know about a USB-connected iPhone or iPad.
struct DeviceInfo: Identifiable, Equatable {
    let udid: String
    var id: String { udid }
    var name = "Connecting…"
    var productType = ""
    var deviceClass = ""
    var osVersion = ""
    var trusted = false
    var developerMode: Bool?
    /// Space free right now (what an install can use without iOS purging caches).
    var freeBytes: Int64?
    /// Free space including purgeable storage iOS may reclaim.
    var availableWithPurgeable: Int64?
    var dataCapacity: Int64?
    var problem: String?

    var summary: String {
        [deviceClass, osVersion.isEmpty ? "" : "iOS \(osVersion)", productType]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

/// A provisioning profile installed on the device. iOS refuses to launch an
/// app once every profile that covers it has expired.
struct DeviceProfile: Equatable {
    let uuid: String
    let name: String
    let teamID: String
    let appIDPattern: String
    let expiration: Date
    let capabilities: Set<Capability>

    var isWildcard: Bool { appIDPattern.hasSuffix("*") }

    func matches(bundleID: String) -> Bool {
        if isWildcard { return bundleID.hasPrefix(String(appIDPattern.dropLast())) }
        return appIDPattern == bundleID
    }

    /// The profile governing an app: the newest exact match, else the newest wildcard.
    static func governing(_ bundleID: String, in profiles: [DeviceProfile]) -> DeviceProfile? {
        let matching = profiles.filter { $0.matches(bundleID: bundleID) }
        let exact = matching.filter { !$0.isWildcard }
        return (exact.isEmpty ? matching : exact).max { $0.expiration < $1.expiration }
    }
}

/// Thin wrapper over Apple's private MobileDevice.framework (the same
/// framework Finder and Xcode use) for device discovery and lockdown values.
final class MobileDevice: @unchecked Sendable {
    static let shared = MobileDevice()

    typealias NotifyCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    private typealias SubscribeFn = @convention(c) (
        NotifyCallback, UInt32, UInt32, UnsafeMutableRawPointer?,
        UnsafeMutablePointer<UnsafeMutableRawPointer?>
    ) -> Int32
    private typealias DeviceFn = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias CopyValueFn = @convention(c) (UnsafeMutableRawPointer, CFString?, CFString?) -> Unmanaged<CFTypeRef>?
    private typealias CopyStringFn = @convention(c) (UnsafeMutableRawPointer) -> Unmanaged<CFString>?

    private let subscribeFn: SubscribeFn?
    private let connectFn: DeviceFn?
    private let disconnectFn: DeviceFn?
    private let startSessionFn: DeviceFn?
    private let stopSessionFn: DeviceFn?
    private let interfaceTypeFn: DeviceFn?
    private let copyValueFn: CopyValueFn?
    private let copyIdentifierFn: CopyStringFn?
    private typealias CopyProfilesFn = @convention(c) (UnsafeMutableRawPointer) -> Unmanaged<CFArray>?
    private typealias ProfilePayloadFn = @convention(c) (UnsafeRawPointer) -> Unmanaged<CFDictionary>?
    private let copyProfilesFn: CopyProfilesFn?
    private let profilePayloadFn: ProfilePayloadFn?

    var isAvailable: Bool {
        subscribeFn != nil && connectFn != nil && copyValueFn != nil && copyIdentifierFn != nil
    }

    private init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice", RTLD_NOW)
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let handle, let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        subscribeFn = symbol("AMDeviceNotificationSubscribe", SubscribeFn.self)
        connectFn = symbol("AMDeviceConnect", DeviceFn.self)
        disconnectFn = symbol("AMDeviceDisconnect", DeviceFn.self)
        startSessionFn = symbol("AMDeviceStartSession", DeviceFn.self)
        stopSessionFn = symbol("AMDeviceStopSession", DeviceFn.self)
        interfaceTypeFn = symbol("AMDeviceGetInterfaceType", DeviceFn.self)
        copyValueFn = symbol("AMDeviceCopyValue", CopyValueFn.self)
        copyIdentifierFn = symbol("AMDeviceCopyDeviceIdentifier", CopyStringFn.self)
        copyProfilesFn = symbol("AMDeviceCopyProvisioningProfiles", CopyProfilesFn.self)
        profilePayloadFn = symbol("MISProfileCopyPayload", ProfilePayloadFn.self)
    }

    /// Reads the provisioning profiles installed on the device. Blocking.
    func readProfiles(_ device: UnsafeMutableRawPointer) -> [DeviceProfile] {
        guard let connectFn, let disconnectFn, let startSessionFn, let stopSessionFn,
              let copyProfilesFn, let profilePayloadFn,
              connectFn(device) == 0 else { return [] }
        defer { _ = disconnectFn(device) }
        guard startSessionFn(device) == 0 else { return [] }
        defer { _ = stopSessionFn(device) }
        guard let list = copyProfilesFn(device)?.takeRetainedValue() as? [AnyObject] else { return [] }

        return list.compactMap { object in
            let pointer = UnsafeRawPointer(Unmanaged.passUnretained(object).toOpaque())
            guard let payload = profilePayloadFn(pointer)?.takeRetainedValue() as? [String: Any],
                  let entitlements = payload["Entitlements"] as? [String: Any],
                  let appID = entitlements["application-identifier"] as? String,
                  let expiration = payload["ExpirationDate"] as? Date
            else { return nil }
            let team = (payload["TeamIdentifier"] as? [String])?.first
                ?? String(appID.split(separator: ".").first ?? "")
            return DeviceProfile(
                uuid: payload["UUID"] as? String ?? UUID().uuidString,
                name: payload["Name"] as? String ?? appID,
                teamID: team,
                appIDPattern: appID.hasPrefix(team + ".") ? String(appID.dropFirst(team.count + 1)) : appID,
                expiration: expiration,
                capabilities: Capability.present(in: entitlements)
            )
        }
    }

    func subscribe(_ callback: NotifyCallback) -> Bool {
        var token: UnsafeMutableRawPointer?
        return subscribeFn?(callback, 0, 0, nil, &token) == 0
    }

    /// 1 = USB, 2 = Wi-Fi.
    func interfaceType(_ device: UnsafeMutableRawPointer) -> Int32 {
        interfaceTypeFn?(device) ?? 0
    }

    func identifier(_ device: UnsafeMutableRawPointer) -> String? {
        copyIdentifierFn?(device)?.takeRetainedValue() as String?
    }

    private func value(_ device: UnsafeMutableRawPointer, _ domain: String?, _ key: String) -> AnyObject? {
        copyValueFn?(device, domain as CFString?, key as CFString)?.takeRetainedValue()
    }

    /// Connects, opens a lockdown session and reads name, OS and storage.
    /// Blocking; call off the main thread.
    func readInfo(_ device: UnsafeMutableRawPointer, udid: String) -> DeviceInfo {
        var info = DeviceInfo(udid: udid)
        guard let connectFn, let disconnectFn, let startSessionFn, let stopSessionFn else {
            info.problem = "MobileDevice.framework is unavailable."
            return info
        }
        let connected = connectFn(device)
        guard connected == 0 else {
            info.name = "iOS Device"
            info.problem = String(format: "Couldn't connect to the device (0x%08X).", UInt32(bitPattern: connected))
            return info
        }
        defer { _ = disconnectFn(device) }

        if let name = value(device, nil, "DeviceName") as? String { info.name = name }
        if let type = value(device, nil, "ProductType") as? String { info.productType = type }
        if let cls = value(device, nil, "DeviceClass") as? String { info.deviceClass = cls }
        if let version = value(device, nil, "ProductVersion") as? String { info.osVersion = version }

        guard startSessionFn(device) == 0 else {
            if info.name == "Connecting…" { info.name = "iOS Device" }
            info.problem = "Unlock the device and tap “Trust This Computer”, then click Refresh."
            return info
        }
        defer { _ = stopSessionFn(device) }
        info.trusted = true

        if let name = value(device, nil, "DeviceName") as? String { info.name = name }
        if let type = value(device, nil, "ProductType") as? String { info.productType = type }
        if let cls = value(device, nil, "DeviceClass") as? String { info.deviceClass = cls }
        if let version = value(device, nil, "ProductVersion") as? String { info.osVersion = version }

        let disk = "com.apple.disk_usage"
        info.freeBytes = (value(device, disk, "AmountDataAvailable") as? NSNumber)?.int64Value
        info.availableWithPurgeable = (value(device, disk, "TotalDataAvailable") as? NSNumber)?.int64Value
        info.dataCapacity = (value(device, disk, "TotalDataCapacity") as? NSNumber)?.int64Value
        if let mode = value(device, "com.apple.security.mac.amfi", "DeveloperModeStatus") as? NSNumber {
            info.developerMode = mode.boolValue
        }
        return info
    }
}

private let deviceNotificationCallback: MobileDevice.NotifyCallback = { info, _ in
    guard let info else { return }
    guard let device = info.load(as: UnsafeMutableRawPointer?.self) else { return }
    let message = info.load(fromByteOffset: MemoryLayout<UnsafeMutableRawPointer>.size, as: UInt32.self)
    // Keep the device object alive until the main actor has looked at it.
    _ = Unmanaged<AnyObject>.fromOpaque(device).retain()
    let bits = UInt(bitPattern: device)
    Task { @MainActor in
        DeviceMonitor.shared.handle(deviceBits: bits, message: message)
    }
}

/// Publishes the iPhones and iPads attached over USB.
@MainActor
final class DeviceMonitor: ObservableObject {
    static let shared = DeviceMonitor()

    @Published private(set) var devices: [DeviceInfo] = []
    @Published private(set) var startupError: String?

    private var references: [String: UInt] = [:]
    private let queue = DispatchQueue(label: "local.ipacourier.mobiledevice")
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        guard MobileDevice.shared.isAvailable else {
            startupError = "Couldn't load MobileDevice.framework. Is Xcode installed?"
            return
        }
        if !MobileDevice.shared.subscribe(deviceNotificationCallback) {
            startupError = "Couldn't listen for USB devices."
        }
    }

    fileprivate func handle(deviceBits: UInt, message: UInt32) {
        guard let device = UnsafeMutableRawPointer(bitPattern: deviceBits) else { return }
        defer { Unmanaged<AnyObject>.fromOpaque(device).release() }
        let api = MobileDevice.shared
        guard api.interfaceType(device) == 1, let udid = api.identifier(device) else { return }

        switch message {
        case 1: // connected
            if let old = references[udid], let pointer = UnsafeMutableRawPointer(bitPattern: old) {
                Unmanaged<AnyObject>.fromOpaque(pointer).release()
            }
            _ = Unmanaged<AnyObject>.fromOpaque(device).retain()
            references[udid] = deviceBits
            if !devices.contains(where: { $0.udid == udid }) {
                devices.append(DeviceInfo(udid: udid))
            }
            Task { await refresh(udid) }
        case 2: // disconnected
            if let old = references.removeValue(forKey: udid),
               let pointer = UnsafeMutableRawPointer(bitPattern: old) {
                Unmanaged<AnyObject>.fromOpaque(pointer).release()
            }
            devices.removeAll { $0.udid == udid }
        default:
            break
        }
    }

    func isConnected(_ udid: String) -> Bool { references[udid] != nil }

    /// Re-reads name, trust state and free space.
    @discardableResult
    func refresh(_ udid: String) async -> DeviceInfo? {
        guard let bits = references[udid], let device = UnsafeMutableRawPointer(bitPattern: bits) else {
            return nil
        }
        _ = Unmanaged<AnyObject>.fromOpaque(device).retain()
        let info: DeviceInfo = await withCheckedContinuation { continuation in
            queue.async {
                let pointer = UnsafeMutableRawPointer(bitPattern: bits)!
                let result = MobileDevice.shared.readInfo(pointer, udid: udid)
                Unmanaged<AnyObject>.fromOpaque(pointer).release()
                continuation.resume(returning: result)
            }
        }
        guard references[udid] != nil else { return nil }
        if let index = devices.firstIndex(where: { $0.udid == udid }) {
            devices[index] = info
        }
        return info
    }

    /// Provisioning profiles installed on the device.
    func profiles(_ udid: String) async -> [DeviceProfile] {
        guard let bits = references[udid], let device = UnsafeMutableRawPointer(bitPattern: bits) else {
            return []
        }
        _ = Unmanaged<AnyObject>.fromOpaque(device).retain()
        return await withCheckedContinuation { continuation in
            queue.async {
                let pointer = UnsafeMutableRawPointer(bitPattern: bits)!
                let result = MobileDevice.shared.readProfiles(pointer)
                Unmanaged<AnyObject>.fromOpaque(pointer).release()
                continuation.resume(returning: result)
            }
        }
    }

    func refreshAll() async {
        for device in devices { await refresh(device.udid) }
    }
}
