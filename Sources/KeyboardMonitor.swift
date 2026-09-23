import Cocoa

protocol KeyboardEventBackend {
    var rightCommandIsDown: Bool { get }
    func addGlobal(_ handler: @escaping (UInt16, UInt64) -> Void) -> Any?
    func addLocal(_ handler: @escaping (UInt16, UInt64) -> Void) -> Any?
    func remove(_ token: Any)
}

struct AppKitKeyboardEventBackend: KeyboardEventBackend {
    var rightCommandIsDown: Bool {
        (CGEventSource.flagsState(.combinedSessionState).rawValue & 0x10) != 0
    }

    func addGlobal(_ handler: @escaping (UInt16, UInt64) -> Void) -> Any? {
        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            handler(event.keyCode, UInt64(event.modifierFlags.rawValue))
        }
    }

    func addLocal(_ handler: @escaping (UInt16, UInt64) -> Void) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handler(event.keyCode, UInt64(event.modifierFlags.rawValue))
            return event
        }
    }

    func remove(_ token: Any) {
        NSEvent.removeMonitor(token)
    }
}

// AppKit's global and local monitors cover disjoint event streams. Keep exactly
// one of each; a second CGEvent tap duplicates input and owns WindowServer ports.
// All lifecycle methods and AppKit callbacks run on the main thread.
final class KeyboardMonitor {
    private let backend: KeyboardEventBackend
    private let enqueue: (@escaping () -> Void) -> Void
    private let onChange: (Bool, String) -> Void
    private var globalToken: Any?
    private var localToken: Any?
    private var generation: UInt64 = 0
    private var isDown = false

    var isConnected: Bool { globalToken != nil && localToken != nil }

    init(backend: KeyboardEventBackend = AppKitKeyboardEventBackend(),
         enqueue: @escaping (@escaping () -> Void) -> Void = { work in
             DispatchQueue.main.async(execute: work)
         },
         onChange: @escaping (Bool, String) -> Void) {
        self.backend = backend
        self.enqueue = enqueue
        self.onChange = onChange
    }

    @discardableResult
    func start() -> Bool {
        if isConnected { return true }
        stop()
        isDown = backend.rightCommandIsDown
        let currentGeneration = generation
        globalToken = backend.addGlobal { [weak self] keyCode, flags in
            self?.receive(keyCode, flags, source: "global monitor", generation: currentGeneration)
        }
        localToken = backend.addLocal { [weak self] keyCode, flags in
            self?.receive(keyCode, flags, source: "local monitor", generation: currentGeneration)
        }
        // A partially installed pair must not survive the failed setup.
        guard isConnected else { stop(); return false }
        return true
    }

    func stop() {
        generation &+= 1
        if let token = globalToken { backend.remove(token) }
        if let token = localToken { backend.remove(token) }
        globalToken = nil
        localToken = nil
        isDown = false
    }

    private func receive(_ keyCode: UInt16, _ flags: UInt64, source: String, generation: UInt64) {
        guard keyCode == 0x36 else { return }
        let pressed = (flags & 0x10) != 0
        // Never initialize/stop audio, touch files, query TCC or draw UI inside
        // an input callback. Capture scalars and return the event immediately.
        enqueue { [weak self] in
            guard let self, self.generation == generation, self.isConnected,
                  self.isDown != pressed else { return }
            self.isDown = pressed
            self.onChange(pressed, source)
        }
    }
}
