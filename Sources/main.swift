import AppKit
import AVFoundation
import HotKey
import Accelerate
import ApplicationServices
import Carbon.HIToolbox
import ServiceManagement

let logFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".speakflow.log")
func log(_ msg: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
    print(line, terminator: "")
    fflush(stdout)
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logFile.path) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: logFile)
        }
    }
}

struct Config {
    // Audio chunking - more conservative
    static let minChunkDuration: Double = 5.0      // Minimum 5s of audio to send
    static let maxChunkDuration: Double = 60.0     // Max 60s before forced send
    static let silenceThreshold: Float = 0.003
    static let silenceDuration: Double = 2.0       // Wait 2s of silence
    static let minSpeechRatio: Float = 0.03

    // API - conservative to avoid rate limits
    static let minTimeBetweenRequests: Double = 10.0  // At least 10s between API calls
    static let timeout: Double = 30.0                  // 30s timeout
    static let maxRetries: Int = 2                     // Only 2 retries
    static let retryBaseDelay: Double = 5.0           // Start with 5s delay
}

// MARK: - Hotkey Settings
enum HotkeyType: String, CaseIterable {
    case doubleTapControl = "doubleTapControl"
    case controlOptionD = "controlOptionD"
    case controlOptionSpace = "controlOptionSpace"
    case commandShiftD = "commandShiftD"

    var displayName: String {
        switch self {
        case .doubleTapControl: return "⌃⌃ (double-tap)"
        case .controlOptionD: return "⌃⌥D"
        case .controlOptionSpace: return "⌃⌥Space"
        case .commandShiftD: return "⇧⌘D"
        }
    }
}

class HotkeySettings {
    static let shared = HotkeySettings()

    private let defaultsKey = "activationHotkey"

    var currentHotkey: HotkeyType {
        get {
            if let raw = UserDefaults.standard.string(forKey: defaultsKey),
               let type = HotkeyType(rawValue: raw) {
                return type
            }
            return .doubleTapControl  // Default
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            log("⌨️ Hotkey changed to: \(newValue.displayName)")
        }
    }
}

// MARK: - Double-Tap Control Key Detector
class DoubleTapControlDetector {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastControlKeyReleaseTime: Date?
    private var controlWasDown = false
    private let doubleTapInterval: TimeInterval = 0.4

    var onDoubleTap: (() -> Void)?

    func start() {
        guard eventTap == nil else { return }

        let eventMask = (1 << CGEventType.flagsChanged.rawValue)

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passRetained(event) }
                let detector = Unmanaged<DoubleTapControlDetector>.fromOpaque(refcon).takeUnretainedValue()
                detector.handleFlagsChanged(event: event)
                return Unmanaged.passRetained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap = eventTap else {
            log("❌ Could not create event tap for Control key detection (need Accessibility permission)")
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        guard let source = runLoopSource else { return }

        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        log("✅ Double-tap Control detector started")
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func handleFlagsChanged(event: CGEvent) {
        let flags = event.flags
        let controlDown = flags.contains(.maskControl)

        // Only trigger on Control alone (no other modifiers)
        let hasOtherModifiers = flags.contains(.maskCommand) ||
                                flags.contains(.maskAlternate) ||
                                flags.contains(.maskShift)

        // Detect Control key release (was down, now up) with no other modifiers
        if controlWasDown && !controlDown && !hasOtherModifiers {
            let now = Date()
            if let lastRelease = lastControlKeyReleaseTime,
               now.timeIntervalSince(lastRelease) < doubleTapInterval {
                // Double-tap detected!
                lastControlKeyReleaseTime = nil
                DispatchQueue.main.async { [weak self] in
                    self?.onDoubleTap?()
                }
            } else {
                lastControlKeyReleaseTime = now
            }
        }

        controlWasDown = controlDown
    }

    deinit {
        stop()
    }
}

// MARK: - Rate Limiter
class RateLimiter {
    private var lastRequestTime: Date?
    private let lock = NSLock()
    
    func canMakeRequest() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        guard let last = lastRequestTime else { return true }
        return Date().timeIntervalSince(last) >= Config.minTimeBetweenRequests
    }
    
    func recordRequest() {
        lock.lock()
        lastRequestTime = Date()
        lock.unlock()
    }
    
    func timeUntilNextAllowed() -> Double {
        lock.lock()
        defer { lock.unlock() }
        
        guard let last = lastRequestTime else { return 0 }
        let elapsed = Date().timeIntervalSince(last)
        return max(0, Config.minTimeBetweenRequests - elapsed)
    }
}

