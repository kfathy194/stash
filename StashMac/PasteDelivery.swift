import Foundation

/// Coordinates only transient OS delivery. The native adapter owns target and clipboard checks.
@MainActor final class PasteDelivery {
    enum Failure { case clipboardChanged, destinationUnavailable }
    private var generation = 0
    func cancel() { generation += 1 }
    func prepare() -> Int { cancel(); return generation }
    func deliver(generation current: Int, activate: () -> Void, isFrontmost: () -> Bool, isFocused: () -> Bool,
                 restoreFocus: () -> Void, clipboardIsCurrent: () -> Bool, post: () -> Bool,
                 feedback: (Failure) -> Void,
                 wait: (Duration) async -> Void = { try? await Task.sleep(for: $0) }) async {
        guard current == generation else { return }
        activate()
        await wait(.milliseconds(140))
        guard current == generation else { return }
        guard clipboardIsCurrent() else { feedback(.clipboardChanged); return }
        guard isFrontmost() else { feedback(.destinationUnavailable); return }
        if !isFocused() {
            restoreFocus()
            await wait(.milliseconds(80))
        }
        guard current == generation else { return }
        guard clipboardIsCurrent() else { feedback(.clipboardChanged); return }
        guard isFocused(), isFrontmost(), post() else { feedback(.destinationUnavailable); return }
    }
}
