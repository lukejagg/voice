import AppKit
import SwiftUI
import AVFoundation
import ApplicationServices
import Darwin
import QuartzCore

final class PassivePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class VoiceController: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var state = "Ready"
    @Published var detail = "Tap right Option to record"
    @Published var level: Float = 0
    @Published var elapsed: TimeInterval = 0
    @Published var entries: [Recording] = []
    @Published var microphone = false
    @Published var accessibility = false
    @Published var inputMonitoring = false
    @Published var hotkeyReady = false
    @Published var busy = false
    @Published var pendingIDs: Set<String> = []
    @Published var recording = false
    @Published var hudSize = CGSize(width: 240, height: 64)
    let store: HistoryStore
    let hotkey = Hotkey()
    let soundCues = SoundCues()
    var panel: PassivePanel!
    var historyWindow: NSWindow?
    var setupWindow: NSWindow?
    var recorder: AVAudioRecorder?
    var current: Recording?
    var meter: Timer?
    var hideWork: DispatchWorkItem?
    var permissionsTimer: Timer?
    var statusItem: NSStatusItem!
    let transcribeAudio: (URL) async throws -> String
    let deliverOverride: ((String, Bool) async -> Void)?
    var lastTapStartedRecording = true
    lazy var workQueue = OrderedWorkQueue<TranscriptionJob>(
        identifier: { $0.recording.id },
        process: { [weak self] in await self?.processTranscription($0) },
        discard: { [weak self] in self?.preserveCancelled($0.recording) },
        changed: { [weak self] ids in
            guard let self else { return }
            self.pendingIDs = ids; self.busy = !ids.isEmpty
            try? self.store.prune(protecting: ids.union(self.current.map { [$0.id] } ?? []))
            self.refreshHistory()
        })
    var quitting = false
    var speculativeStart: TimeInterval?
    var hudGeneration = 0
    var previewMode = false

    init(store: HistoryStore,
         transcribeAudio: @escaping (URL) async throws -> String = { try await TranscriptionClient().transcribe($0) },
         deliverTranscript: ((String, Bool) async -> Void)? = nil) {
        self.store = store; self.transcribeAudio = transcribeAudio
        self.deliverOverride = deliverTranscript; super.init()
    }
    func start(preview: Bool = false) {
        previewMode = preview
        refreshHistory()
        panel = PassivePanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 64), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false; panel.ignoresMouseEvents = false
        panel.contentView = NSHostingView(rootView: RecordingHUD(controller: self))
        if preview { return }
        hotkey.onSingle = { [weak self] in self?.toggle() }
        hotkey.onDouble = { [weak self] in self?.handleDoubleTap() }
        hotkey.allowsDoubleTap = { [weak self] in self?.lastTapStartedRecording ?? true }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Voice")
        let menu = NSMenu()
        for (title, action) in [("History", #selector(menuHistory)), ("Permissions", #selector(menuSetup)), ("Recordings", #selector(showFolder))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Voice", action: #selector(quitApp), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
        statusItem.menu = menu
        refreshPermissions()
        permissionsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.refreshPermissions() } }
        if !microphone || !accessibility || !hotkeyReady { showSetup() }
    }
    @objc func menuToggle() { toggle() }
    @objc func menuHistory() { showHistory() }
    @objc func menuSetup() { showSetup() }
    @objc func showFolder() { NSWorkspace.shared.open(store.root) }
    @objc func quitApp() {
        shutdown()
        NSApp.terminate(nil)
    }
    func shutdown() {
        quitting = true; workQueue.shutdown(); soundCues.stop()
        if recorder != nil { finishRecording(submit: false) }
        panel?.orderOut(nil)
    }
    func refreshPermissions() {
        microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibility = AXIsProcessTrusted()
        inputMonitoring = CGPreflightListenEventAccess()
        hotkeyReady = hotkey.start()
    }
    func requestMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .denied || AVCaptureDevice.authorizationStatus(for: .audio) == .restricted { openSettings("Privacy_Microphone"); return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in DispatchQueue.main.async { self?.refreshPermissions() } }
    }
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openSettings("Privacy_Accessibility")
    }
    func requestInputMonitoring() { _ = CGRequestListenEventAccess(); openSettings("Privacy_ListenEvent") }
    func openSettings(_ section: String) { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(section)")!) }
    func refreshHistory() {
        do { entries = try store.entries() } catch { detail = "Could not read history: \(error.localizedDescription)" }
    }
    func showHUD(_ state: String, _ detail: String = "", hideAfter: Double? = nil) {
        hideWork?.cancel(); hudGeneration += 1
        self.state = state; self.detail = detail
        let isRecording = state == "Listening"
        let isTranscribing = state == "Transcribing" || state == "Cancelling"
        let size = CGSize(width: isRecording ? 240 : (isTranscribing ? 216 : 290), height: 64)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { hudSize = size }
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        let target = NSRect(x: frame.midX - size.width / 2, y: frame.minY + 64, width: size.width, height: size.height)
        let visible = panel.isVisible
        if !visible {
            panel.setFrame(target, display: true); panel.alphaValue = reduceMotion ? 1 : 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
        if let delay = hideAfter {
            let work = DispatchWorkItem { [weak self] in self?.hideHUD() }; hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }
    func hideHUD() {
        hideWork?.cancel(); hudGeneration += 1
        let generation = hudGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.hudGeneration == generation else { return }
                self.panel.orderOut(nil)
                self.state = "Ready"
            }
        }
    }
    func handleDoubleTap() {
        // An immediate first tap may have just begun recording. Undo that tentative
        // start without sending audio or adding a history item when it becomes a double tap.
        if let started = speculativeStart, ProcessInfo.processInfo.systemUptime - started <= 0.4,
           let entry = current, let audio = recorder {
            soundCues.stop(); audio.stop(); recorder = nil; recording = false; current = nil
            meter?.invalidate(); meter = nil; level = 0
            try? FileManager.default.removeItem(at: store.folder(entry))
            statusItem?.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Voice")
            hideHUD(); refreshHistory()
        }
        speculativeStart = nil
        showHistory()
    }
    func toggle() {
        if recorder != nil { finishRecording(); return }
        guard microphone else { showSetup(); requestMicrophone(); return }
        do {
            _ = try Configuration.apiKey()
            // Close our active windows and return to the app that was in front before history/setup.
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                historyWindow?.orderOut(nil); setupWindow?.orderOut(nil); NSApp.hide(nil)
            }
            let entry = try store.create(protecting: pendingIDs)
            current = entry
            let audio = try AVAudioRecorder(url: store.audio(entry), settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue])
            audio.delegate = self; audio.isMeteringEnabled = true
            guard audio.prepareToRecord(), audio.record() else { throw VoiceError(message: "Microphone could not start recording.") }
            recorder = audio; recording = true; elapsed = 0; level = 0
            speculativeStart = ProcessInfo.processInfo.systemUptime
            lastTapStartedRecording = true
            try store.save(entry)
            if !previewMode { soundCues.recordingStarted() }
            showHUD("Listening")
            statusItem?.button?.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")
            meter = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let recorder = self.recorder else { return }
                    recorder.updateMeters(); self.level = pow(10, recorder.averagePower(forChannel: 0) / 20); self.elapsed = recorder.currentTime
                    if self.elapsed >= 20 * 60 { self.finishRecording() }
                }
            }
            if let meter { RunLoop.main.add(meter, forMode: .common) }
        } catch {
            soundCues.stop(); recorder?.stop(); recorder = nil; recording = false; meter?.invalidate(); meter = nil
            if var entry = current { entry.error = error.localizedDescription; try? store.save(entry) }; current = nil
            refreshHistory(); showHUD("Couldn’t record", "Check microphone access", hideAfter: 4)
        }
    }
    func finishRecording(submit: Bool = true) {
        guard let recorder, var entry = current else { return }
        soundCues.stop(); lastTapStartedRecording = false
        entry.duration = recorder.currentTime
        self.recorder = nil; recording = false; speculativeStart = nil; current = nil; meter?.invalidate(); meter = nil; recorder.stop(); level = 0
        statusItem?.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Voice")
        do { try store.save(entry) } catch { showHUD("Couldn’t save", "Check storage access", hideAfter: 4); return }
        refreshHistory()
        if submit {
            if !previewMode { soundCues.recordingFinished() }
            transcribe(entry, paste: true)
        }
        // Ready for another recording immediately; background work owns no HUD.
        hideHUD()
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.recorder === recorder else { return }
            self.finishRecording(submit: false)
            self.showHUD("Recording interrupted", "Audio saved in history", hideAfter: 4)
        }
    }
    func transcribe(_ original: Recording, paste: Bool) {
        guard !quitting, current?.id != original.id else { return }
        workQueue.enqueue(TranscriptionJob(recording: original, paste: paste))
    }
    func preserveCancelled(_ original: Recording) {
        if let saved = try? store.entries().first(where: { $0.id == original.id }), saved.text != nil { return }
        var entry = original
        entry.error = "Transcription cancelled on quit. Audio preserved; retry from history."
        try? store.save(entry)
    }
    func processTranscription(_ job: TranscriptionJob) async {
        var entry = job.recording
        do {
            let text = try await transcribeAudio(store.audio(entry))
            try Task.checkCancellation()
            guard !quitting else { preserveCancelled(entry); return }
            entry.text = text; entry.error = nil
            try store.save(entry)
            if let deliverOverride { await deliverOverride(text, job.paste) }
            else {
                copy(text)
                if job.paste { _ = await pasteIntoCurrentApp(text: text) }
            }
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
            entry.error = cancelled ? "Transcription cancelled on quit. Audio preserved; retry from history." : error.localizedDescription
            do { try store.save(entry) }
            catch {
                if !quitting, !recording { showHUD("Couldn’t save", "Check storage access", hideAfter: 4) }
                return
            }
            if !quitting, !recording, !cancelled {
                showHUD("Couldn’t transcribe", "Retry in history", hideAfter: 4)
            }
        }
        refreshHistory()
    }
    func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    func pasteIntoCurrentApp(text: String) async -> Bool {
        guard AXIsProcessTrusted(), !quitting, !Task.isCancelled else { return false }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            historyWindow?.orderOut(nil); setupWindow?.orderOut(nil); NSApp.hide(nil)
        }
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return false }
        do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return false }
        guard !quitting, !Task.isCancelled else { return false }
        copy(text)
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        // Give the receiving app time to consume this clipboard before the next result.
        try? await Task.sleep(nanoseconds: 120_000_000)
        return true
    }
    func showHistory() {
        refreshHistory()
        if historyWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 580), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Voice"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true; window.toolbarStyle = .unifiedCompact; window.backgroundColor = .windowBackgroundColor; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: HistoryView(controller: self)); window.center(); historyWindow = window
        }
        if !previewMode { NSApp.activate(ignoringOtherApps: true) }; historyWindow?.makeKeyAndOrderFront(nil)
    }
    func showSetup() {
        if setupWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 230), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Voice"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true; window.backgroundColor = .windowBackgroundColor; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SetupView(controller: self)); window.center(); setupWindow = window
        }
        if !previewMode { NSApp.activate(ignoringOtherApps: true) }; setupWindow?.makeKeyAndOrderFront(nil)
    }
}