// MARK: - Transcription Queue (ordered results)
class TranscriptionQueue {
    private var pendingResults: [Int: String] = [:]
    private var nextSeqToOutput: Int = 0
    private var currentSeq: Int = 0
    private let lock = NSLock()
    let rateLimiter = RateLimiter()
    
    var onTextReady: ((String) -> Void)?
    var onAllComplete: (() -> Void)?
    
    func reset() {
        lock.lock()
        pendingResults.removeAll()
        nextSeqToOutput = 0
        currentSeq = 0
        lock.unlock()
    }
    
    func nextSequence() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let seq = currentSeq
        currentSeq += 1
        return seq
    }
    
    func getPendingCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return currentSeq - nextSeqToOutput
    }
    
    func submitResult(seq: Int, text: String) {
        lock.lock()
        pendingResults[seq] = text
        lock.unlock()
        flushReady()
    }
    
    func markFailed(seq: Int) {
        lock.lock()
        pendingResults[seq] = ""
        lock.unlock()
        flushReady()
    }
    
    private func flushReady() {
        lock.lock()
        var textsToOutput: [String] = []
        
        while let text = pendingResults[nextSeqToOutput] {
            pendingResults.removeValue(forKey: nextSeqToOutput)
            if !text.isEmpty { textsToOutput.append(text) }
            nextSeqToOutput += 1
        }
        
        let allDone = pendingResults.isEmpty && currentSeq == nextSeqToOutput
        lock.unlock()
        
        for text in textsToOutput {
            log("📝 Output: \"\(text)\"")
            onTextReady?(text)
        }
        
        if allDone { onAllComplete?() }
    }
}

// MARK: - Transcription with Rate Limiting
class Transcription {
    static let shared = Transcription()
    let queue = TranscriptionQueue()
    private var pendingAudioChunks: [(seq: Int, audio: Data, attempt: Int)] = []
    private var isProcessing = false
    
    func transcribe(seq: Int, audio: Data) {
        pendingAudioChunks.append((seq, audio, 1))
        processNextIfReady()
    }
    
    private func processNextIfReady() {
        guard !isProcessing, !pendingAudioChunks.isEmpty else { return }
        
        let waitTime = queue.rateLimiter.timeUntilNextAllowed()
        if waitTime > 0 {
            log("⏳ Rate limit: waiting \(String(format: "%.1f", waitTime))s")
            DispatchQueue.main.asyncAfter(deadline: .now() + waitTime) { [weak self] in
                self?.processNextIfReady()
            }
            return
        }
        
        isProcessing = true
        let chunk = pendingAudioChunks.removeFirst()
        queue.rateLimiter.recordRequest()
        
        log("📤 #\(chunk.seq) attempt \(chunk.attempt) (timeout: \(Config.timeout)s)")
        
        makeRequest(audio: chunk.audio) { [weak self] result in
            guard let self = self else { return }
            self.isProcessing = false
            
            switch result {
            case .success(let text):
                log("✅ #\(chunk.seq): \"\(text)\"")
                self.queue.submitResult(seq: chunk.seq, text: text)
                
            case .failure(let error):
                log("❌ #\(chunk.seq): \(error.localizedDescription)")
                
                if chunk.attempt < Config.maxRetries {
                    let delay = Config.retryBaseDelay * pow(2.0, Double(chunk.attempt - 1))
                    log("🔄 #\(chunk.seq) retry in \(delay)s...")
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        self.pendingAudioChunks.insert((chunk.seq, chunk.audio, chunk.attempt + 1), at: 0)
                        self.processNextIfReady()
                    }
                    return
                } else {
                    log("💀 #\(chunk.seq) gave up")
                    self.queue.markFailed(seq: chunk.seq)
                }
            }
            
            self.processNextIfReady()
        }
    }
    
    private func makeRequest(audio: Data, completion: @escaping (Result<String, Error>) -> Void) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let ad = try? Data(contentsOf: home.appendingPathComponent(".codex/auth.json")),
              let j = try? JSONSerialization.jsonObject(with: ad) as? [String: Any],
              let tk = j["tokens"] as? [String: Any],
              let t = tk["access_token"] as? String,
              let a = tk["account_id"] as? String else {
            completion(.failure(NSError(domain: "", code: 1, userInfo: [NSLocalizedDescriptionKey: "Auth failed"])))
            return
        }
        
        let ck = Cookies.load()
        let bd = "----\(UUID())"
        var rq = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/transcribe")!)
        rq.httpMethod = "POST"
        rq.timeoutInterval = Config.timeout
        rq.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        rq.setValue(a, forHTTPHeaderField: "ChatGPT-Account-Id")
        rq.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        rq.setValue("Codex Desktop/260202.0859 (darwin; arm64)", forHTTPHeaderField: "User-Agent")
        rq.setValue("multipart/form-data; boundary=\(bd)", forHTTPHeaderField: "Content-Type")
        if !ck.isEmpty { rq.setValue(ck.map { "\($0.key)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie") }
        
        var by = "--\(bd)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!
        by.append(audio)
        by.append("\r\n--\(bd)--\r\n".data(using: .utf8)!)
        rq.httpBody = by
        
        URLSession.shared.dataTask(with: rq) { d, _, e in
            DispatchQueue.main.async {
                if let e = e { completion(.failure(e)); return }
                guard let d = d,
                      let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let x = j["text"] as? String else {
                    let errorMsg = d.flatMap { String(data: $0, encoding: .utf8) } ?? "Bad response"
                    completion(.failure(NSError(domain: "", code: 2, userInfo: [NSLocalizedDescriptionKey: errorMsg])))
                    return
                }
                completion(.success(x))
            }
        }.resume()
    }
}

