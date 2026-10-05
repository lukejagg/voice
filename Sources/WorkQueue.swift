import Foundation

// Runs completed recordings in order without holding up microphone interaction.
@MainActor
final class OrderedWorkQueue<Item> {
    private var waiting: [Item] = []
    private var active: Item?
    private var worker: Task<Void, Never>?
    private var closed = false
    private let identifier: (Item) -> String
    private let process: (Item) async -> Void
    private let discard: (Item) -> Void
    private let changed: (Set<String>) -> Void
    var pendingIDs: Set<String> {
        Set(waiting.map(identifier) + (active.map { [identifier($0)] } ?? []))
    }
    init(identifier: @escaping (Item) -> String, process: @escaping (Item) async -> Void,
         discard: @escaping (Item) -> Void = { _ in }, changed: @escaping (Set<String>) -> Void = { _ in }) {
        self.identifier = identifier; self.process = process; self.discard = discard; self.changed = changed
    }
    @discardableResult
    func enqueue(_ item: Item) -> Bool {
        guard !closed, !pendingIDs.contains(identifier(item)) else { return false }
        waiting.append(item); changed(pendingIDs)
        if worker == nil {
            worker = Task { @MainActor [weak self] in
                guard let self else { return }
                while !self.closed, !Task.isCancelled, !self.waiting.isEmpty {
                    self.active = self.waiting.removeFirst(); self.changed(self.pendingIDs)
                    await self.process(self.active!)
                    self.active = nil; self.changed(self.pendingIDs)
                }
                self.worker = nil
            }
        }
        return true
    }
    func shutdown() {
        closed = true; worker?.cancel()
        let abandoned = waiting; waiting.removeAll()
        for item in abandoned { discard(item) }
        if let active { discard(active) }
        changed(pendingIDs)
    }
}

struct TranscriptionJob {
    let recording: Recording
    let paste: Bool
}