// Shared native controls: SF Symbols, neutral surfaces, restrained hover feedback.
struct QuietIcon: View {
    let symbol: String
    let label: String
    var action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovered ? Color.primary : Color.secondary)
                .frame(width: 28, height: 28)
                .background(hovered ? Color.primary.opacity(0.07) : .clear, in: Circle())
                .contentShape(Circle())
        }.buttonStyle(.plain).onHover { hovered = $0 }
            .help(label).accessibilityLabel(label)
    }
}

struct RecordingHUD: View {
    @ObservedObject var controller: VoiceController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var transcribing: Bool { controller.state == "Transcribing" || controller.state == "Cancelling" }
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if transcribing {
                    ProgressView().controlSize(.small).tint(.primary).transition(.opacity.combined(with: .scale(scale: 0.7)))
                } else {
                    Image(systemName: controller.state == "Listening" ? "waveform" : "exclamationmark.circle")
                        .font(.system(size: 19, weight: .medium))
                        .symbolEffect(.variableColor.iterative, options: .repeating, isActive: controller.state == "Listening" && !reduceMotion)
                        .foregroundStyle(.primary).transition(.opacity.combined(with: .scale(scale: 0.7)))
                }
            }.frame(width: 24, height: 26)
            if transcribing {
                Text("Transcribing").font(.system(size: 13, weight: .medium)).transition(.opacity)
            } else if controller.state == "Listening" {
                HStack(alignment: .center, spacing: 3) {
                    ForEach(0..<11, id: \.self) { index in
                        Capsule().fill(Color.primary.opacity(0.35 + Double(index % 3) * 0.16))
                            .frame(width: 3, height: 5 + CGFloat(min(controller.level * 5, 1)) * CGFloat([12, 20, 9, 25, 17, 28, 13, 22, 10, 19, 14][index]))
                    }
                }.frame(height: 30).animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: controller.level)
            } else {
                Text(controller.state).font(.system(size: 13)).lineLimit(1).help(controller.detail)
            }
            Spacer(minLength: 0)
            if controller.state == "Listening" {
                Text(String(format: "%02d:%02d", Int(controller.elapsed) / 60, Int(controller.elapsed) % 60))
                    .font(.system(size: 12, weight: .regular, design: .monospaced)).foregroundStyle(.secondary)
                    .accessibilityLabel("Recording duration").transition(.opacity)
            }
            QuietIcon(symbol: "xmark", label: "Quit Voice") { controller.quitApp() }
        }
        .padding(.horizontal, 16)
        .frame(width: controller.hudSize.width, height: controller.hudSize.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: transcribing)
    }
}

