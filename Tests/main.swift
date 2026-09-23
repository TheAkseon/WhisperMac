import Cocoa

final class FakeKeyboardBackend: KeyboardEventBackend {
    var rightCommandIsDown = false
    var failGlobal = false
    var failLocal = false
    var nextToken = 0
    var active: Set<Int> = []
    var globalHandler: ((UInt16, UInt64) -> Void)?
    var localHandler: ((UInt16, UInt64) -> Void)?
    var additions = 0
    var removals = 0
    var peakActive = 0

    private func add(fails: Bool) -> Any? {
        guard !fails else { return nil }
        nextToken += 1
        additions += 1
        active.insert(nextToken)
        peakActive = max(peakActive, active.count)
        return nextToken
    }
    func addGlobal(_ handler: @escaping (UInt16, UInt64) -> Void) -> Any? {
        globalHandler = handler
        return add(fails: failGlobal)
    }
    func addLocal(_ handler: @escaping (UInt16, UInt64) -> Void) -> Any? {
        localHandler = handler
        return add(fails: failLocal)
    }
    func remove(_ token: Any) {
        precondition(active.remove(token as! Int) != nil, "monitor removed twice")
        removals += 1
    }
}

final class PendingEvents {
    var work: [() -> Void] = []
    func enqueue(_ callback: @escaping () -> Void) { work.append(callback) }
    func drain() {
        let callbacks = work
        work.removeAll()
        callbacks.forEach { $0() }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

let backend = FakeKeyboardBackend()
let pending = PendingEvents()
var transitions: [Bool] = []
let monitor = KeyboardMonitor(backend: backend, enqueue: pending.enqueue) { pressed, _ in
    transitions.append(pressed)
}

// Repeated setup and dictations must never register additional native monitors.
for _ in 0..<1000 { expect(monitor.start(), "setup failed") }
expect(backend.additions == 2 && backend.active.count == 2, "setup accumulates monitors")
for _ in 0..<1000 {
    backend.globalHandler?(0x36, 0x10)
    backend.globalHandler?(0x36, 0x10) // duplicate notification
    backend.globalHandler?(0x37, 0x08) // left Command cannot stop recording
    backend.globalHandler?(0x36, 0x08) // release right while left stays down
}
expect(transitions.isEmpty, "recording work ran synchronously in input callback")
pending.drain()
expect(transitions.count == 2000, "duplicate or missing down/up transition")
expect(transitions.enumerated().allSatisfy { $0.element == ($0.offset % 2 == 0) }, "event order changed")
expect(backend.additions == 2, "dictation registered new monitors")

// A global press and local release across a focus change is one dictation.
transitions.removeAll()
backend.globalHandler?(0x36, 0x10)
backend.localHandler?(0x36, 0)
pending.drain()
expect(transitions == [true, false], "focus change lost key release")

// Retry invalidates queued events and callbacks from the previous registration.
transitions.removeAll()
let staleHandler = backend.globalHandler
backend.globalHandler?(0x36, 0x10)
monitor.stop()
expect(monitor.start(), "restart failed")
staleHandler?(0x36, 0)
staleHandler?(0x36, 0x10)
pending.drain()
expect(transitions.isEmpty, "stale callback restarted recording")
backend.localHandler?(0x36, 0x10)
backend.localHandler?(0x36, 0)
pending.drain()
expect(transitions == [true, false], "new registration did not receive events")

// Repeated Retry and Quit release both tokens, including partial setup failure.
for _ in 0..<1000 { monitor.stop(); expect(monitor.start(), "retry failed") }
monitor.stop()
monitor.stop()
expect(backend.active.isEmpty && backend.removals == backend.additions, "monitor token leak")
expect(backend.peakActive == 2, "overlapping registrations")
for globalFails in [true, false] {
    backend.failGlobal = globalFails
    backend.failLocal = !globalFails
    expect(!monitor.start(), "partial installation treated as connected")
    expect(backend.active.isEmpty, "partial installation leaked a monitor")
}
backend.failGlobal = false
backend.failLocal = false

// Installing while right Command is already held must wait for a fresh press.
backend.rightCommandIsDown = true
transitions.removeAll()
expect(monitor.start(), "held-key setup failed")
backend.globalHandler?(0x36, 0x10)
backend.globalHandler?(0x36, 0)
pending.drain()
expect(transitions == [false], "setup while key held started unexpected dictation")
monitor.stop()
expect(backend.active.isEmpty, "final cleanup failed")
print("PASS: 1,000 dictations, 1,000 retries, callback ordering, stale events, failure cleanup, focus changes")
