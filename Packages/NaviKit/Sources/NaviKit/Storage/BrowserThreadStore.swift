import Foundation

// MARK: - BrowserThreadStore

actor BrowserThreadStore {
    // MARK: Lifecycle

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // MARK: Internal

    static let shared = BrowserThreadStore()

    func load(threadKey: String) -> [String: JSONValue]? {
        do {
            let data = try Data(contentsOf: fileURL(for: threadKey))
            return try JSONDecoder().decode([String: JSONValue].self, from: data)
        } catch {
            return nil
        }
    }

    func save(threadKey: String, snapshot: [String: JSONValue]) {
        do {
            let directoryURL = storageDirectoryURL
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            let data = try JSONEncoder().encode(snapshot)
            let destinationURL = fileURL(for: threadKey)
            let temporaryURL = directoryURL.appendingPathComponent(UUID().uuidString, isDirectory: false)

            try data.write(to: temporaryURL, options: .atomic)

            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            }
        } catch {
            return
        }
    }

    func clear(threadKey: String) {
        let url = fileURL(for: threadKey)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.removeItem(at: url)
    }

    // MARK: Private

    private let fileManager: FileManager

    private var storageDirectoryURL: URL {
        let containerURL = (try? fileManager.containerURL(forSecurityApplicationGroupIdentifier: NaviSharedStorage.appGroupID))
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return containerURL
            .appendingPathComponent("BrowserAgent", isDirectory: true)
            .appendingPathComponent("Threads", isDirectory: true)
    }

    private func fileURL(for threadKey: String) -> URL {
        storageDirectoryURL
            .appendingPathComponent(safeFilename(for: threadKey), isDirectory: false)
            .appendingPathExtension("json")
    }

    private func safeFilename(for threadKey: String) -> String {
        let encoded = Data(threadKey.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return encoded.isEmpty ? "thread" : encoded
    }
}