struct HistoryView: View {
    @ObservedObject var controller: VoiceController
    @State private var search = ""
    @State private var copied: String?
    @State private var copyReset: DispatchWorkItem?
    var filtered: [Recording] { controller.entries.filter { search.isEmpty || ($0.text ?? $0.error ?? "").localizedCaseInsensitiveContains(search) } }
    func copy(_ entry: Recording) {
        guard let text = entry.text else { return }
        controller.copy(text); copied = entry.id; copyReset?.cancel()
        let work = DispatchWorkItem { copied = nil }; copyReset = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(.tertiary)
                TextField("Search", text: $search).textFieldStyle(.plain).font(.system(size: 13))
                if !search.isEmpty { QuietIcon(symbol: "xmark", label: "Clear search") { search = "" } }
                QuietIcon(symbol: "folder", label: "Open recordings") { controller.showFolder() }
            }.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 18)
            Divider().opacity(0.55)
            if filtered.isEmpty {
                Spacer()
                Text(search.isEmpty ? "No transcriptions yet" : "No results").font(.system(size: 13)).foregroundStyle(.tertiary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { entry in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 6) {
                                    Text(entry.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                                    Spacer()
                                    Text(String(format: "%02d:%02d", Int(entry.duration) / 60, Int(entry.duration) % 60)).monospacedDigit()
                                    QuietIcon(symbol: "play", label: "Play recording") { NSWorkspace.shared.open(controller.store.audio(entry)) }
                                    if entry.text != nil {
                                        QuietIcon(symbol: copied == entry.id ? "checkmark" : "doc.on.doc", label: copied == entry.id ? "Copied" : "Copy transcription") { copy(entry) }
                                    } else {
                                        QuietIcon(symbol: "arrow.clockwise", label: "Retry transcription") { controller.transcribe(entry, paste: false) }
                                            .disabled(controller.pendingIDs.contains(entry.id) || controller.current?.id == entry.id)
                                    }
                                }.font(.system(size: 11)).foregroundStyle(.secondary)
                                if let text = entry.text {
                                    Button { copy(entry) } label: {
                                        Text(text).font(.system(size: 14)).lineSpacing(5)
                                            .foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                    }.buttonStyle(.plain).accessibilityLabel("Copy transcription: \(text)")
                                } else {
                                    Text(controller.current?.id == entry.id ? "Recording…" : (controller.pendingIDs.contains(entry.id) ? "Transcribing…" : (entry.error ?? "Pending")))
                                        .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4)
                                }
                            }.padding(.horizontal, 28).padding(.vertical, 20)
                            Divider().padding(.horizontal, 28).opacity(0.4)
                        }
                    }.padding(.bottom, 16)
                }
            }
        }.frame(minWidth: 440, minHeight: 320).background(Color(nsColor: .windowBackgroundColor))
    }
}

