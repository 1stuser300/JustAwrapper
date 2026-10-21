import Foundation
import Combine
import UIKit

struct Session: Codable, Identifiable {
    let id: String
    var title: String
    let createdAt: Date
    var lastActive: Date

    static func makeNew(title: String = "") -> Session {
        Session(id: UUID().uuidString,
                title: title.isEmpty ? "New Chat" : title,
                createdAt: Date(),
                lastActive: Date())
    }
}

final class TranscriptStore: ObservableObject {
    static let shared = TranscriptStore()

    @Published var latest: String = ""
    @Published var lastSaved: String = "-"
    @Published var lastError: String = ""
    @Published var saveCount: Int = 0
    @Published var captureEnabled: Bool = true
    @Published var privacyMode: Bool = false
    @Published var fakeLockTapCount: Int = 0
    @Published var unlockRequired: Bool = false

    @Published var sessions: [Session] = []
    @Published var activeSessionId: String?

    private let fm = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let indexFile = "sessions.json"
    private let maxBackgroundTime = 30

    private var dir: URL {
        fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LumoTranscripts", isDirectory: true)
    }

    private var indexURL: URL {
        dir.appendingPathComponent(indexFile)
    }

    private func transcriptFileFor(id: String) -> URL {
        dir.appendingPathComponent(id + ".txt")
    }

    private func mainTranscriptFile() -> URL {
        dir.appendingPathComponent("transcript.txt")
    }

    /// The file backing whichever tab is currently on screen.
    private func activeFile() -> URL {
        if let id = activeSessionId {
            return transcriptFileFor(id: id)
        }
        return mainTranscriptFile()
    }

    var storagePath: String { dir.path }

    var activeTabLabel: String {
        if let id = activeSessionId,
           let s = sessions.first(where: { $0.id == id }) {
            return s.title
        }
        return "Main Chat"
    }

    init() {
        _ = ensureDir()
        loadSessions()
        loadLatest()
    }

    @discardableResult
    private func ensureDir() -> Bool {
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return true
        } catch {
            lastError = "mkdir failed: " + error.localizedDescription
            return false
        }
    }

    private func excludeFromBackup(_ url: URL) {
        do {
            var mutableURL = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try mutableURL.setResourceValues(values)
        } catch {
            lastError = "backup exclusion failed: " + error.localizedDescription
        }
    }

    private func saveIndex() {
        do {
            let data = try encoder.encode(sessions)
            try data.write(to: indexURL)
        } catch {
            lastError = "index save failed: " + error.localizedDescription
        }
    }

    func loadSessions() {
        if fm.fileExists(atPath: indexURL.path),
           let data = try? Data(contentsOf: indexURL),
           let loaded = try? decoder.decode([Session].self, from: data) {
            sessions = loaded.sorted { $0.lastActive > $1.lastActive }
        } else {
            sessions = []
        }
    }

    // MARK: - Capture

    func save(_ raw: String) {
        guard captureEnabled else { return }

        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text != latest else { return }

        latest = text
        _ = ensureDir()

        let url = activeFile()
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            excludeFromBackup(url)

            saveCount += 1
            lastSaved = ISO8601DateFormatter().string(from: Date())
            lastError = ""

            if let id = activeSessionId,
               let idx = sessions.firstIndex(where: { $0.id == id }) {
                sessions[idx].lastActive = Date()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadLatest() {
        let url = activeFile()
        latest = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // MARK: - Tabs

    func selectMainChat() {
        activeSessionId = nil
        loadLatest()
        captureEnabled = false
    }

    func loadSession(_ session: Session) {
        activeSessionId = session.id
        let url = transcriptFileFor(id: session.id)
        latest = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        lastSaved = ISO8601DateFormatter().string(from: session.lastActive)
        captureEnabled = false
    }

    /// Parks the current chat as its own tab, then leaves a fresh main chat behind.
    func turnIntoTab(title: String = "") {
        let session = Session.makeNew(title: title)

        do {
            let sessionURL = transcriptFileFor(id: session.id)
            try latest.write(to: sessionURL, atomically: true, encoding: .utf8)
            excludeFromBackup(sessionURL)

            sessions.insert(session, at: 0)
            saveIndex()

            activeSessionId = nil
            let mainURL = mainTranscriptFile()
            try? "".write(to: mainURL, atomically: true, encoding: .utf8)

            latest = ""
            saveCount = 0
            lastSaved = "-"
            captureEnabled = false
        } catch {
            lastError = "session create failed: " + error.localizedDescription
        }
    }

    func updateSessionTitle(id: String, newTitle: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].title = newTitle
        sessions[idx].lastActive = Date()
        sessions.moveObject(at: idx, to: 0)
        saveIndex()
    }

    func deleteSession(id: String) {
        let url = transcriptFileFor(id: id)
        do {
            if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
            sessions.removeAll { $0.id == id }
            saveIndex()

            if activeSessionId == id {
                activeSessionId = nil
                latest = ""
                captureEnabled = false
            }
        } catch {
            lastError = "session delete failed: " + error.localizedDescription
        }
    }

    func clear() {
        let url = activeFile()
        do {
            if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
            latest = ""
            lastSaved = "-"
            saveCount = 0
            lastError = ""
            captureEnabled = false
        } catch {
            lastError = "delete failed: " + error.localizedDescription
        }
    }

    // MARK: - Fake lock

    func startUnlock() {
        unlockRequired = true
        fakeLockTapCount = Int.random(in: 2...3)
    }

    func tapOnLock() -> Bool {
        fakeLockTapCount -= 1
        if fakeLockTapCount <= 0 {
            unlockRequired = false
            return true
        }
        return false
    }

    // MARK: - Background time

    func requestBackgroundTime() -> UIBackgroundTaskIdentifier {
        var identifier: UIBackgroundTaskIdentifier = .invalid
        identifier = UIApplication.shared.beginBackgroundTask(withName: "LumoExtendedTime") {
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(maxBackgroundTime)) {
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
        return identifier
    }
}

extension Array {
    mutating func moveObject(at fromIndex: Int, to toIndex: Int) {
        guard fromIndex != toIndex,
              fromIndex >= 0, fromIndex < count,
              toIndex >= 0, toIndex < count else { return }
        let obj = self.remove(at: fromIndex)
        insert(obj, at: toIndex)
    }
}