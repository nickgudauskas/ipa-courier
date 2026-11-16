import Foundation

enum APKKind: String {
    case apk, xapk, apks

    init?(url: URL) {
        switch url.pathExtension.lowercased() {
        case "apk": self = .apk
        case "xapk": self = .xapk
        case "apks", "apkm": self = .apks
        default: return nil
        }
    }

    var isBundle: Bool { self != .apk }
}

/// What IPA Courier knows about an Android package file.
struct APKInfo: Equatable {
    let url: URL
    let kind: APKKind
    var label: String
    var package: String?
    var versionName: String?
    var versionCode: Int?
    var minSdk: Int?
    /// Native code architectures inside (empty means pure Java/Kotlin: runs anywhere).
    var abis: Set<String> = []
    var size: Int64 = 0

    var versionText: String { versionName ?? versionCode.map(String.init) ?? "?" }
}

enum APKInfoError: LocalizedError {
    case notAPK(String)
    var errorDescription: String? {
        switch self {
        case .notAPK(let name): return "\(name) isn't an Android package (.apk, .xapk or .apks)."
        }
    }
}

enum APKReader {
    static func read(_ url: URL) async throws -> APKInfo {
        guard let kind = APKKind(url: url) else { throw APKInfoError.notAPK(url.lastPathComponent) }
        let size = ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize).map(Int64.init) ?? 0
        var info = APKInfo(url: url, kind: kind, label: prettyName(url), size: size)
        let entries = (try? await Shell.run("/usr/bin/zipinfo", ["-1", url.path]))?.text
            .split(whereSeparator: \.isNewline).map(String.init) ?? []
        guard !entries.isEmpty else { throw APKInfoError.notAPK(url.lastPathComponent) }

        switch kind {
        case .apk:
            if let manifest = await entry("AndroidManifest.xml", in: url) {
                await apply(BinaryManifest.parse(manifest), to: &info, apk: url)
            }
            info.abis = abis(in: entries)
        case .xapk:
            if let data = await entry("manifest.json", in: url),
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                if let name = json["name"] as? String, !name.isEmpty { info.label = name }
                info.package = json["package_name"] as? String
                info.versionName = json["version_name"] as? String
                info.versionCode = (json["version_code"] as? String).flatMap(Int.init) ?? json["version_code"] as? Int
                info.minSdk = (json["min_sdk_version"] as? String).flatMap(Int.init) ?? json["min_sdk_version"] as? Int
            }
            info.abis = Set(entries.compactMap(splitABI))
        case .apks:
            // bundletool / APKMirror bundles: read the base split's manifest.
            if let base = entries.first(where: { $0.hasSuffix("base-master.apk") || $0 == "base.apk" || $0.hasSuffix("/base.apk") }) {
                let work = FileManager.default.temporaryDirectory.appendingPathComponent("ipa-courier-apks-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: work) }
                try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                if (try? await Shell.run("/usr/bin/unzip", ["-o", "-q", url.path, base, "-d", work.path])) != nil,
                   let manifest = await entry("AndroidManifest.xml", in: work.appendingPathComponent(base)) {
                    await apply(BinaryManifest.parse(manifest), to: &info, apk: work.appendingPathComponent(base))
                }
            }
            info.abis = Set(entries.compactMap(splitABI))
        }
        return info
    }

    private static func apply(_ manifest: BinaryManifest.Result, to info: inout APKInfo, apk: URL) async {
        info.package = manifest.package ?? info.package
        info.versionName = manifest.versionName ?? info.versionName
        info.versionCode = manifest.versionCode ?? info.versionCode
        info.minSdk = manifest.minSdk ?? info.minSdk
        if let label = manifest.label, !label.isEmpty {
            info.label = label
        } else if let ref = manifest.labelRef, let table = await entry("resources.arsc", in: apk),
                  let label = ResourceTable.string(ref, in: table), !label.isEmpty {
            info.label = label
        }
    }

    private static func entry(_ name: String, in archive: URL) async -> Data? {
        guard let result = try? await Shell.run("/usr/bin/unzip", ["-p", archive.path, name], mergeStderr: false),
              !result.output.isEmpty else { return nil }
        return result.output
    }

    private static func abis(in entries: [String]) -> Set<String> {
        Set(entries.compactMap { entry -> String? in
            let parts = entry.split(separator: "/")
            guard parts.count >= 3, parts[0] == "lib", entry.hasSuffix(".so") else { return nil }
            return String(parts[1])
        })
    }

    /// "config.arm64_v8a.apk" → "arm64-v8a".
    static func splitABI(_ entry: String) -> String? {
        let name = (entry as NSString).lastPathComponent.lowercased()
        // Split names use underscores; Android's ABI names mix hyphens (arm64-v8a) and underscores (x86_64).
        let abis: [(split: String, abi: String)] = [("arm64_v8a", "arm64-v8a"), ("armeabi_v7a", "armeabi-v7a"),
                                                    ("x86_64", "x86_64"), ("x86", "x86"), ("armeabi", "armeabi")]
        for (split, abi) in abis where name.contains("config.\(split)") || name.contains("-\(split)") {
            return abi
        }
        return nil
    }

    /// "Melee-Android-arm64.apk" → "Melee Android arm64" when the manifest has no plain-text label.
    static func prettyName(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }
}

