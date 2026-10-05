import AppKit
import SwiftUI
import Foundation

struct RepositoryBanner: View {
    @ObservedObject var controller: VoiceController
    var body: some View {
        HStack(spacing: 70) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Voice").font(.system(size: 86, weight: .semibold)).tracking(-5)
                Text("Speak. Tap. Keep going.").font(.system(size: 24, weight: .regular)).foregroundStyle(.secondary)
                Text("A quieter way to type.").font(.system(size: 14)).foregroundStyle(.tertiary).padding(.top, 22)
            }
            Spacer(minLength: 0)
            RecordingHUD(controller: controller)
                .scaleEffect(1.25)
                .shadow(color: Color.black.opacity(0.08), radius: 24, y: 12)
                .frame(width: 310)
        }.padding(.horizontal, 96).frame(width: 1120, height: 420)
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
    work.append {
        let host = NSHostingView(rootView: RepositoryBanner(controller: controller))
        host.frame = NSRect(x: 0, y: 0, width: 1120, height: 420)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        capture(host, name: "banner-" + suffix)
        window.close()
    }
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
