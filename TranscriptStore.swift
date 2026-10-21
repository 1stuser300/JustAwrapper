import Foundation
import Combine

final class TranscriptStore: ObservableObject {
    static let shared = TranscriptStore()

    @Published var latest: String = ""
    @Published var lastSaved: String = "-"
    @Published var lastError: String = ""
    @Published var saveCount: Int = 0
    @Published var captureEnabled: Bool = true

    private let fm = FileManager.default

    private var dir: URL {
        fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LumoTranscripts", isDirectory: true)
    }

    var transcriptFile: URL { dir.appendingPathComponent("transcript.txt") }
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
        guard captureEnabled else { return }

        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text != latest else { return }

        latest = text
        _ = ensureDir()

        do {
            try text.write(to: transcriptFile, atomically: true, encoding: .utf8)
            saveCount += 1
            lastSaved = ISO8601DateFormatter().string(from: Date())
            lastError = ""
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadLatest() {
        latest = (try? String(contentsOf: transcriptFile, encoding: .utf8)) ?? ""
    }

    /// Deletes the stored transcript and pauses capture so it doesn't reappear.
    func clear() {
        do {
            if fm.fileExists(atPath: transcriptFile.path) {
                try fm.removeItem(at: transcriptFile)
            }
            latest = ""
            lastSaved = "-"
            saveCount = 0
            lastError = ""
            captureEnabled = false
        } catch {
            lastError = "delete failed: \(error.localizedDescription)"
        }
    }
}