// MARK: - Streaming Recorder
class StreamingRecorder {
    private var audioEngine: AVAudioEngine?
    private var audioBuffer: [Float] = []
    private var isRecording = false
    private var lastSoundTime: Date = Date()
    private var chunkTimer: Timer?
    private var silenceTimer: Timer?
    private var speechFrameCount: Int = 0
    private var totalFrameCount: Int = 0
    
    var onChunkReady: ((Data) -> Void)?
    private let sampleRate: Double = 16000
    private let bufferLock = NSLock()
    
    func start() {
        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else { return }
        
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return }
        
        audioBuffer = []; isRecording = true; lastSoundTime = Date()
        speechFrameCount = 0; totalFrameCount = 0
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self, self.isRecording else { return }
            
            let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * self.sampleRate / inputFormat.sampleRate)
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCount) else { return }
            
            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            
            if let channelData = convertedBuffer.floatChannelData?[0] {
                let frames = Int(convertedBuffer.frameLength)
                var rms: Float = 0
                vDSP_rmsqv(channelData, 1, &rms, vDSP_Length(frames))
                
                let hasSpeech = rms > Config.silenceThreshold
                if hasSpeech { self.lastSoundTime = Date() }
                
                self.bufferLock.lock()
                self.audioBuffer.append(contentsOf: UnsafeBufferPointer(start: channelData, count: frames))
                self.totalFrameCount += frames
                if hasSpeech { self.speechFrameCount += frames }
                self.bufferLock.unlock()
            }
        }
        
        do {
            try engine.start()
            log("🎙️ Recording (min \(Config.minChunkDuration)s, max \(Config.maxChunkDuration)s chunks)")
            
            // Check for max duration
            chunkTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.checkMaxDuration()
            }
            
            // Check for silence
            silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.checkSilence()
            }
        } catch { log("❌ \(error)") }
    }
    
    private func checkMaxDuration() {
        bufferLock.lock()
        let duration = Double(audioBuffer.count) / sampleRate
        bufferLock.unlock()
        
        if duration >= Config.maxChunkDuration {
            sendChunkIfReady(reason: "max duration")
        }
    }
    
    private func checkSilence() {
        guard isRecording else { return }
        
        bufferLock.lock()
        let duration = Double(audioBuffer.count) / sampleRate
        bufferLock.unlock()
        
        // Only send on silence if we have minimum duration
        if duration >= Config.minChunkDuration && Date().timeIntervalSince(lastSoundTime) >= Config.silenceDuration {
            sendChunkIfReady(reason: "silence")
        }
    }
    
    private func sendChunkIfReady(reason: String) {
        bufferLock.lock()
        let samples = audioBuffer
        let speech = speechFrameCount
        let total = totalFrameCount
        audioBuffer = []
        speechFrameCount = 0
        totalFrameCount = 0
        bufferLock.unlock()
        
        let duration = Double(samples.count) / sampleRate
        guard duration >= Config.minChunkDuration else {
            log("⏭️ Too short (\(String(format: "%.1f", duration))s < \(Config.minChunkDuration)s)")
            return
        }
        
        let speechRatio = total > 0 ? Float(speech) / Float(total) : 0
        if speechRatio < Config.minSpeechRatio {
            log("⏭️ Skip silent (\(String(format: "%.0f", speechRatio * 100))%)")
            return
        }
        
        log("🎤 Chunk (\(reason)): \(String(format: "%.1f", duration))s, \(String(format: "%.0f", speechRatio * 100))% speech")
        onChunkReady?(createWav(from: samples))
        lastSoundTime = Date()
    }
    
    func stop() {
        isRecording = false
        chunkTimer?.invalidate()
        silenceTimer?.invalidate()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        
        bufferLock.lock()
        let samples = audioBuffer
        let speech = speechFrameCount
        let total = totalFrameCount
        audioBuffer = []
        bufferLock.unlock()
        
        let duration = Double(samples.count) / sampleRate
        let speechRatio = total > 0 ? Float(speech) / Float(total) : 0
        
        // On stop, send whatever we have (if it has speech)
        if duration >= 1.0 && speechRatio >= Config.minSpeechRatio {
            log("🎤 Final chunk: \(String(format: "%.1f", duration))s")
            onChunkReady?(createWav(from: samples))
        }
        log("⏹️ Stopped")
    }
    
    private func createWav(from samples: [Float]) -> Data {
        let int16 = samples.map { Int16(max(-1, min(1, $0)) * 32767) }
        var wav = Data()
        let sr = UInt32(sampleRate), sz = UInt32(int16.count * 2)
        wav.append(contentsOf: "RIFF".utf8)
        wav.append(withUnsafeBytes(of: (36 + sz).littleEndian) { Data($0) })
        wav.append(contentsOf: "WAVEfmt ".utf8)
        wav.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
        wav.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
        wav.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
        wav.append(withUnsafeBytes(of: sr.littleEndian) { Data($0) })
        wav.append(withUnsafeBytes(of: (sr * 2).littleEndian) { Data($0) })
        wav.append(withUnsafeBytes(of: UInt16(2).littleEndian) { Data($0) })
        wav.append(withUnsafeBytes(of: UInt16(16).littleEndian) { Data($0) })
        wav.append(contentsOf: "data".utf8)
        wav.append(withUnsafeBytes(of: sz.littleEndian) { Data($0) })
        int16.forEach { wav.append(withUnsafeBytes(of: $0.littleEndian) { Data($0) }) }
        return wav
    }
}

