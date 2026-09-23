import Cocoa
import AVFoundation

let vKeyCode: UInt16 = 0x09
// Leave CPU capacity for the foreground app while whisper.cpp transcribes.
let transcriptionThreadCount = 2

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
var isEnabled = true
var audioRecorder: AVAudioRecorder?
var recordingURL: URL?
var recordingTargetPID: pid_t?
var statusItem: NSStatusItem!
let keyboardMonitor = KeyboardMonitor(onChange: handleRightCommand)
var downloadSession: URLSessionDownloadTask?
var isDownloading = false
var selectedModel: Model = .medium
var activityWindow: PrefsWindow?

func showActivity(_ message: String, color: NSColor = .labelColor) {
    activityWindow?.activityLabel?.stringValue = message
    activityWindow?.activityLabel?.textColor = color
    activityWindow?.refreshPermissions()
}

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
// Count only this process's registrations, without reading keyboard events.
// This runs outside the input/UI path and records no dictated text.
func logKeyboardResources(_ context: String) {
    diagnosticQueue.async {
        var count: UInt32 = 0
        var result = CGGetEventTapList(0, nil, &count)
        guard result == .success else {
            logDiagnostic("keyboard resources \(context): unavailable (\(result.rawValue))")
            return
        }
        let capacity = count + 8
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(capacity))
        result = CGGetEventTapList(capacity, &taps, &count)
        guard result == .success else { return }
        let owned = taps.prefix(min(Int(count), taps.count)).filter { $0.tappingProcess == getpid() }
        logDiagnostic("keyboard resources \(context): owned taps=\(owned.count), enabled=\(owned.filter { $0.enabled }.count)")
    }
}

let externalWhisperBinPath = appSupport + "/bin/whisper-cli"
var bundledWhisperBinPath: String {
    (Bundle.main.resourcePath ?? "") + "/whisper-cli"
}

