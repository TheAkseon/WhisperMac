import Cocoa
import AVFoundation

let rightCommandKeyCode: UInt16 = 0x36
let vKeyCode: UInt16 = 0x09

struct Model: CaseIterable {
    let name: String
    let filename: String
    let size: String
    let minimumBytes: Int64
    let url: String

    static let tiny    = Model(name: "Tiny (multilingual)",    filename: "ggml-tiny.bin",       size: "78 MB",  minimumBytes: 70_000_000, url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin")
    static let base    = Model(name: "Base (multilingual)",    filename: "ggml-base.bin",       size: "148 MB", minimumBytes: 140_000_000, url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin")
    static let small   = Model(name: "Small (multilingual)",   filename: "ggml-small.bin",      size: "488 MB", minimumBytes: 450_000_000, url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin")
    static let medium  = Model(name: "Medium (multilingual)",  filename: "ggml-medium.bin",     size: "1.5 GB", minimumBytes: 1_400_000_000, url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin")
    static let large   = Model(name: "Large v3 (multilingual)", filename: "ggml-large-v3.bin",  size: "2.9 GB", minimumBytes: 2_800_000_000, url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin")

    static let allCases: [Model] = [.tiny, .base, .small, .medium, .large]

    static func from(filename: String) -> Model? {
        allCases.first { $0.filename == filename }
    }
}

var isRecording = false
var isTranscribing = false
var isRightCommandDown = false
var isEnabled = true
var audioRecorder: AVAudioRecorder?
var recordingURL: URL?
var statusItem: NSStatusItem!
var eventTap: CFMachPort?
var tapRunLoopSource: CFRunLoopSource?
var tapHealthTimer: Timer?
var downloadSession: URLSessionDownloadTask?
var isDownloading = false
var selectedModel: Model = .medium

let home = FileManager.default.homeDirectoryForCurrentUser.path
let appSupport = home + "/.whispermac"
let modelsDir = appSupport + "/models"
let diagnosticLogPath = appSupport + "/debug.log"
let diagnosticQueue = DispatchQueue(label: "com.whispermac.diagnostics")

func logDiagnostic(_ message: String) {
    diagnosticQueue.async {
        let line = "\(Date()) \(message)\n"
        let data = Data(line.utf8)
        let url = URL(fileURLWithPath: diagnosticLogPath)
        if !FileManager.default.fileExists(atPath: diagnosticLogPath) {
            FileManager.default.createFile(atPath: diagnosticLogPath, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
var whisperBinPath: String {
    (Bundle.main.resourcePath ?? "") + "/whisper-cli"
}

var modelPath: String {
    modelsDir + "/" + selectedModel.filename
}

let audioSettings: [String: Any] = [
    AVFormatIDKey: Int(kAudioFormatLinearPCM),
    AVSampleRateKey: 16000.0,
    AVNumberOfChannelsKey: 1,
    AVLinearPCMBitDepthKey: 16,
    AVLinearPCMIsFloatKey: false,
    AVLinearPCMIsBigEndianKey: false,
]

func playSound(_ name: String) {
    if let sound = NSSound(named: name) {
        sound.volume = 0.5
        sound.play()
    }
}

func setIcon(_ name: String) {
    guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
    img.size = NSSize(width: 18, height: 18)
    img.isTemplate = true
    statusItem.button?.image = img
}

func startRecording() {
    guard !isTranscribing else { return }
    guard FileManager.default.fileExists(atPath: whisperBinPath), modelExists() else {
        logDiagnostic("recording unavailable: CLI or model missing")
        statusItem.button?.toolTip = "WhisperMac — Install whisper-cli and download a model in Preferences"
        playSound("Basso")
        return
    }
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
        logDiagnostic("recording unavailable: microphone access not granted")
        statusItem.button?.toolTip = "WhisperMac — Allow microphone access in System Settings"
        playSound("Basso")
        return
    }

    let url = FileManager.default.temporaryDirectory.appendingPathComponent("whispermac-\(UUID().uuidString).wav")

    guard let recorder = try? AVAudioRecorder(url: url, settings: audioSettings) else {
        logDiagnostic("recording unavailable: AVAudioRecorder could not initialize")
        playSound("Basso")
        return
    }
    guard recorder.prepareToRecord(), recorder.record() else {
        logDiagnostic("recording unavailable: AVAudioRecorder could not start")
        playSound("Basso")
        return
    }
    audioRecorder = recorder
    recordingURL = url
    isRecording = true
    logDiagnostic("recording started")
    playSound("Ping")
    setIcon("waveform.circle.fill")
    statusItem.button?.toolTip = "WhisperMac — Recording"
}

func stopAndTranscribe() {
    guard let inputURL = recordingURL else { return }
    audioRecorder?.stop()
    audioRecorder = nil
    recordingURL = nil
    isRecording = false
    isTranscribing = true
    logDiagnostic("recording stopped; transcription started")
    setIcon("arrow.triangle.2.circlepath")
    statusItem.button?.toolTip = "WhisperMac — Transcribing"
    let chosenModelPath = modelPath

    DispatchQueue.global(qos: .userInitiated).async {
        let outputBase = FileManager.default.temporaryDirectory.appendingPathComponent("whispermac-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: inputURL)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: outputBase.path + ".txt"))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperBinPath)
        process.arguments = ["-f", inputURL.path, "-m", chosenModelPath, "-otxt", "-of", outputBase.path, "-np", "--no-timestamps", "-l", "auto"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        var text: String?
        do {
            try process.run()
            process.waitUntilExit()
            logDiagnostic("whisper-cli exited with status \(process.terminationStatus)")
            if process.terminationStatus == 0 {
                text = try? String(contentsOfFile: outputBase.path + ".txt", encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            logDiagnostic("whisper-cli failed to run: \(error.localizedDescription)")
        }

        DispatchQueue.main.async {
            isTranscribing = false
            if let text = text, !text.isEmpty {
                logDiagnostic("transcription produced text")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)

                let source = CGEventSource(stateID: .combinedSessionState)
                let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
                down?.flags = .maskCommand
                down?.post(tap: .cghidEventTap)

                let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
                up?.flags = .maskCommand
                up?.post(tap: .cghidEventTap)

                playSound("Glass")
                statusItem.button?.toolTip = "WhisperMac — Hold Right ⌘ to record"
            } else {
                logDiagnostic("transcription produced no text")
                playSound("Basso")
                statusItem.button?.toolTip = "WhisperMac — Transcription failed or no speech detected"
            }
            if !isRecording { setIcon("waveform.circle") }
        }
    }
}

let callback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
    } else if type == .flagsChanged && event.getIntegerValueField(.keyboardEventKeycode) == rightCommandKeyCode {
        // The device-specific right Command bit distinguishes it from left Command.
        let isDown = (event.flags.rawValue & 0x10) != 0
        if isDown != isRightCommandDown {
            isRightCommandDown = isDown
            logDiagnostic("right Command \(isDown ? "pressed" : "released")")
            if isDown && isEnabled && !isRecording && !isTranscribing {
                startRecording()
            } else if !isDown && isRecording {
                stopAndTranscribe()
            }
        }
    }
    return Unmanaged.passUnretained(event)
}

func removeTap() {
    if let source = tapRunLoopSource {
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        tapRunLoopSource = nil
    }
    eventTap = nil
}

func createTap() -> Bool {
    removeTap()
    isRightCommandDown = CGEventSource.keyState(.combinedSessionState, key: rightCommandKeyCode)
    let mask = (1 << CGEventType.flagsChanged.rawValue)
    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: CGEventMask(mask),
        callback: callback,
        userInfo: nil
    ) else { return false }
    eventTap = tap
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    tapRunLoopSource = source
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return true
}

func setupTap() {
    guard CGPreflightListenEventAccess() else {
        removeTap()
        setIcon("exclamationmark.circle")
        statusItem.button?.toolTip = "WhisperMac — Allow Input Monitoring in System Settings"
        logDiagnostic("keyboard tap unavailable: Input Monitoring not granted")
        return
    }
    if createTap() {
        logDiagnostic("keyboard tap connected")
        if !isRecording && !isTranscribing { setIcon("waveform.circle") }
        statusItem.button?.toolTip = "WhisperMac — Hold Right ⌘ to record"
    } else {
        logDiagnostic("keyboard tap unavailable: could not create tap")
        setIcon("exclamationmark.circle")
        statusItem.button?.toolTip = "WhisperMac — Need Accessibility permission"
    }
}

func checkTapHealth() {
    if !CGPreflightListenEventAccess() {
        if eventTap != nil { setupTap() }
        return
    }
    if isRecording && !CGEventSource.keyState(.combinedSessionState, key: rightCommandKeyCode) {
        isRightCommandDown = false
        stopAndTranscribe()
    }
    guard let tap = eventTap else {
        _ = createTap()
        if eventTap != nil {
            if !isRecording && !isTranscribing { setIcon("waveform.circle") }
            statusItem.button?.toolTip = "WhisperMac — Hold Right ⌘ to record"
        }
        return
    }
    if !CGEvent.tapIsEnabled(tap: tap) {
        CGEvent.tapEnable(tap: tap, enable: true)
        if !CGEvent.tapIsEnabled(tap: tap) {
            removeTap()
            _ = createTap()
            if eventTap != nil {
                if !isRecording && !isTranscribing { setIcon("waveform.circle") }
                statusItem.button?.toolTip = "WhisperMac — Hold Right ⌘ to record"
            }
        }
    }
}

func loadPreferences() {
    let prefs = UserDefaults.standard
    if let name = prefs.string(forKey: "modelFilename"),
       let model = Model.from(filename: name) {
        selectedModel = model
    }
    isEnabled = prefs.object(forKey: "isEnabled") as? Bool ?? true
}

func savePreferences() {
    let prefs = UserDefaults.standard
    prefs.set(selectedModel.filename, forKey: "modelFilename")
    prefs.set(isEnabled, forKey: "isEnabled")
}

func modelExists() -> Bool {
    validModel(at: URL(fileURLWithPath: modelPath), minimumBytes: selectedModel.minimumBytes)
}

func validModel(at url: URL, minimumBytes: Int64) -> Bool {
    guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber,
          size.int64Value >= minimumBytes,
          let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    return (try? handle.read(upToCount: 4)) == Data([0x6c, 0x6d, 0x67, 0x67])
}

func downloadModel(progress: @escaping (Double) -> Void, completion: @escaping (Bool) -> Void) {
    guard let url = URL(string: selectedModel.url) else { completion(false); return }
    try? FileManager.default.createDirectory(atPath: modelsDir, withIntermediateDirectories: true, attributes: nil)

    let session = URLSession(configuration: .default, delegate: DownloadDelegate(progress: progress, destination: modelPath, minimumBytes: selectedModel.minimumBytes, completion: completion), delegateQueue: nil)
    downloadSession = session.downloadTask(with: url)
    downloadSession?.resume()
}

class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let progress: (Double) -> Void
    let destination: String
    let minimumBytes: Int64
    let completion: (Bool) -> Void
    private var downloaded = false

    init(progress: @escaping (Double) -> Void, destination: String, minimumBytes: Int64, completion: @escaping (Bool) -> Void) {
        self.progress = progress
        self.destination = destination
        self.minimumBytes = minimumBytes
        self.completion = completion
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            DispatchQueue.main.async { self.progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard validModel(at: location, minimumBytes: minimumBytes),
              (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else { return }
        do {
            let target = URL(fileURLWithPath: destination)
            if FileManager.default.fileExists(atPath: destination) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: location)
            } else {
                try FileManager.default.moveItem(at: location, to: target)
            }
            downloaded = true
        } catch {}
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let success = error == nil && downloaded
        DispatchQueue.main.async { self.completion(success) }
        session.finishTasksAndInvalidate()
    }
}

class PrefsWindow: NSObject, NSWindowDelegate {
    var window: NSWindow!
    var modelPopup: NSPopUpButton!
    var downloadButton: NSButton!
    var progressBar: NSProgressIndicator!
    var statusLabel: NSTextField!
    var enableCheckbox: NSButton!
    var cancelButton: NSButton!
    private var downloadID: UUID?

    func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 280),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "WhisperMac"
        window.delegate = self
        window.center()

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 280))

        let titleLabel = NSTextField(labelWithString: "Whisper Model")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 13)
        titleLabel.frame = NSRect(x: 20, y: 235, width: 420, height: 20)
        content.addSubview(titleLabel)

        modelPopup = NSPopUpButton(frame: NSRect(x: 20, y: 200, width: 420, height: 26))
        modelPopup.addItems(withTitles: Model.allCases.map { "\($0.name) — \($0.size)" })
        if let idx = Model.allCases.firstIndex(where: { $0.filename == selectedModel.filename }) {
            modelPopup.selectItem(at: idx)
        }
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged)
        content.addSubview(modelPopup)

        downloadButton = NSButton(frame: NSRect(x: 20, y: 160, width: 180, height: 28))
        downloadButton.title = "Download"
        downloadButton.bezelStyle = .rounded
        downloadButton.target = self
        downloadButton.action = #selector(startDownload)
        content.addSubview(downloadButton)

        cancelButton = NSButton(frame: NSRect(x: 210, y: 160, width: 80, height: 28))
        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelDownload)
        cancelButton.isHidden = true
        content.addSubview(cancelButton)

        progressBar = NSProgressIndicator(frame: NSRect(x: 20, y: 130, width: 420, height: 14))
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.isHidden = true
        content.addSubview(progressBar)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.frame = NSRect(x: 20, y: 105, width: 420, height: 16)
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        content.addSubview(statusLabel)

        updateStatus()

        enableCheckbox = NSButton(checkboxWithTitle: "Enable (Right ⌘ to record)", target: self, action: #selector(toggleEnabled))
        enableCheckbox.frame = NSRect(x: 20, y: 65, width: 420, height: 22)
        enableCheckbox.state = isEnabled ? .on : .off
        content.addSubview(enableCheckbox)

        let sep = NSBox(frame: NSRect(x: 20, y: 48, width: 420, height: 1))
        sep.boxType = .separator
        content.addSubview(sep)

        let infoLabel = NSTextField(labelWithString: "Hold Right ⌘ key, speak, release — text pastes automatically.")
        infoLabel.frame = NSRect(x: 20, y: 5, width: 420, height: 30)
        infoLabel.font = NSFont.systemFont(ofSize: 10)
        infoLabel.textColor = .secondaryLabelColor
        content.addSubview(infoLabel)

        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateStatus() {
        if modelExists() {
            statusLabel.stringValue = "✅ Model ready"
            statusLabel.textColor = .systemGreen
            downloadButton.title = "Re-download"
        } else {
            statusLabel.stringValue = "⚠️ Model not downloaded — click Download"
            statusLabel.textColor = .systemOrange
            downloadButton.title = "Download"
        }
        progressBar.isHidden = true
        cancelButton.isHidden = true
        downloadButton.isEnabled = !isDownloading
        modelPopup.isEnabled = !isDownloading
    }

    @objc func modelChanged() {
        guard let newModel = Model.allCases[safe: modelPopup.indexOfSelectedItem] else { return }
        selectedModel = newModel
        savePreferences()
        updateStatus()
    }

    @objc func toggleEnabled() {
        isEnabled = (enableCheckbox.state == .on)
        savePreferences()
    }

    @objc func startDownload() {
        let id = UUID()
        downloadID = id
        isDownloading = true
        downloadButton.isEnabled = false
        modelPopup.isEnabled = false
        cancelButton.isHidden = false
        progressBar.isHidden = false
        progressBar.doubleValue = 0
        statusLabel.stringValue = "Downloading \(selectedModel.size)..."
        statusLabel.textColor = .secondaryLabelColor

        downloadModel(progress: { p in
            guard self.downloadID == id else { return }
            self.progressBar.doubleValue = p
            let mb = Double(selectedModel.size.replacingOccurrences(of: " MB", with: "").replacingOccurrences(of: " GB", with: "")) ?? 0
            let total = selectedModel.size.contains("GB") ? mb * 1000 : mb
            self.statusLabel.stringValue = String(format: "Downloading... %.0f%% (%.0f / %.0f MB)", p * 100, p * total, total)
        }, completion: { success in
            guard self.downloadID == id else { return }
            self.downloadID = nil
            isDownloading = false
            downloadSession = nil
            self.cancelButton.isHidden = true
            self.progressBar.isHidden = true
            self.downloadButton.isEnabled = true
            self.modelPopup.isEnabled = true
            if success {
                self.statusLabel.stringValue = "✅ Model downloaded"
                self.statusLabel.textColor = .systemGreen
                self.downloadButton.title = "Re-download"
            } else {
                self.statusLabel.stringValue = "❌ Download failed"
                self.statusLabel.textColor = .systemRed
            }
        })
    }

    @objc func cancelDownload() {
        downloadID = nil
        downloadSession?.cancel()
        downloadSession = nil
        isDownloading = false
        downloadButton.isEnabled = true
        modelPopup.isEnabled = true
        cancelButton.isHidden = true
        progressBar.isHidden = true
        statusLabel.stringValue = "Download cancelled"
        statusLabel.textColor = .secondaryLabelColor
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    let prefs = PrefsWindow()

    @objc func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc func openInputMonitoringSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    @objc func openPreferences() {
        prefs.show()
    }

    @objc func retryTap() {
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        setupTap()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(atPath: modelsDir, withIntermediateDirectories: true, attributes: nil)
        loadPreferences()
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        logDiagnostic("app launched; model=\(selectedModel.filename); Input Monitoring=\(CGPreflightListenEventAccess()); microphone=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }

        statusItem = NSStatusBar.system.statusItem(withLength: 24)
        setIcon("waveform.circle")
        statusItem.button?.toolTip = "WhisperMac — Hold Right ⌘ to record"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "WhisperMac", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        let preferencesItem = NSMenuItem(title: "Preferences...", action: #selector(openPreferences), keyEquivalent: ",")
        preferencesItem.target = self
        menu.addItem(preferencesItem)
        menu.addItem(NSMenuItem.separator())
        let accessibilityItem = NSMenuItem(title: "Open Accessibility Settings", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)
        let inputMonitoringItem = NSMenuItem(title: "Open Input Monitoring Settings", action: #selector(openInputMonitoringSettings), keyEquivalent: "")
        inputMonitoringItem.target = self
        menu.addItem(inputMonitoringItem)
        let retryItem = NSMenuItem(title: "Retry Connection", action: #selector(retryTap), keyEquivalent: "")
        retryItem.target = self
        menu.addItem(retryItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        setupTap()
        tapHealthTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in checkTapHealth() }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