/// Minimal reader for Android's compiled (binary) AndroidManifest.xml.
enum BinaryManifest {
    struct Result {
        var package: String?
        var versionName: String?
        var versionCode: Int?
        var minSdk: Int?
        var label: String?
        /// Resource ID when the label is a reference such as @string/app_name.
        var labelRef: UInt32?
    }

    // android: attribute resource IDs, used when attribute name strings are stripped.
    private static let versionCodeID: UInt32 = 0x0101_021B
    private static let versionNameID: UInt32 = 0x0101_021C
    private static let minSdkID: UInt32 = 0x0101_020C
    private static let labelID: UInt32 = 0x0101_0001

    static func parse(_ data: Data) -> Result {
        let bytes = [UInt8](data)
        var result = Result()
        guard bytes.count > 8, u16(bytes, 0) == 0x0003 else { return result }

        var strings: [String] = []
        var resourceIDs: [UInt32] = []
        var offset = Int(u16(bytes, 2)) // past the XML header
        while offset + 8 <= bytes.count {
            let type = u16(bytes, offset)
            let headerSize = Int(u16(bytes, offset + 2))
            let size = Int(u32(bytes, offset + 4))
            guard size >= 8, offset + size <= bytes.count else { break }

            switch type {
            case 0x0001: // string pool
                strings = stringPool(bytes, at: offset)
            case 0x0180: // resource ID map: string index → attribute resource ID
                let count = (size - headerSize) / 4
                resourceIDs = (0..<count).map { u32(bytes, offset + headerSize + $0 * 4) }
            case 0x0102: // start element
                let nameIndex = Int(u32(bytes, offset + 20))
                let attributeStart = Int(u16(bytes, offset + 24))
                let attributeSize = Int(u16(bytes, offset + 26))
                let attributeCount = Int(u16(bytes, offset + 28))
                let element = nameIndex < strings.count ? strings[nameIndex] : ""
                guard ["manifest", "uses-sdk", "application"].contains(element) else { break }
                for index in 0..<attributeCount {
                    let base = offset + 16 + attributeStart + index * attributeSize
                    guard base + 20 <= bytes.count else { break }
                    let nameIdx = Int(u32(bytes, base + 4))
                    let raw = u32(bytes, base + 8)
                    let dataType = bytes[base + 15]
                    let value = u32(bytes, base + 16)
                    let name = nameIdx < strings.count ? strings[nameIdx] : ""
                    let resID = nameIdx < resourceIDs.count ? resourceIDs[nameIdx] : 0
                    let stringValue: String? = raw != 0xFFFF_FFFF && Int(raw) < strings.count ? strings[Int(raw)]
                        : (dataType == 0x03 && Int(value) < strings.count ? strings[Int(value)] : nil)
                    let intValue: Int? = (dataType == 0x10 || dataType == 0x11) ? Int(Int32(bitPattern: value))
                        : stringValue.flatMap(Int.init)

                    switch element {
                    case "manifest":
                        if name == "package" { result.package = stringValue }
                        if name == "versionName" || resID == versionNameID { result.versionName = stringValue ?? intValue.map(String.init) }
                        if name == "versionCode" || resID == versionCodeID { result.versionCode = intValue }
                    case "uses-sdk":
                        if name == "minSdkVersion" || resID == minSdkID { result.minSdk = intValue }
                    case "application":
                        if name == "label" || resID == labelID {
                            if dataType == 0x01 { result.labelRef = value } else { result.label = stringValue }
                        }
                    default: break
                    }
                }
            default:
                break
            }
            offset += size
        }
        return result
    }

