import Foundation

enum AndroidToolsError: LocalizedError {
    case adbMissing
    case downloadBroken(String)

    var errorDescription: String? {
        switch self {
        case .adbMissing:
            return "Android Platform Tools (adb) aren't installed. Download them from the Android tab."
        case .downloadBroken(let detail):
            return "The Platform Tools download didn't work: \(detail)"
        }
    }
}

/// Finds or downloads Google's adb and runs it.
enum AndroidTools {
    /// Where IPA Courier keeps its own copy of Platform Tools.
    static var ownFolder: URL { AppPaths.support.appendingPathComponent("platform-tools", isDirectory: true) }

    static let downloadURL = URL(string: "https://dl.google.com/android/repository/platform-tools-latest-darwin.zip")!
    static let termsURL = URL(string: "https://developer.android.com/studio/releases/platform-tools")!
    static let approximateDownloadSize: Int64 = 16_000_000

    /// An existing adb: IPA Courier's own, the Android SDK's, or Homebrew's.
    static func findADB() -> URL? {
        let env = ProcessInfo.processInfo.environment
        var candidates = [ownFolder.appendingPathComponent("adb")]
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let root = env[key] { candidates.append(URL(fileURLWithPath: root).appendingPathComponent("platform-tools/adb")) }
        }
        candidates += [
            AppPaths.home.appendingPathComponent("Library/Android/sdk/platform-tools/adb"),
            URL(fileURLWithPath: "/opt/homebrew/bin/adb"),
            URL(fileURLWithPath: "/usr/local/bin/adb"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Downloads Google's Platform Tools into IPA Courier's folder and returns adb.
    static func downloadPlatformTools(progress: @escaping @Sendable (Double, String) -> Void) async throws -> URL {
        let work = GameInstaller.workFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let asset = ReleaseAsset(name: "platform-tools-latest-darwin.zip", size: approximateDownloadSize,
                                 downloadURL: downloadURL)
        let zip = try await GameInstaller.download(asset, into: work, progress: progress)
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        try await GameInstaller.extract(zip, into: unpacked)
        let tools = unpacked.appendingPathComponent("platform-tools", isDirectory: true)
        guard FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent("adb").path) else {
            throw AndroidToolsError.downloadBroken("the archive has no platform-tools/adb.")
        }
        try? FileManager.default.removeItem(at: ownFolder)
        try FileManager.default.moveItem(at: tools, to: ownFolder)
        let adb = ownFolder.appendingPathComponent("adb")
        let version = try await Shell.run(adb.path, ["version"])
        guard version.text.contains("Android Debug Bridge") else {
            throw AndroidToolsError.downloadBroken(version.text)
        }
        return adb
    }

    static func version(_ adb: URL) async -> String? {
        guard let result = try? await Shell.run(adb.path, ["version"], checkStatus: false) else { return nil }
        let first = result.text.split(whereSeparator: \.isNewline).first.map(String.init)
        return first?.replacingOccurrences(of: "Android Debug Bridge version ", with: "")
    }
}
