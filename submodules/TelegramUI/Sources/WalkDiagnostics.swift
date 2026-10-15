import Foundation

/// A single bounded log shared by both agent chats and retained across launches.
/// Callers supply state only: never audio, message text, credentials or device names.
enum WalkDiagnostics {
    private static let store = WalkDiagnosticStore(directory: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("WalkDiagnostics", isDirectory: true))

    static func log(_ text: String) { store.append(text) }

    static func exportURLs() -> [URL] {
        do { return [try store.export()] }
        catch {
            NSLog("Walk diagnostics export failed: %@", String(describing: type(of: error)))
            return []
        }
    }
}

final class WalkDiagnosticStore {
    private let directory: URL
    private let maximumBytes: Int
    private let queue = DispatchQueue(label: "NanoVoice.Diagnostics")
    private let formatter = ISO8601DateFormatter()

    init(directory: URL, maximumBytes: Int = 512 * 1024) {
        self.directory = directory
        self.maximumBytes = max(1024, maximumBytes)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    private func url(_ index: Int) -> URL {
        directory.appendingPathComponent("events-\(index).txt")
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        #endif
        var value = directory
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try value.setResourceValues(resources)
    }

    func append(_ text: String) {
        queue.async {
            do {
                try self.prepareDirectory()
                // Bound a single event too, so malformed diagnostics cannot grow storage.
                let clean = String(decoding: text.utf8.prefix(min(4096, self.maximumBytes - 128)), as: UTF8.self).replacingOccurrences(of: "\n", with: " ")
                let data = Data("\(self.formatter.string(from: Date())) \(clean)\n".utf8)
                let size = (try? self.url(0).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size + data.count > self.maximumBytes {
                    for index in stride(from: 2, through: 1, by: -1) {
                        if FileManager.default.fileExists(atPath: self.url(index).path) {
                            try FileManager.default.removeItem(at: self.url(index))
                        }
                        if FileManager.default.fileExists(atPath: self.url(index - 1).path) {
                            try FileManager.default.moveItem(at: self.url(index - 1), to: self.url(index))
                        }
                    }
                }
                if !FileManager.default.fileExists(atPath: self.url(0).path) {
                    try Data().write(to: self.url(0), options: .atomic)
                }
                if #available(iOS 13.4, macOS 10.15.4, *) {
                    let handle = try FileHandle(forWritingTo: self.url(0))
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    var contents = try Data(contentsOf: self.url(0))
                    contents.append(data)
                    try contents.write(to: self.url(0), options: .atomic)
                }
            } catch {
                NSLog("Walk diagnostics write failed: %@", String(describing: type(of: error)))
            }
        }
    }

    /// Flush queued events, then create a stable snapshot for the share sheet.
    /// A fixed export filename bounds storage across repeated exports.
    func export() throws -> URL {
        return try queue.sync {
            try prepareDirectory()
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
            var data = Data("NanoVoice audio diagnostics; build=\(build); exported=\(formatter.string(from: Date()))\n".utf8)
            for index in stride(from: 2, through: 0, by: -1) {
                if FileManager.default.fileExists(atPath: url(index).path) {
                    data.append(try Data(contentsOf: url(index)))
                }
            }
            let result = directory.appendingPathComponent("NanoVoice-diagnostics.txt")
            try data.write(to: result, options: .atomic)
            return result
        }
    }
}
