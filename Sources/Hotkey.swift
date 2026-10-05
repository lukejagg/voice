import AppKit
import CoreGraphics

final class Hotkey {
    var onSingle: (() -> Void)?
    var onDouble: (() -> Void)?
    var allowsDoubleTap: () -> Bool = { true }
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var gesture = OptionGesture()
    private var timer: Timer?
    var running: Bool { tap != nil }
    func start() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, pointer in
            guard let pointer else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<Hotkey>.fromOpaque(pointer).takeUnretainedValue()
            owner.handle(type, event)
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return false }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }
    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            gesture = OptionGesture(); timer?.invalidate(); timer = nil
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }; return
        }
        guard type == .flagsChanged else { gesture.cancelChord(); return }
        guard event.getIntegerValueField(.keyboardEventKeycode) == 61 else { gesture.cancelChord(); return }
        let now = event.timestamp > 0 ? Double(event.timestamp) / 1_000_000_000 : ProcessInfo.processInfo.systemUptime
        // Device-specific right Option bit distinguishes it even when left Option is held.
        let down = event.flags.rawValue & 0x40 != 0
        if down {
            let others = !event.flags.intersection([.maskCommand, .maskControl, .maskShift]).isEmpty || event.flags.rawValue & 0x20 != 0
            gesture.down(at: now, otherModifiers: others)
        } else {
            let action = gesture.up(at: now, allowDouble: allowsDoubleTap())
            if action == .double { timer?.invalidate(); timer = nil; onDouble?(); return }
            if action == .single { onSingle?() }
            if gesture.pendingAt != nil {
                timer?.invalidate()
                timer = Timer.scheduledTimer(withTimeInterval: gesture.interval + 0.01, repeats: false) { [weak self] _ in
                    guard let self else { return }
                    _ = self.gesture.flush(at: ProcessInfo.processInfo.systemUptime)
                }
                if let timer { RunLoop.main.add(timer, forMode: .common) }
            }
        }
    }
}