var whisperBinPath: String {
    FileManager.default.isExecutableFile(atPath: externalWhisperBinPath)
        ? externalWhisperBinPath
        : bundledWhisperBinPath
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
        showActivity("Model or whisper-cli is missing", color: .systemRed)
        statusItem.button?.toolTip = "WhisperMac — Install whisper-cli and download a model in Preferences"
        playSound("Basso")
        return
    }
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
        logDiagnostic("recording unavailable: microphone access not granted")
        showActivity("Allow microphone access in System Settings", color: .systemRed)
        statusItem.button?.toolTip = "WhisperMac — Allow microphone access in System Settings"
        playSound("Basso")
        return
    }

    let url = FileManager.default.temporaryDirectory.appendingPathComponent("whispermac-\(UUID().uuidString).wav")

    guard let recorder = try? AVAudioRecorder(url: url, settings: audioSettings) else {
        logDiagnostic("recording unavailable: AVAudioRecorder could not initialize")
        showActivity("Could not initialize microphone", color: .systemRed)
        playSound("Basso")
        return
    }
    guard recorder.prepareToRecord(), recorder.record() else {
        logDiagnostic("recording unavailable: AVAudioRecorder could not start")
        showActivity("Could not start recording", color: .systemRed)
        playSound("Basso")
        return
    }
    audioRecorder = recorder
    recordingURL = url
    recordingTargetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
    isRecording = true
    logDiagnostic("recording started; target pid=\(recordingTargetPID.map(String.init) ?? "none")")
    showActivity("Recording — release Right ⌘ to transcribe", color: .systemRed)
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
    showActivity("Transcribing…", color: .systemOrange)
    setIcon("arrow.triangle.2.circlepath")
    statusItem.button?.toolTip = "WhisperMac — Transcribing"
    let chosenModelPath = modelPath
    let originalTargetPID = recordingTargetPID
    recordingTargetPID = nil

    DispatchQueue.global(qos: .userInitiated).async {
        let outputBase = FileManager.default.temporaryDirectory.appendingPathComponent("whispermac-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: inputURL)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: outputBase.path + ".txt"))
        }
        var text: String?
        let primaryBinPath = whisperBinPath
        var attempts: [(path: String, forceCPU: Bool)] = [(primaryBinPath, false), (primaryBinPath, true)]
        if primaryBinPath != bundledWhisperBinPath {
            attempts.append((bundledWhisperBinPath, true))
        }
        for attempt in attempts {
            try? FileManager.default.removeItem(atPath: outputBase.path + ".txt")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: attempt.path)
            process.arguments = (attempt.forceCPU ? ["-ng"] : []) + [
                "-t", String(transcriptionThreadCount),
                "-f", inputURL.path, "-m", chosenModelPath,
                "-otxt", "-of", outputBase.path, "-np", "--no-timestamps", "-l", "auto"
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                logDiagnostic("whisper-cli exited with status \(process.terminationStatus); cpu=\(attempt.forceCPU); path=\(attempt.path)")
                if process.terminationStatus == 0 {
                    text = try? String(contentsOfFile: outputBase.path + ".txt", encoding: .utf8)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            } catch {
                logDiagnostic("whisper-cli failed to run at \(attempt.path): \(error.localizedDescription)")
            }
        }

        logKeyboardResources("after transcription")
        DispatchQueue.main.async {
            isTranscribing = false
            if let text = text, !text.isEmpty {
                logDiagnostic("transcription produced text")
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.setString(text, forType: .string) else {
                    logDiagnostic("pasteboard write failed")
                    showActivity("Could not copy transcription", color: .systemRed)
                    playSound("Basso")
                    statusItem.button?.toolTip = "WhisperMac — Could not copy transcription"
                    setIcon("waveform.circle")
                    return
                }

                let focusedPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                let targetPID = focusedPID.flatMap { $0 == getpid() ? nil : $0 } ?? originalTargetPID
                if let targetPID, targetPID != getpid(), postPaste(to: targetPID) {
                    logDiagnostic("paste shortcut sent to focused app pid=\(targetPID)")
                    showActivity("Text sent to the active app", color: .systemGreen)
                    playSound("Glass")
                    statusItem.button?.toolTip = "WhisperMac — Hold Right ⌘ to record"
                } else {
                    logDiagnostic("paste shortcut not sent; focused pid=\(focusedPID.map(String.init) ?? "none"), original pid=\(originalTargetPID.map(String.init) ?? "none"), post access=\(CGPreflightPostEventAccess())")
                    if focusedPID == getpid() {
                        showActivity("Text copied. Select a field in another app before recording.", color: .systemOrange)
                    } else {
                        showActivity("Text copied. Check Accessibility for automatic paste.", color: .systemOrange)
                    }
                    playSound("Basso")
                    statusItem.button?.toolTip = "WhisperMac — Text copied, but automatic paste was blocked"
                }
            } else {
                logDiagnostic("transcription produced no text")
                showActivity("No text recognized", color: .systemRed)
                playSound("Basso")
                statusItem.button?.toolTip = "WhisperMac — Transcription failed or no speech detected"
            }
            if !isRecording { setIcon("waveform.circle") }
        }
    }
}

func postPaste(to pid: pid_t) -> Bool {
    // Post through the HID event stream so the key combination reaches the
    // focused control (including web-based editors), rather than the app's
    // outer process, which can ignore process-targeted keyboard events.
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
        logDiagnostic("paste skipped: target pid=\(pid) is no longer frontmost")
        return false
    }
    let postAccess = CGPreflightPostEventAccess()
    let axAccess = AXIsProcessTrusted()
    guard axAccess else {
        logDiagnostic("paste blocked: Accessibility access is not trusted; post access=\(postAccess)")
        return false
    }
    let source = CGEventSource(stateID: .hidSystemState)
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else { return false }
    down.flags = .maskCommand
    up.flags = .maskCommand
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    logDiagnostic("paste HID events posted; target pid=\(pid); post access=\(postAccess); AX trusted=\(axAccess)")
    return true
}

func handleRightCommand(isDown: Bool, source: String) {
    logDiagnostic("right Command \(isDown ? "pressed" : "released") via \(source)")
    if isDown && isEnabled && !isRecording && !isTranscribing {
        startRecording()
    } else if !isDown && isRecording {
        stopAndTranscribe()
    }
}

