import Foundation

func check(_ condition: Bool, _ message: String) {
    guard condition else { fatalError(message) }
}
var gesture = OptionGesture()
gesture.down(at: 0, otherModifiers: false)
check(gesture.up(at: 0.1) == .single, "Single tap starts immediately")
check(gesture.flush(at: 0.2) == nil, "No premature single")
check(gesture.flush(at: 0.42) == nil && gesture.pendingAt == nil, "Double-tap window expires without a second toggle")
check(gesture.flush(at: 0.8) == nil, "No duplicate single")
gesture.down(at: 1, otherModifiers: false); _ = gesture.up(at: 1.05)
gesture.down(at: 1.15, otherModifiers: false)
check(gesture.up(at: 1.2) == .double, "Double tap opens history")
check(gesture.flush(at: 2) == nil, "Double tap never toggles recording")
gesture.down(at: 3, otherModifiers: false); gesture.cancelChord()
check(gesture.up(at: 3.1) == nil && gesture.pendingAt == nil, "Option+key ignored")
gesture.down(at: 4, otherModifiers: true)
check(gesture.up(at: 4.1) == nil && gesture.pendingAt == nil, "Other modifier chords ignored")
gesture.down(at: 5, otherModifiers: false)
check(gesture.up(at: 6) == .single && gesture.pendingAt != nil, "Bare Option hold stops immediately on release")
check(gesture.flush(at: 6.31) == nil, "Long hold never toggles twice")
gesture.down(at: 7, otherModifiers: false); _ = gesture.up(at: 7.05)
gesture.down(at: 7.10, otherModifiers: false)
check(gesture.up(at: 7.15, allowDouble: false) == .single, "Rapid finish/start must not open history")
let root = FileManager.default.temporaryDirectory.appendingPathComponent("voice-test-" + UUID().uuidString)
defer { try? FileManager.default.removeItem(at: root) }
let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent("voice-lock-test-" + UUID().uuidString)
var firstLock: InstanceLock? = try InstanceLock(url: lockURL)
check(firstLock!.acquire(), "First instance acquires lock")
let secondLock = try InstanceLock(url: lockURL)
check(!secondLock.acquire(), "Second instance blocked")
firstLock = nil
check(secondLock.acquire(), "Lock releases when instance exits")
try FileManager.default.removeItem(at: lockURL)
let store = try HistoryStore(root: root)
for i in 0..<105 {
    var entry = try store.create()
    entry = Recording(id: entry.id, createdAt: Date(timeIntervalSince1970: Double(i)), duration: 1, text: "Transcript \(i)", error: nil, model: Configuration.model)
    try Data([1, 2, 3]).write(to: store.audio(entry))
    try store.save(entry)
    try store.prune()
}
let entries = try store.entries()
check(entries.count == 100, "Retains exactly 100")
check(entries.first?.text == "Transcript 104", "Newest first")
check(entries.last?.text == "Transcript 5", "Oldest five pruned")
check(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 100, "Prunes recording folders and audio")
check(try String(contentsOf: store.folder(entries[0]).appendingPathComponent("transcript.txt"), encoding: .utf8) == "Transcript 104", "Plain text persisted")
check((try FileManager.default.attributesOfItem(atPath: store.audio(entries[0]).path)[.posixPermissions] as? Int) == 0o600, "Audio owner-only")
print("Passed gesture, retention, transcript persistence, and file permissions tests")

final class MockAPI: URLProtocol {
    static var status = 200
    static var payload = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        check(request.url?.path == "/v1/audio/transcriptions", "Transcription endpoint")
        check(request.httpMethod == "POST", "POST request")
        check(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-placeholder-for-tests", "Authentication header")
        check(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=Voice-") == true, "Multipart boundary")
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
let configuration = URLSessionConfiguration.ephemeral
configuration.protocolClasses = [MockAPI.self]
let client = TranscriptionClient(session: URLSession(configuration: configuration), keyProvider: { "sk-test-placeholder-for-tests" })
let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("voice-api-test-" + UUID().uuidString + ".m4a")
try Data([1, 2, 3]).write(to: fixture)
Task {
    do {
        MockAPI.payload = Data(#"{"text":"  Hello world. "}"#.utf8)
        let text = try await client.transcribe(fixture)
        check(text == "Hello world.", "JSON transcription decoded and trimmed")
        MockAPI.payload = Data(#"{"text":" "}"#.utf8)
        do { _ = try await client.transcribe(fixture); fatalError("Empty speech should fail") }
        catch { check(error.localizedDescription.contains("No speech"), "Empty speech error") }
        MockAPI.status = 401
        MockAPI.payload = Data(#"{"error":{"message":"Invalid key sk-test-placeholder-for-tests"}}"#.utf8)
        do { _ = try await client.transcribe(fixture); fatalError("HTTP errors should fail") }
        catch {
            check(error.localizedDescription.contains("401"), "HTTP status surfaced")
            check(!error.localizedDescription.contains("sk-test-placeholder"), "Secret redacted from API errors")
        }
        print("Passed API request, successful response, empty speech, and HTTP error tests")
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: fixture)
        exit(0)
    } catch { fatalError("API test failed: \(error)") }
}
dispatchMain()