    static func stringPool(_ b: [UInt8], at start: Int) -> [String] {
        let count = Int(u32(b, start + 8))
        let flags = u32(b, start + 16)
        let stringsStart = Int(u32(b, start + 20))
        let utf8 = flags & 0x100 != 0
        let headerSize = Int(u16(b, start + 2))
        var result: [String] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            let offsetPos = start + headerSize + i * 4
            guard offsetPos + 4 <= b.count else { break }
            var p = start + stringsStart + Int(u32(b, offsetPos))
            guard p < b.count else { result.append(""); continue }
            if utf8 {
                // UTF-16 length (1–2 bytes), then UTF-8 byte length (1–2 bytes), then bytes.
                p += b[p] & 0x80 != 0 ? 2 : 1
                guard p + 1 < b.count else { result.append(""); continue }
                var length = Int(b[p])
                if length & 0x80 != 0 { length = ((length & 0x7F) << 8) | Int(b[p + 1]); p += 2 } else { p += 1 }
                let end = min(p + length, b.count)
                result.append(String(decoding: b[p..<end], as: UTF8.self))
            } else {
                var length = Int(u16(b, p))
                if length & 0x8000 != 0 { length = ((length & 0x7FFF) << 16) | Int(u16(b, p + 2)); p += 4 } else { p += 2 }
                var units: [UInt16] = []
                units.reserveCapacity(length)
                for j in 0..<length where p + j * 2 + 1 < b.count { units.append(u16(b, p + j * 2)) }
                result.append(String(decoding: units, as: UTF16.self))
            }
        }
        return result
    }

    static func u16(_ b: [UInt8], _ i: Int) -> UInt16 {
        guard i + 1 < b.count else { return 0 }
        return UInt16(b[i]) | UInt16(b[i + 1]) << 8
    }

    static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        guard i + 3 < b.count else { return 0 }
        return UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}

/// Looks up a string resource (e.g. the app name) in an APK's resources.arsc.
enum ResourceTable {
    static func string(_ id: UInt32, in data: Data, depth: Int = 0) -> String? {
        let b = [UInt8](data)
        let u16 = BinaryManifest.u16, u32 = BinaryManifest.u32
        guard b.count > 12, u16(b, 0) == 0x0002 else { return nil }
        let wantPackage = Int(id >> 24), wantType = Int((id >> 16) & 0xFF), wantEntry = Int(id & 0xFFFF)

        var globalStrings: [String] = []
        var fallback: String?
        var offset = Int(u16(b, 2))
        while offset + 8 <= b.count {
            let type = u16(b, offset), size = Int(u32(b, offset + 4))
            guard size >= 8, offset + size <= b.count else { break }
            if type == 0x0001 && globalStrings.isEmpty {
                globalStrings = BinaryManifest.stringPool(b, at: offset)
            } else if type == 0x0200, Int(u32(b, offset + 8)) == wantPackage {
                // Walk the package's chunks for type chunks of the wanted type.
                var inner = offset + Int(u16(b, offset + 2))
                let end = offset + size
                while inner + 8 <= end {
                    let innerType = u16(b, inner), innerSize = Int(u32(b, inner + 4))
                    guard innerSize >= 8, inner + innerSize <= end else { break }
                    if innerType == 0x0201, Int(b[inner + 8]) == wantType,
                       let value = entryValue(b, chunk: inner, entry: wantEntry) {
                        let language = u16(b, inner + 20 + 8)
                        var text: String?
                        if value.type == 0x03, Int(value.data) < globalStrings.count {
                            text = globalStrings[Int(value.data)]
                        } else if value.type == 0x01, depth < 2 {
                            text = string(value.data, in: data, depth: depth + 1)
                        }
                        if let text {
                            if language == 0 { return text } // default configuration
                            fallback = fallback ?? text
                        }
                    }
                    inner += innerSize
                }
            }
            offset += size
        }
        return fallback
    }

    private static func entryValue(_ b: [UInt8], chunk: Int, entry: Int) -> (type: UInt8, data: UInt32)? {
        let u16 = BinaryManifest.u16, u32 = BinaryManifest.u32
        let flags = b[chunk + 9]
        let headerSize = Int(u16(b, chunk + 2))
        let entryCount = Int(u32(b, chunk + 12))
        let entriesStart = Int(u32(b, chunk + 16))
        var entryOffset: Int?
        if flags & 0x01 != 0 { // sparse: (index u16, offset/4 u16) pairs
            for i in 0..<entryCount {
                let p = chunk + headerSize + i * 4
                if Int(u16(b, p)) == entry { entryOffset = Int(u16(b, p + 2)) * 4; break }
            }
        } else if flags & 0x02 != 0 { // 16-bit offsets
            guard entry < entryCount else { return nil }
            let raw = u16(b, chunk + headerSize + entry * 2)
            if raw != 0xFFFF { entryOffset = Int(raw) * 4 }
        } else {
            guard entry < entryCount else { return nil }
            let raw = u32(b, chunk + headerSize + entry * 4)
            if raw != 0xFFFF_FFFF { entryOffset = Int(raw) }
        }
        guard let entryOffset else { return nil }
        let e = chunk + entriesStart + entryOffset
        guard e + 16 <= b.count, u16(b, e + 2) & 0x0001 == 0 else { return nil } // skip complex entries
        let valueStart = e + Int(u16(b, e))
        guard valueStart + 8 <= b.count else { return nil }
        return (b[valueStart + 3], u32(b, valueStart + 4))
    }
}