func setupKeyboardMonitoring(retry: Bool = false) {
    // Don't discard a queued release while a recording is still in progress.
    guard !isRecording && !isTranscribing else { return }
    if retry { keyboardMonitor.stop() }
    let connected = keyboardMonitor.start()
    logDiagnostic("keyboard monitors connected=\(connected); backend=AppKit")
    logKeyboardResources("setup")
    if connected {
        showActivity("Ready — hold Right ⌘ to record", color: .systemGreen)
        setIcon("waveform.circle")
        statusItem.button?.toolTip = "WhisperMac — Hold Right ⌘ to record"
    } else {
        showActivity("Shortcut unavailable — check Accessibility", color: .systemRed)
        setIcon("exclamationmark.circle")
        statusItem.button?.toolTip = "WhisperMac — Allow Accessibility and retry"
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
    var activityLabel: NSTextField!
    var permissionsLabel: NSTextField!
    var modelPopup: NSPopUpButton!
    var downloadButton: NSButton!
    var progressBar: NSProgressIndicator!
    var statusLabel: NSTextField!
    var enableCheckbox: NSButton!
    var cancelButton: NSButton!
    private var downloadID: UUID?

    func show() {
        if let w = window {
            refreshPermissions()
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 390),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "WhisperMac"
        window.delegate = self
        window.center()

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 390))

        activityLabel = NSTextField(labelWithString: !keyboardMonitor.isConnected
            ? "Shortcut unavailable — check Accessibility"
            : "Ready — hold Right ⌘ to record")
        activityLabel.frame = NSRect(x: 20, y: 349, width: 420, height: 22)
        activityLabel.font = NSFont.boldSystemFont(ofSize: 13)
        activityLabel.textColor = !keyboardMonitor.isConnected ? .systemRed : .systemGreen
        content.addSubview(activityLabel)

        permissionsLabel = NSTextField(labelWithString: "")
        permissionsLabel.frame = NSRect(x: 20, y: 320, width: 420, height: 20)
        permissionsLabel.font = NSFont.systemFont(ofSize: 11)
        permissionsLabel.textColor = .secondaryLabelColor
        content.addSubview(permissionsLabel)

        let retryButton = NSButton(frame: NSRect(x: 20, y: 282, width: 90, height: 28))
        retryButton.title = "Retry"
        retryButton.bezelStyle = .rounded
        retryButton.target = self
        retryButton.action = #selector(retryConnection)
        content.addSubview(retryButton)

        let inputButton = NSButton(frame: NSRect(x: 118, y: 282, width: 150, height: 28))
        inputButton.title = "Input Monitoring"
        inputButton.bezelStyle = .rounded
        inputButton.target = self
        inputButton.action = #selector(openInputMonitoring)
        content.addSubview(inputButton)

        let accessibilityButton = NSButton(frame: NSRect(x: 276, y: 282, width: 164, height: 28))
        accessibilityButton.title = "Accessibility"
        accessibilityButton.bezelStyle = .rounded
        accessibilityButton.target = self
        accessibilityButton.action = #selector(openAccessibility)
        content.addSubview(accessibilityButton)

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
        refreshPermissions()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refreshPermissions() {
        guard let permissionsLabel else { return }
        let keyboard = !keyboardMonitor.isConnected ? "unavailable" : "connected"
        let paste = AXIsProcessTrusted() ? "allowed" : "needs access"
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? "allowed" : "needs access"
        permissionsLabel.stringValue = "Shortcut: \(keyboard)   Paste: \(paste)   Mic: \(microphone)"
    }

    @objc func retryConnection() {
        setupKeyboardMonitoring(retry: true)
        refreshPermissions()
    }

    @objc func openInputMonitoring() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    @objc func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
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
        setupKeyboardMonitoring(retry: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(atPath: modelsDir, withIntermediateDirectories: true, attributes: nil)
        loadPreferences()
        activityWindow = prefs
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        logDiagnostic("app launched; version=\(version) build=\(build) pid=\(getpid()); model=\(selectedModel.filename); Input Monitoring=\(CGPreflightListenEventAccess()); post access=\(CGPreflightPostEventAccess()); microphone=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        if !CGPreflightPostEventAccess() { _ = CGRequestPostEventAccess() }

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

        setupKeyboardMonitoring(retry: true)
        prefs.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        keyboardMonitor.stop()
        audioRecorder?.stop()
        audioRecorder = nil
        if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
        recordingURL = nil
        downloadSession?.cancel()
        downloadSession = nil
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        prefs.show()
        return true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.applicationIconImage = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "WhisperMac")
app.run()
