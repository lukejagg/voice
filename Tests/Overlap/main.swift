import AppKit
import Foundation

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
func check(_ condition: Bool, _ message: String) { precondition(condition, message) }
Task { @MainActor in
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("voice-overlap-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try HistoryStore(root: root, limit: 2)
    let first = try store.create()
    let second = try store.create(protecting: [first.id])
    let third = try store.create(protecting: [first.id, second.id])
    check(try store.entries().count == 3, "Pending audio survives retention pruning")
    var uploaded: [String] = []
    var pasted: [String] = []
    var activeUploads = 0
    var maxUploads = 0
    let controller = VoiceController(store: store, transcribeAudio: { audio in
        let id = audio.deletingLastPathComponent().lastPathComponent
        uploaded.append(id); activeUploads += 1; maxUploads = max(maxUploads, activeUploads)
        defer { activeUploads -= 1 }
        try await Task.sleep(nanoseconds: 120_000_000)
        if id == second.id { throw VoiceError(message: "Simulated failure") }
        return id
    }, deliverTranscript: { text, paste in
        check(paste, "Auto-paste retained")
        // Model a delayed clipboard consumer; next result must not overtake it.
        try? await Task.sleep(nanoseconds: 100_000_000)
        pasted.append(text)
    })
    controller.start(preview: true)
    check(controller.panel.ignoresMouseEvents, "Hidden panel must pass clicks through")
    controller.showHUD("Listening")
    check(!controller.panel.ignoresMouseEvents, "Visible panel allows its quit control")
    controller.hideHUD()
    check(controller.panel.ignoresMouseEvents, "Fade-out immediately stops intercepting underlying clicks")
    controller.showHUD("Listening")
    check(!controller.panel.ignoresMouseEvents, "Restarting during fade restores panel interaction")
    try await Task.sleep(nanoseconds: 250_000_000)
    check(controller.panel.isVisible && !controller.panel.ignoresMouseEvents, "Old fade cannot disable a new panel")
    controller.transcribe(first, paste: true)
    controller.transcribe(second, paste: true)
    controller.transcribe(third, paste: true)
    controller.transcribe(first, paste: true) // Duplicate retry should not duplicate paste.
    check(controller.pendingIDs.count == 3, "Three jobs queued without a recording gate")
    controller.recording = true
    controller.showHUD("Listening")
    for _ in 0..<100 {
        if !controller.busy { break }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    check(!controller.busy, "All work drained")
    check(uploaded == [first.id, second.id, third.id], "Recording order preserved through failure")
    check(pasted == [first.id, third.id], "Every successful result delivered once, in order")
    check(maxUploads == 1, "Serial delivery prevents clipboard races")
    check(controller.recording && controller.state == "Listening" && controller.panel.isVisible, "Old success/failure never hides or replaces new recording")
    check(controller.pendingIDs.isEmpty, "Pending IDs cleared")
    check(try store.entries().count == 2, "Retention returns to limit after work drains")
    controller.recording = false; controller.hideHUD()

    let active = try store.create()
    let waiting = try store.create(protecting: [active.id])
    var latePastes = 0
    var cancelUploads = 0
    let cancelling = VoiceController(store: store, transcribeAudio: { _ in
        cancelUploads += 1
        // Even a transport that ignores cancellation must not be allowed to paste late.
        try? await Task.sleep(nanoseconds: 150_000_000)
        return "late response"
    }, deliverTranscript: { _, _ in latePastes += 1 })
    cancelling.start(preview: true)
    cancelling.transcribe(active, paste: true); cancelling.transcribe(waiting, paste: true)
    try await Task.sleep(nanoseconds: 20_000_000)
    cancelling.shutdown()
    try await Task.sleep(nanoseconds: 100_000_000)
    check(latePastes == 0 && cancelUploads == 1, "Quit cancels active and waiting jobs without late paste")
    let saved = try store.entries()
    check(saved.filter { $0.error?.contains("cancelled") == true }.count == 2, "Cancelled jobs stay retryable")
    print("Passed overlapping recording, ordered paste, failure continuation, deduplication, protected retention, HUD isolation, and quit cancellation tests")
    exit(0)
}
app.run()
