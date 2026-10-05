import AppKit
import SwiftUI
import Foundation

struct RecordingSequence: View {
    @ObservedObject var controller: VoiceController
    let opacity: Double
    var spinnerPhase: Int = 0
    var body: some View {
        RecordingHUD(controller: controller, previewSpinnerPhase: spinnerPhase)
            .shadow(color: Color.black.opacity(0.07), radius: 16, y: 8)
            .opacity(opacity)
            .scaleEffect(1.25)
            .frame(width: 480, height: 160)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

try MainActor.assumeIsolated {
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let previousApp = NSWorkspace.shared.frontmostApplication
let root = FileManager.default.temporaryDirectory.appendingPathComponent("voice-visual-" + UUID().uuidString)
let controller = VoiceController(store: try HistoryStore(root: root))
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
controller.start(preview: true)
if CommandLine.arguments.contains("--motion") {
    application.appearance = NSAppearance(named: .aqua)
    controller.recording = true
    controller.showHUD("Listening")
    controller.panel.orderOut(nil)
    let frameDirectory = output.appendingPathComponent("motion", isDirectory: true)
    try FileManager.default.createDirectory(at: frameDirectory, withIntermediateDirectories: true)
    let host = NSHostingView(rootView: RecordingSequence(controller: controller, opacity: 0.35))
    host.frame = NSRect(x: 0, y: 0, width: 480, height: 160)
    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    var frame = 0
    @MainActor func renderFrame() {
        guard frame < 96 else {
            window.close()
            try? FileManager.default.removeItem(at: root)
            print("Captured 96 sample-data recording-sequence frames")
            exit(0)
        }
        let seconds = Double(frame) / 12
        let processing = seconds >= 4
        if processing && controller.state != "Transcribing" {
            controller.recording = false
            controller.busy = true
            controller.state = "Transcribing"
        }
        // Show the two existing panel designs, not the application's hidden
        // background-work lifecycle. Keep transitions short and the panel visible.
        let resizeProgress = min(max((seconds - 4) / 0.2, 0), 1)
        controller.hudSize = CGSize(width: 240 - 24 * resizeProgress, height: 64)
        let opacity = seconds < 0.2 ? 0.35 + 0.65 * seconds / 0.2 :
            (seconds > 7.7 ? max(0.35, 1 - (seconds - 7.7) / 0.3) : 1)
        controller.elapsed = min(seconds, 4)
        controller.level = Float(0.04 + abs(sin(seconds * 5.2)) * 0.15)
        host.rootView = RecordingSequence(controller: controller, opacity: opacity, spinnerPhase: frame % 12)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: frameDirectory.appendingPathComponent(String(format: "%03d.png", frame)))
        frame += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 12) { renderFrame() }
    }
    DispatchQueue.main.async { renderFrame() }
    application.run()
    exit(0)
}
controller.entries = [
    Recording(id: "preview-1", createdAt: Date(timeIntervalSince1970: 1791155400), duration: 18, text: "Let's keep this simple. A quiet place for your thoughts, ready whenever you need them.", error: nil, model: Configuration.model),
    Recording(id: "preview-2", createdAt: Date(timeIntervalSince1970: 1791151800), duration: 32, text: "Move the review to Thursday afternoon and send the updated notes before lunch.", error: nil, model: Configuration.model),
    Recording(id: "preview-3", createdAt: Date(timeIntervalSince1970: 1791065400), duration: 9, text: "The little details make the whole thing feel better.", error: nil, model: Configuration.model)
]
func capture(_ view: NSView, name: String) {
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("No bitmap") }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try! bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
    print("Captured \(name): \(Int(view.bounds.width))×\(Int(view.bounds.height))")
}
var work: [@MainActor () -> Void] = []
for appearance in [NSAppearance.Name.aqua, .darkAqua] {
    let suffix = appearance == .aqua ? "light" : "dark"
    work.append {
        application.appearance = NSAppearance(named: appearance)
        controller.elapsed = 14; controller.level = 0.13; controller.recording = true
        controller.showHUD("Listening")
    }
    work.append { capture(controller.panel.contentView!, name: "recording-" + suffix) }
    work.append { controller.recording = false; controller.busy = true; controller.showHUD("Transcribing") }
    work.append {
        capture(controller.panel.contentView!, name: "transcribing-" + suffix)
        controller.busy = false
        controller.showHistory()
        // Use preview data instead of disk history; showHistory refreshes from disk.
        controller.entries = [
            Recording(id: "preview-1", createdAt: Date(timeIntervalSince1970: 1791155400), duration: 18, text: "Let's keep this simple. A quiet place for your thoughts, ready whenever you need them.", error: nil, model: Configuration.model),
            Recording(id: "preview-2", createdAt: Date(timeIntervalSince1970: 1791151800), duration: 32, text: "Move the review to Thursday afternoon and send the updated notes before lunch.", error: nil, model: Configuration.model),
            Recording(id: "preview-3", createdAt: Date(timeIntervalSince1970: 1791065400), duration: 9, text: "The little details make the whole thing feel better.", error: nil, model: Configuration.model)
        ]
    }
    work.append { capture(controller.historyWindow!.contentView!, name: "history-" + suffix); controller.historyWindow?.orderOut(nil); controller.showSetup() }
    work.append { capture(controller.setupWindow!.contentView!, name: "permissions-" + suffix); controller.setupWindow?.orderOut(nil); controller.hideHUD() }
    work.append { precondition(!controller.panel.isVisible, "Completion must hide HUD") }
}
work.append {
    controller.showHUD("Listening")
    controller.hideHUD()
    controller.showHUD("Transcribing")
}
work.append {
    precondition(controller.panel.isVisible, "Old fade must not hide a new session")
    precondition(controller.panel.alphaValue > 0.99, "New session must fade in fully")
    controller.hideHUD()
}
work.append { precondition(!controller.panel.isVisible, "Final fade must hide panel") }
@MainActor func step() {
    guard !work.isEmpty else {
        try? FileManager.default.removeItem(at: root)
        previousApp?.activate(options: [])
        print("Verified both appearances, HUD resize, and completion fade-out")
        exit(0)
    }
    work.removeFirst()()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { step() }
}
DispatchQueue.main.async { step() }
application.run()

}