// MARK: - Accessibility Permission Manager
class AccessibilityPermissionManager {
    private var permissionCheckTimer: Timer?
    private var hasShownInitialPrompt = false
    weak var delegate: AppDelegate?
    
    func checkAndRequestPermission(showAlertIfNeeded: Bool = true, isAppStart: Bool = false) -> Bool {
        // Use AXIsProcessTrustedWithOptions to automatically add app to the list
        // and trigger system prompt on first call
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: !hasShownInitialPrompt] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        
        if !hasShownInitialPrompt {
            hasShownInitialPrompt = true
            if !trusted {
                log("🔔 App added to Accessibility list, system prompt shown")
            }
        }
        
        // On app start, ALWAYS show alert if permission is not granted
        // On other calls, only show if showAlertIfNeeded is true
        let shouldShowAlert = !trusted && (isAppStart || showAlertIfNeeded)
        
        if shouldShowAlert {
            // Show our detailed alert after a brief delay to let system prompt appear/dismiss
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.showPermissionAlert()
                self?.startPollingForPermission()
            }
        }
        
        return trusted
    }
    
    private func showPermissionAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Enable Accessibility Access"
            alert.informativeText = """
            This app needs Accessibility permission to type dictated text into other applications.
            
            We've already added this app to your Accessibility settings.
            
            To enable it:
            1. Click "Open System Settings" below
            2. Find this app in the Accessibility list (already added for you)
            3. Click the toggle switch to turn it ON
            4. Return to this app — we'll automatically detect when you enable it
            
            💡 You may need to unlock the settings with your password first.
            """
            alert.alertStyle = .informational
            alert.icon = NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: "Permission")
            
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Remind Me Later")
            alert.addButton(withTitle: "Quit App")
            
            let response = alert.runModal()
            
            switch response {
            case .alertFirstButtonReturn: // Open System Settings
                self.openAccessibilitySettings()
                
            case .alertSecondButtonReturn: // Remind Me Later
                log("⏰ User postponed accessibility permission")
                
            case .alertThirdButtonReturn: // Quit
                log("👋 User chose to quit")
                NSApp.terminate(nil)
                
            default:
                break
            }
        }
    }
    
    private func openAccessibilitySettings() {
        // Modern macOS (Ventura 13.0+): Use new URL scheme
        if #available(macOS 13.0, *) {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
        } else {
            // Legacy macOS (Big Sur 11.0 - Monterey 12.x): Old URL scheme
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
        }
        
        log("🔓 Opened System Settings > Privacy & Security > Accessibility")
    }
    
    private func startPollingForPermission() {
        // Stop any existing timer
        permissionCheckTimer?.invalidate()
        
        // Check every 2 seconds if permission has been granted
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            
            let trusted = AXIsProcessTrusted()
            if trusted {
                log("✅ Accessibility permission granted!")
                timer.invalidate()
                self.permissionCheckTimer = nil

                // Update UI
                self.delegate?.updateStatusIcon()

                // Re-setup hotkey now that we have permission (needed for fn key detection)
                self.delegate?.setupHotkey()

                // Show confirmation
                self.showPermissionGrantedAlert()
            }
        }
    }
    
    private func showPermissionGrantedAlert() {
        let hotkeyName = HotkeySettings.shared.currentHotkey.displayName
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Accessibility Permission Granted"
            alert.informativeText = """
            The app now has permission to insert dictated text into other applications.

            You can start using the dictation feature with \(hotkeyName).
            """
            alert.alertStyle = .informational
            alert.icon = NSImage(systemSymbolName: "checkmark.shield", accessibilityDescription: "Success")

            alert.addButton(withTitle: "OK")

            alert.runModal()
        }
    }
    
    func stopPolling() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
    }
    
    deinit {
        stopPolling()
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var hotKey: HotKey?
    var controlDetector: DoubleTapControlDetector?
    var recorder: StreamingRecorder?
    var isRecording = false
    var isProcessingFinal = false  // Track if we're waiting for final transcriptions
    var fullTranscript = ""
    var permissionManager: AccessibilityPermissionManager!
    var targetElement: AXUIElement?  // Store focused element when recording starts

    // Menu bar icons
    private lazy var defaultIcon: NSImage? = loadMenuBarIcon()
    private lazy var warningIcon: NSImage? = createWarningIcon()
    
    func applicationDidFinishLaunching(_ n: Notification) {
        // Set up permission manager
        permissionManager = AccessibilityPermissionManager()
        permissionManager.delegate = self
        
        // Check accessibility permission - ALWAYS show alert on app start if not granted
        let trusted = permissionManager.checkAndRequestPermission(showAlertIfNeeded: true, isAppStart: true)
        log("AXIsProcessTrusted: \(trusted)")
        
        if !trusted {
            log("⚠️ No Accessibility permission - showing permission request...")
        } else {
            log("✅ Accessibility permission granted")
        }
        
        let hotkeyName = HotkeySettings.shared.currentHotkey.displayName
        log("SpeakFlow ready - \(hotkeyName)")
        log("Config: min=\(Config.minChunkDuration)s, max=\(Config.maxChunkDuration)s, rate=\(Config.minTimeBetweenRequests)s")
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()

        buildMenu(trusted: trusted)
        setupHotkey()
        
        Transcription.shared.queue.onTextReady = { [weak self] text in
            guard let self = self else { return }
            if !self.fullTranscript.isEmpty { self.fullTranscript += " " }
            self.fullTranscript += text
            // Insert text during recording AND while processing final chunks
            if self.isRecording || self.isProcessingFinal {
                self.insertText(text + " ")
            }
        }
        
        Transcription.shared.queue.onAllComplete = { [weak self] in
            self?.finishIfDone()
        }
        
        // Check and request microphone permission on startup
        checkMicrophonePermission()

        NSApp.setActivationPolicy(.accessory)
        
        // Check permission when app becomes active
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }
    
    @objc func applicationDidBecomeActive(_ notification: Notification) {
        // Check if we're the activated app
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == Bundle.main.bundleIdentifier else {
            return
        }

        // Re-check accessibility permission (without showing alert)
        let trusted = AXIsProcessTrusted()
        updateStatusIcon()
        updateMenu(trusted: trusted)
    }

    private func buildMenu(trusted: Bool) {
        let menu = NSMenu()

        let hotkeyName = HotkeySettings.shared.currentHotkey.displayName
        menu.addItem(NSMenuItem(title: "Start Dictation (\(hotkeyName))", action: #selector(toggle), keyEquivalent: ""))
        menu.addItem(.separator())

        // Add accessibility status menu item
        let accessibilityItem = NSMenuItem(title: trusted ? "✅ Accessibility Enabled" : "⚠️ Enable Accessibility...", action: #selector(checkAccessibility), keyEquivalent: "")
        menu.addItem(accessibilityItem)

        // Add microphone status menu item
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let micTitle = micStatus == .authorized ? "✅ Microphone Enabled" : "⚠️ Enable Microphone..."
        let micItem = NSMenuItem(title: micTitle, action: #selector(checkMicrophoneAction), keyEquivalent: "")
        menu.addItem(micItem)
        menu.addItem(.separator())

        // Hotkey submenu
        let hotkeySubmenu = NSMenu()
        for type in HotkeyType.allCases {
            let item = NSMenuItem(title: type.displayName, action: #selector(changeHotkey(_:)), keyEquivalent: "")
            item.representedObject = type
            item.state = (type == HotkeySettings.shared.currentHotkey) ? .on : .off
            hotkeySubmenu.addItem(item)
        }

        let hotkeyMenuItem = NSMenuItem(title: "Activation Hotkey", action: nil, keyEquivalent: "")
        hotkeyMenuItem.submenu = hotkeySubmenu
        menu.addItem(hotkeyMenuItem)

        // Launch at Login toggle
        let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launchAtLoginItem.state = isLaunchAtLoginEnabled() ? .on : .off
        menu.addItem(launchAtLoginItem)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func isLaunchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                    sender.state = .off
                    log("🚀 Disabled launch at login")
                } else {
                    try SMAppService.mainApp.register()
                    sender.state = .on
                    log("🚀 Enabled launch at login")
                }
            } catch {
                log("❌ Failed to toggle launch at login: \(error)")
            }
        }
    }

    @objc private func changeHotkey(_ sender: NSMenuItem) {
        guard let newType = sender.representedObject as? HotkeyType else { return }

        HotkeySettings.shared.currentHotkey = newType
        setupHotkey()

        // Rebuild menu to update checkmarks and hotkey display
        let trusted = AXIsProcessTrusted()
        buildMenu(trusted: trusted)
    }

    func setupHotkey() {
        // Disable previous hotkey handlers
        hotKey = nil
        controlDetector?.stop()
        controlDetector = nil

        let type = HotkeySettings.shared.currentHotkey

        switch type {
        case .doubleTapControl:
            controlDetector = DoubleTapControlDetector()
            controlDetector?.onDoubleTap = { [weak self] in self?.toggle() }
            controlDetector?.start()
            log("⌨️ Using double-tap Control activation")

        case .controlOptionD:
            hotKey = HotKey(key: .d, modifiers: [.control, .option])
            hotKey?.keyDownHandler = { [weak self] in self?.toggle() }
            log("⌨️ Using ⌃⌥D activation")

        case .controlOptionSpace:
            hotKey = HotKey(key: .space, modifiers: [.control, .option])
            hotKey?.keyDownHandler = { [weak self] in self?.toggle() }
            log("⌨️ Using ⌃⌥Space activation")

        case .commandShiftD:
            hotKey = HotKey(key: .d, modifiers: [.command, .shift])
            hotKey?.keyDownHandler = { [weak self] in self?.toggle() }
            log("⌨️ Using ⇧⌘D activation")
        }
    }
    
    func updateStatusIcon() {
        let accessibilityOK = AXIsProcessTrusted()
        let microphoneOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

        statusItem.button?.title = ""

        if !accessibilityOK || !microphoneOK {
            statusItem.button?.image = warningIcon
        } else {
            statusItem.button?.image = defaultIcon
        }
    }

    private func loadMenuBarIcon() -> NSImage? {
        guard let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            log("⚠️ Could not load AppIcon.png from bundle")
            return nil
        }

        // Menu bar icons should be 18x18 to match system icons
        let menuBarSize = NSSize(width: 18, height: 18)
        let resizedImage = NSImage(size: menuBarSize)
        resizedImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: menuBarSize),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy,
                   fraction: 1.0)
        resizedImage.unlockFocus()

        // Template mode makes icon white in dark mode, black in light mode
        resizedImage.isTemplate = true
        return resizedImage
    }

    private func createWarningIcon() -> NSImage? {
        if let icon = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning") {
            let size = NSSize(width: 18, height: 18)
            let resized = NSImage(size: size)
            resized.lockFocus()
            icon.draw(in: NSRect(origin: .zero, size: size),
                      from: NSRect(origin: .zero, size: icon.size),
                      operation: .copy,
                      fraction: 1.0)
            resized.unlockFocus()
            return resized
        }
        return nil
    }

    
    private func updateMenu(trusted: Bool) {
        // Rebuild entire menu to ensure proper state
        buildMenu(trusted: trusted)
    }
    
    @objc func checkAccessibility() {
        let trusted = permissionManager.checkAndRequestPermission(showAlertIfNeeded: true)
        if trusted {
            let alert = NSAlert()
            alert.messageText = "Accessibility Permission Active"
            alert.informativeText = "The app has the necessary permissions to insert dictated text."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc func checkMicrophoneAction() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .authorized {
            let alert = NSAlert()
            alert.messageText = "Microphone Permission Active"
            alert.informativeText = "The app has access to your microphone for voice recording."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        } else {
            checkMicrophonePermission()
        }
    }
    
    @objc func toggle() { if isRecording { stopRecording() } else { startRecording() } }
    
    func startRecording() {
        guard !isRecording else { return }

        // Check accessibility permission before starting
        if !AXIsProcessTrusted() {
            log("⚠️ Cannot start recording - accessibility permission required")
            NSSound(named: "Basso")?.play()
            _ = permissionManager.checkAndRequestPermission(showAlertIfNeeded: true)
            return
        }

        // Check microphone permission before starting
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break // Permission granted, continue
        case .notDetermined:
            log("⚠️ Microphone permission not yet requested")
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.startRecording() // Retry after permission granted
                    } else {
                        self?.showMicrophonePermissionAlert()
                    }
                }
            }
            return
        case .denied, .restricted:
            log("⚠️ Microphone permission denied")
            NSSound(named: "Basso")?.play()
            showMicrophonePermissionAlert()
            return
        @unknown default:
            log("⚠️ Unknown microphone permission status")
            return
        }

        isRecording = true
        isProcessingFinal = false  // Reset in case of previous session
        fullTranscript = ""
        Transcription.shared.queue.reset()

        // Capture the focused element NOW so we can insert text there later
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?
        if AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success {
            targetElement = (focusedElement as! AXUIElement)

            // Log element info for debugging
            var role: AnyObject?
            var title: AnyObject?
            AXUIElementCopyAttributeValue(targetElement!, kAXRoleAttribute as CFString, &role)
            AXUIElementCopyAttributeValue(targetElement!, kAXTitleAttribute as CFString, &title)
            log("🎯 Captured target: role=\(role ?? "?" as AnyObject), title=\(title ?? "?" as AnyObject)")
        } else {
            targetElement = nil
            log("⚠️ Could not capture focused element")
        }

        updateStatusIcon()
        NSSound(named: "Pop")?.play()

        recorder = StreamingRecorder()
        recorder?.onChunkReady = { data in
            let seq = Transcription.shared.queue.nextSequence()
            Transcription.shared.transcribe(seq: seq, audio: data)
        }
        recorder?.start()
    }

    private var micPermissionTimer: Timer?

    private func checkMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            log("✅ Microphone permission granted")
            micPermissionTimer?.invalidate()
            micPermissionTimer = nil
            updateStatusIcon()
            updateMenu(trusted: AXIsProcessTrusted())
        case .notDetermined:
            log("🔔 Requesting microphone permission...")
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        log("✅ Microphone permission granted")
                        self?.updateStatusIcon()
                        self?.updateMenu(trusted: AXIsProcessTrusted())
                    } else {
                        log("⚠️ Microphone permission denied by user")
                        self?.showMicrophonePermissionAlert()
                        self?.startMicrophonePermissionPolling()
                    }
                }
            }
            // Also start polling in case callback doesn't fire
            startMicrophonePermissionPolling()
        case .denied, .restricted:
            log("⚠️ Microphone permission denied - showing alert")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showMicrophonePermissionAlert()
            }
            startMicrophonePermissionPolling()
        @unknown default:
            log("⚠️ Unknown microphone permission status")
        }
    }

    private func startMicrophonePermissionPolling() {
        micPermissionTimer?.invalidate()
        micPermissionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            if status == .authorized {
                log("✅ Microphone permission granted (detected via polling)")
                timer.invalidate()
                self?.micPermissionTimer = nil
                self?.updateStatusIcon()
                self?.updateMenu(trusted: AXIsProcessTrusted())
            }
        }
    }

    private func showMicrophonePermissionAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Microphone Access Required"
            alert.informativeText = """
            This app needs microphone permission to record your voice for transcription.

            To enable it:
            1. Open System Settings > Privacy & Security > Microphone
            2. Find this app and enable the toggle
            3. Try recording again

            💡 You may need to restart the app after changing permissions.
            """
            alert.alertStyle = .warning
            alert.icon = NSImage(systemSymbolName: "mic.slash.fill", accessibilityDescription: "Microphone Denied")

            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "OK")

            let response = alert.runModal()

            if response == .alertFirstButtonReturn {
                // Open Privacy & Security > Microphone
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
    
    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        isProcessingFinal = true  // Keep inserting text while waiting for final transcriptions
        updateStatusIcon()
        NSSound(named: "Blow")?.play()
        recorder?.stop()
        recorder = nil

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.finishIfDone()
        }
    }
    
    func finishIfDone() {
        guard !isRecording else { return }

        let pending = Transcription.shared.queue.getPendingCount()
        if pending > 0 {
            log("⏳ Waiting for \(pending) pending...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.finishIfDone()
            }
            return
        }

        // All transcriptions complete, stop processing mode
        isProcessingFinal = false
        targetElement = nil  // Clear stored element
        updateStatusIcon()
        guard !fullTranscript.isEmpty else { return }

        log("📝 Final transcript: \"\(fullTranscript)\"")
        NSSound(named: "Glass")?.play()
    }
    
    func insertText(_ text: String) {
        log("📋 Insert: \"\(text)\"")
        // Use CGEvent typing - most reliable method that works across all apps
        typeText(text)
        log("✅ Typed via CGEvent")
    }
    
    func typeText(_ text: String) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            log("❌ Could not create CGEventSource")
            return
        }

        for char in text {
            var unichar = Array(String(char).utf16)

            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                log("❌ Could not create CGEvent for char: \(char)")
                continue
            }

            keyDown.keyboardSetUnicodeString(stringLength: unichar.count, unicodeString: &unichar)
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)

            usleep(5000)  // 5ms delay between keystrokes
        }
    }
    
    @objc func quit() { NSApp.terminate(nil) }
}

