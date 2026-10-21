import Foundation
import Combine

final class TranscriptStore: ObservableObject {
    static let shared = TranscriptStore()

    @Published var latest: String = ""
    @Published var lastSaved: String = "-"
    @Published var lastError: String = ""
    @Published var saveCount: Int = 0

    private let fm = FileManager.default

    private var dir: URL {
        fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LumoTranscripts", isDirectory: true)
    }

    var latestFile: URL { dir.appendingPathComponent("latest.txt") }
    var historyFile: URL { dir.appendingPathComponent("history.txt") }
    var storagePath: String { dir.path }

    init() {
        _ = ensureDir()
        loadLatest()
    }

    @discardableResult
    private func ensureDir() -> Bool {
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return true
        } catch {
            lastError = "mkdir failed: \(error.localizedDescription)"
            return false
        }
    }

    func save(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text != latest else { return }

        latest = text
        _ = ensureDir()

        do {
            try text.write(to: latestFile, atomically: true, encoding: .utf8)

            let stamp = ISO8601DateFormatter().string(from: Date())
            let entry = "\n===== \(stamp) =====\n\(text)\n"

            if fm.fileExists(atPath: historyFile.path),
               let handle = try? FileHandle(forWritingTo: historyFile) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                if let data = entry.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
            } else {
                try entry.write(to: historyFile, atomically: true, encoding: .utf8)
            }

            saveCount += 1
            lastSaved = stamp
            lastError = ""
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadLatest() {
        latest = (try? String(contentsOf: latestFile, encoding: .utf8)) ?? ""
    }

    func loadHistory() -> String {
        (try? String(contentsOf: historyFile, encoding: .utf8)) ?? "(no history yet)"
    }

    func clearEverything() {
        try? fm.removeItem(at: latestFile)
        try? fm.removeItem(at: historyFile)
        latest = ""
        lastSaved = "-"
        saveCount = 0
        lastError = ""
    }
}