struct SetupView: View {
    @ObservedObject var controller: VoiceController
    var body: some View {
        VStack(spacing: 0) {
            permission("Microphone", ready: controller.microphone, action: controller.requestMicrophone)
            Divider().opacity(0.4)
            permission("Accessibility", ready: controller.accessibility, action: controller.requestAccessibility)
            Divider().opacity(0.4)
            permission("Input Monitoring", ready: controller.inputMonitoring || controller.hotkeyReady, action: controller.requestInputMonitoring)
            HStack { Spacer(); QuietIcon(symbol: "checkmark", label: "Done") { controller.setupWindow?.orderOut(nil); NSApp.hide(nil) } }.padding(.top, 12)
        }.padding(.horizontal, 24).padding(.vertical, 18).frame(width: 400, height: 230)
            .background(Color(nsColor: .windowBackgroundColor))
    }
    func permission(_ title: String, ready: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            if ready { Image(systemName: "checkmark").font(.system(size: 12)).foregroundStyle(.secondary).accessibilityLabel("Enabled") }
            else { Button("Enable", action: action).buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary) }
        }.frame(height: 44)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: VoiceController?
    var terminationSources: [DispatchSourceSignal] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(externalQuit), name: Notification.Name("local.l.voice.quit"), object: nil)
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in self?.controller?.quitApp() }
            source.resume(); terminationSources.append(source)
        }
        do { controller = VoiceController(store: try HistoryStore()); controller?.start() }
        catch { let alert = NSAlert(); alert.messageText = "Voice could not start"; alert.informativeText = error.localizedDescription; alert.runModal(); NSApp.terminate(nil) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    @objc func externalQuit() { controller?.quitApp() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { controller?.shutdown(); return .terminateNow }
    func applicationWillTerminate(_ notification: Notification) { controller?.shutdown() }
}
