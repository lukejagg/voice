import Foundation
import Darwin

struct VoiceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum Configuration {
    static let model = "gpt-transcribe"
    static func apiKey() throws -> String {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("secrets/openai.env")
        let contents = try String(contentsOf: url, encoding: .utf8)
        for line in contents.components(separatedBy: .newlines) {
            var value = line.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("export ") { value = String(value.dropFirst(7)) }
            guard value.hasPrefix("OPENAI_API_KEY=") else { continue }
            value = String(value.dropFirst("OPENAI_API_KEY=".count)).trimmingCharacters(in: .whitespaces)
            if let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            guard value.hasPrefix("sk-"), value.count > 20 else { break }
            return value
        }
        throw VoiceError(message: "Missing OPENAI_API_KEY in ~/secrets/openai.env.")
    }
}

struct Recording: Codable, Identifiable {
    let id: String
    let createdAt: Date
    var duration: TimeInterval
    var text: String?
    var error: String?
    let model: String
}

final class HistoryStore {
    let root: URL
    let limit: Int
    private let fm = FileManager.default
    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projects/Voice/History"), limit: Int = 100) throws {
        self.root = root; self.limit = limit
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }
    func folder(_ entry: Recording) -> URL { root.appendingPathComponent(entry.id) }
    func audio(_ entry: Recording) -> URL { folder(entry).appendingPathComponent("audio.m4a") }
    func create(protecting: Set<String> = []) throws -> Recording {
        let entry = Recording(id: UUID().uuidString, createdAt: Date(), duration: 0, text: nil, error: "Recording was interrupted before transcription completed.", model: Configuration.model)
        try fm.createDirectory(at: folder(entry), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try save(entry)
        try prune(protecting: protecting)
        return entry
    }
    func save(_ entry: Recording) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .millisecondsSince1970
        let metadata = folder(entry).appendingPathComponent("recording.json")
        try encoder.encode(entry).write(to: metadata, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadata.path)
        if let text = entry.text {
            let transcript = folder(entry).appendingPathComponent("transcript.txt")
            try text.write(to: transcript, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: transcript.path)
        }
        if fm.fileExists(atPath: audio(entry).path) { try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: audio(entry).path) }
    }
    func entries() throws -> [Recording] {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        return try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .compactMap { try? decoder.decode(Recording.self, from: Data(contentsOf: $0.appendingPathComponent("recording.json"))) }
            .sorted { $0.createdAt == $1.createdAt ? $0.id > $1.id : $0.createdAt > $1.createdAt }
    }
    func prune(protecting: Set<String> = []) throws {
        for entry in try entries().dropFirst(limit) where !protecting.contains(entry.id) { try fm.removeItem(at: folder(entry)) }
    }
}

struct TranscriptionClient {
    let session: URLSession
    let keyProvider: () throws -> String
    init(session: URLSession = .shared, keyProvider: @escaping () throws -> String = Configuration.apiKey) { self.session = session; self.keyProvider = keyProvider }
    func transcribe(_ audio: URL) async throws -> String {
        let key = try keyProvider()
        let bytes = try Data(contentsOf: audio)
        guard !bytes.isEmpty, bytes.count <= 25_000_000 else {
            throw VoiceError(message: "Recording must be nonempty and under 25 MB. Audio is saved in history.")
        }
        let boundary = "Voice-" + UUID().uuidString
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(Configuration.model)\r\n")
        let ext = audio.pathExtension.lowercased()
        let mime = ext == "wav" ? "audio/wav" : "audio/mp4"
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.\(ext)\"\r\nContent-Type: \(mime)\r\n\r\n")
        body.append(bytes); append("\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"; request.timeoutInterval = 180
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: request, from: body)
        guard let response = response as? HTTPURLResponse else { throw VoiceError(message: "Invalid API response.") }
        guard (200..<300).contains(response.statusCode) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = (json?["error"] as? [String: Any])?["message"] as? String ?? "Request failed."
            throw VoiceError(message: "OpenAI \(response.statusCode): \(message.replacingOccurrences(of: key, with: "[redacted]"))")
        }
        struct Result: Decodable { let text: String }
        let text = try JSONDecoder().decode(Result.self, from: data).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw VoiceError(message: "No speech detected. Recording saved in history.") }
        return text
    }
}

// Pure gesture logic: bare right Option taps only; never Option+key shortcuts.
struct OptionGesture {
    enum Action { case single, double }
    var downAt: TimeInterval?
    var chord = false
    var pendingAt: TimeInterval?
    let interval: TimeInterval = 0.30
    mutating func down(at time: TimeInterval, otherModifiers: Bool) { downAt = time; chord = otherModifiers }
    mutating func cancelChord() { if downAt != nil { chord = true } }
    mutating func up(at time: TimeInterval, allowDouble: Bool = true) -> Action? {
        defer { downAt = nil; chord = false }
        guard downAt != nil, !chord else { return nil }
        if let pendingAt, allowDouble, time - pendingAt <= interval { self.pendingAt = nil; return .double }
        pendingAt = time; return .single
    }
    mutating func flush(at time: TimeInterval) -> Action? {
        guard let pendingAt, time - pendingAt >= interval else { return nil }
        self.pendingAt = nil; return nil
    }
}

// An OS file lock is atomic across concurrent launches and releases on exit/crash.
final class InstanceLock {
    private let descriptor: Int32
    init(url: URL) throws {
        let fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw VoiceError(message: "Cannot open Voice instance lock: \(String(cString: strerror(errno)))") }
        descriptor = fd
    }
    func acquire() -> Bool { flock(descriptor, LOCK_EX | LOCK_NB) == 0 }
    deinit { Darwin.close(descriptor) }
}
