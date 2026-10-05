import AppKit
import Foundation
import Darwin

umask(0o077)

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--transcribe-file" {
    let audio = URL(fileURLWithPath: CommandLine.arguments[2])
    Task {
        do { let text = try await TranscriptionClient().transcribe(audio); print(text); exit(0) }
        catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }
    dispatchMain()
} else if CommandLine.arguments.contains("--quit") {
    DistributedNotificationCenter.default().postNotificationName(Notification.Name("local.l.voice.quit"), object: nil, userInfo: nil, deliverImmediately: true)
} else {
    let lockDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Voice")
    do { try FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
    catch { fputs("Could not create Voice lock directory.\n", stderr); exit(1) }
    let instanceLock: InstanceLock
    do { instanceLock = try InstanceLock(url: lockDirectory.appendingPathComponent("instance.lock")) }
    catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    guard instanceLock.acquire() else { print("Voice is already running; no second instance started."); exit(0) }
    MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.setActivationPolicy(.accessory)
    app.delegate = delegate
    withExtendedLifetime(instanceLock) { app.run() }
    }
}
