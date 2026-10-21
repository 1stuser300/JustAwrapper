import Foundation
import Combine

struct Session: Codable, Identifiable {
    let id: String
    var title: String
    let createdAt: Date
    var lastActive: Date
    
    static func makeNew(title: String = "") -> Session {
        Session(id: UUID().uuidString, title: title.isEmpty ? "New Chat" : title, createdAt: Date(), lastActive: Date())
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
    
    @Published var sessions: [Session] = []
    @Published var selectedSessionId: String?
    
    private let fm = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let indexFile = "sessions.json"

    private var dir: URL {
        fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LumoTranscripts", isDirectory: true)
    }

    private var indexURL: URL {
        dir.appendingPathComponent(indexFile)
    }
    
    private func transcriptFileFor(id: String) -> URL {
        dir.appendingPathComponent("\(id).txt")
    }

    var storagePath: String { dir.path }
    
    private func transcriptFilePath() -> URL {
        dir.appendingPathComponent("transcript.txt")
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
            lastError = "mkdir failed: \(error.localizedDescription)"
            return false
        }
    }

    private func saveIndex() {
        do {
            let data = try encoder.encode(sessions)
            try data.write(to: indexURL)
        } catch {
            lastError = "index save failed: \(error.localizedDescription)"
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

    func save(_ raw: String) {
        guard captureEnabled else { return }

        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text != latest else { return }

        latest = text
        _ = ensureDir()

        do {
            var fileURL = transcriptFilePath()
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try fileURL.setResourceValues(resourceValues)
            
            saveCount += 1
            lastSaved = ISO8601DateFormatter().string(from: Date())
            lastError = ""
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadLatest() {
        let url = transcriptFilePath()
        latest = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // MARK: - Session Management

    func turnIntoTab(title: String = "", onComplete: @escaping () -> Void) {
        let session = Session.makeNew(title: title)
        
        do {
            var sessionFile = transcriptFileFor(id: session.id)
            try latest.write(to: sessionFile, atomically: true, encoding: .utf8)
            
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try sessionFile.setResourceValues(resourceValues)
            
            sessions.insert(session, at: 0)
            saveIndex()
            
            saveCount = 0
            lastSaved = ISO8601DateFormatter().string(from: Date())
            captureEnabled = false
            onComplete()
        } catch {
            lastError = "session create failed: \(error.localizedDescription)"
        }
    }

    func loadSession(_ session: Session) {
        let url = transcriptFileFor(id: session.id)
        if let content = try? String(contentsOf: url, encoding: .utf8) {
            latest = content
            lastSaved = ISO8601DateFormatter().string(from: session.lastActive)
            selectedSessionId = session.id
            captureEnabled = false
        }
    }

    func updateSessionTitle(id: String, newTitle: String) {
        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            sessions[idx].title = newTitle
            sessions[idx].lastActive = Date()
            sessions.moveObject(at: idx, to: 0)
            saveIndex()
        }
    }

    func deleteSession(id: String) {
        let url = transcriptFileFor(id: id)
        do {
            if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
            sessions.removeAll { $0.id == id }
            saveIndex()
            if selectedSessionId == id {
                selectedSessionId = nil
                latest = ""
            }
        } catch {
            lastError = "session delete failed: \(error.localizedDescription)"
        }
    }

    func resumeCapture() {
        captureEnabled = true
    }

    func clear() {
        let url = transcriptFilePath()
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
            lastError = "delete failed: \(error.localizedDescription)"
        }
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