// MARK: - Cookies
struct Cookies {
    static func load() -> [String: String] {
        var c = [String: String]()
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/HTTPStorages/com.openai.chat.binarycookies")
        guard let d = try? Data(contentsOf: url), d.count > 8 else { return c }

        // Verify magic header "cook"
        guard d[0..<4].elementsEqual("cook".utf8) else { return c }

        // Safe read helper
        func readUInt32BE(at offset: Int) -> UInt32? {
            guard offset >= 0, offset + 4 <= d.count else { return nil }
            return d[offset..<offset+4].withUnsafeBytes { ptr in
                guard ptr.count >= 4 else { return nil }
                return ptr.loadUnaligned(as: UInt32.self).bigEndian
            }
        }

        func readUInt32LE(at offset: Int) -> UInt32? {
            guard offset >= 0, offset + 4 <= d.count else { return nil }
            return d[offset..<offset+4].withUnsafeBytes { ptr in
                guard ptr.count >= 4 else { return nil }
                return ptr.loadUnaligned(as: UInt32.self).littleEndian
            }
        }

        guard let numPages = readUInt32BE(at: 4) else { return c }

        var offset = 8
        var pageSizes: [Int] = []

        for _ in 0..<numPages {
            guard let size = readUInt32BE(at: offset) else { break }
            pageSizes.append(Int(size))
            offset += 4
        }

        for pageSize in pageSizes {
            guard offset + pageSize <= d.count else { break }
            let pageData = d[offset..<offset+pageSize]
            let pageStart = pageData.startIndex

            // Check page header
            guard pageData.count > 8 else { offset += pageSize; continue }
            guard pageData[pageStart..<pageStart+4].elementsEqual([0, 0, 1, 0]) else { offset += pageSize; continue }

            guard let numCookies = readUInt32LE(at: offset + 4) else { offset += pageSize; continue }

            var cookieOffset = 8
            for _ in 0..<numCookies {
                guard cookieOffset + 4 <= pageSize else { break }
                guard let cookieStart = readUInt32LE(at: offset + cookieOffset) else { break }
                cookieOffset += 4

                let cookieBase = offset + Int(cookieStart)
                guard cookieBase + 48 <= d.count else { continue }

                // Read string offsets from cookie record
                guard let domainOffset = readUInt32LE(at: cookieBase + 16),
                      let nameOffset = readUInt32LE(at: cookieBase + 20),
                      let valueOffset = readUInt32LE(at: cookieBase + 28) else { continue }

                func readString(at strOffset: UInt32) -> String? {
                    let pos = cookieBase + Int(strOffset)
                    guard pos >= 0, pos < d.count else { return nil }
                    var end = pos
                    while end < d.count && d[end] != 0 { end += 1 }
                    guard end > pos else { return nil }
                    return String(data: d[pos..<end], encoding: .utf8)
                }

                if let domain = readString(at: domainOffset),
                   let name = readString(at: nameOffset),
                   let value = readString(at: valueOffset),
                   domain.contains("chatgpt.com") {
                    c[name] = value
                }
            }
            offset += pageSize
        }
        return c
    }
}

let appDelegate = AppDelegate()
NSApplication.shared.delegate = appDelegate
NSApplication.shared.setActivationPolicy(.regular)
NSApplication.shared.run()
