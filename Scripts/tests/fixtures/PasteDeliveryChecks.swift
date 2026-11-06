import Foundation

@MainActor final class DisposableDestination {
    var clipboard = "generated clip"
    var prepared = true
    var frontmost = true
    var focused = true
    var postAvailable = true
    var inserted: [String] = []
    var feedback: [PasteDelivery.Failure] = []
    var onRestore: (() -> Void)?
    var onWait: (() -> Void)?
    func deliver(_ delivery: PasteDelivery, generation: Int? = nil) async {
        await delivery.deliver(generation: generation ?? delivery.prepare(), activate: {}, isFrontmost: { self.frontmost },
            isFocused: { self.focused }, restoreFocus: { self.onRestore?() },
            clipboardIsCurrent: { self.prepared }, post: { guard self.postAvailable else { return false }; self.inserted.append(self.clipboard); return true },
            feedback: { self.feedback.append($0) }, wait: { _ in self.onWait?() })
    }
}

@main struct PasteDeliveryChecks {
    @MainActor static func main() async {
        let delivery = PasteDelivery()
        let stale = DisposableDestination()
        let oldRequest = delivery.prepare()
        delivery.cancel()
        await stale.deliver(delivery, generation: oldRequest)
        precondition(stale.inserted.isEmpty && stale.feedback.isEmpty, "Superseded work must stay cancelled even if its task starts late")
        let cancelled = DisposableDestination()
        cancelled.onWait = { delivery.cancel() }
        await cancelled.deliver(delivery)
        precondition(cancelled.inserted.isEmpty && cancelled.feedback.isEmpty, "A newer copy or panel opening must supersede pending insertion silently")
        let switched = DisposableDestination()
        switched.focused = false
        switched.onRestore = { switched.focused = true; switched.frontmost = false }
        await switched.deliver(delivery)
        precondition(switched.inserted.isEmpty && switched.feedback == [.destinationUnavailable], "Switching apps during focus restoration must never insert")
        let missing = DisposableDestination()
        missing.focused = false
        await missing.deliver(delivery)
        precondition(missing.inserted.isEmpty && missing.feedback == [.destinationUnavailable], "An unconfirmable field must fall back")
        let changedWhileRestoring = DisposableDestination()
        changedWhileRestoring.focused = false
        changedWhileRestoring.onRestore = { changedWhileRestoring.focused = true; changedWhileRestoring.prepared = false }
        await changedWhileRestoring.deliver(delivery)
        precondition(changedWhileRestoring.inserted.isEmpty && changedWhileRestoring.feedback == [.clipboardChanged], "Clipboard replacement during focus restoration must cancel")
        let unavailable = DisposableDestination()
        unavailable.postAvailable = false
        await unavailable.deliver(delivery)
        await unavailable.deliver(delivery)
        precondition(unavailable.inserted.isEmpty && unavailable.feedback == [.destinationUnavailable, .destinationUnavailable], "Unavailable event delivery must explain every failure")
        let restored = DisposableDestination()
        restored.focused = false
        restored.onRestore = { restored.focused = true }
        await restored.deliver(delivery)
        precondition(restored.inserted == ["generated clip"] && restored.feedback.isEmpty, "A confirmed restored destination receives exactly one generated item")
        let replaced = DisposableDestination()
        replaced.onWait = { replaced.clipboard = "unrelated replacement"; replaced.prepared = false }
        await replaced.deliver(delivery)
        precondition(replaced.inserted.isEmpty && replaced.feedback == [.clipboardChanged], "Replacement clipboard must never be inserted or described as copied")
    }
}
