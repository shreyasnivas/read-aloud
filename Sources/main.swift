// Remote: press a hotkey, point at something on screen, ask out loud,
// hear Claude's answer.
//
// Flow: hotkey -> capture every display -> frozen overlay you can scribble on,
// while the mic records and transcribes on-device -> hotkey or Return -> ask
// Claude with the screenshots and transcript -> speak the answer with the
// system voice.
//
// Remote is self-contained and is the system of record: every request is
// saved in its own history (the newest three are kept).

import AppKit
import AVFoundation
import Carbon.HIToolbox
import ScreenCaptureKit
import ServiceManagement
import Speech
import SwiftUI

// MARK: - Config

enum Config {
    static let appName = "Remote"
    static let historyLimit = 3
    // Hotkey: Option+Shift+A.
    static let hotKeyCode = UInt32(kVK_ANSI_A)
    static let hotKeyModifiers = UInt32(optionKey | shiftKey)
    static let hotKeyLabel = "⌥⇧A"
    static let model = "claude-opus-5"
    static let maxImageEdge: CGFloat = 1568

    static var supportDir: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appName, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var historyDir: URL {
        let u = supportDir.appendingPathComponent("history", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

func log(_ s: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(s)\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Remote.log")
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Global hotkey (Carbon)

/// A global hotkey. Several can be registered; each gets its own id.
final class HotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var installed = false

    init(keyCode: UInt32, modifiers: UInt32, onPress: @escaping () -> Void) {
        id = HotKey.nextID; HotKey.nextID += 1
        HotKey.handlers[id] = onPress
        if !HotKey.installed {
            HotKey.installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                let fire = HotKey.handlers[hk.id]
                DispatchQueue.main.async { fire?() }
                return noErr
            }, 1, &spec, nil, nil)
        }
        let hkID = EventHotKeyID(signature: OSType(0x52414C44), id: id) // 'RALD'
        let status = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { log("hotkey \(keyCode) registration failed: \(status)") }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.handlers[id] = nil
    }
}

/// Makes Esc stop any speech, system-wide, but only while something is being
/// spoken: Remote's own answers or a terminal `/readback` (via its pid file).
/// Holding Esc only while speaking means Esc works normally the rest of the time.
@MainActor
final class EscapeToStop {
    private var hotKey: HotKey?
    private var timer: Timer?
    private let isAppSpeaking: () -> Bool
    private let stopApp: () -> Void
    static let readbackPID = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cache/readback/say.pid")

    init(isAppSpeaking: @escaping () -> Bool, stopApp: @escaping () -> Void) {
        self.isAppSpeaking = isAppSpeaking
        self.stopApp = stopApp
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    static func readbackSpeakingPID() -> pid_t? {
        guard let s = try? String(contentsOf: readbackPID, encoding: .utf8),
              let pid = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0,
              kill(pid, 0) == 0 else { return nil }
        return pid
    }

    private func tick() {
        let speaking = isAppSpeaking() || EscapeToStop.readbackSpeakingPID() != nil
        if speaking && hotKey == nil {
            hotKey = HotKey(keyCode: UInt32(kVK_Escape), modifiers: 0) { [weak self] in
                MainActor.assumeIsolated { self?.stopAll() }
            }
        } else if !speaking && hotKey != nil {
            hotKey = nil
        }
    }

    func stopAll() {
        stopApp()
        if let pid = EscapeToStop.readbackSpeakingPID() { kill(pid, SIGTERM) }
        try? FileManager.default.removeItem(at: EscapeToStop.readbackPID)
        hotKey = nil
        log("Esc: stopped speech")
    }
}

// MARK: - Transcription (on-device, Apple Speech)

/// Records the mic and transcribes it on the Mac as you talk.
final class Transcriber {
    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finished: ((String) -> Void)?
    private(set) var text = ""
    var onPartial: ((String) -> Void)?

    static func requestPermissions() async -> String? {
        let speech = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard speech == .authorized else { return "Speech Recognition permission is off for Remote." }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { return "Microphone permission is off for Remote." }
        return nil
    }

    func start() throws {
        cancel()
        guard let recognizer, recognizer.isAvailable else {
            throw NSError(domain: "Remote", code: 10, userInfo: [NSLocalizedDescriptionKey: "Speech recognizer unavailable"])
        }
        text = ""
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result {
                    self.text = result.bestTranscription.formattedString
                    self.onPartial?(self.text)
                }
                if error != nil || result?.isFinal == true { self.finish() }
            }
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buf, _ in req.append(buf) }
        engine.prepare()
        try engine.start()
    }

    /// Stops recording and returns the final transcript (or the latest partial
    /// one if the recognizer doesn't finish within a couple of seconds).
    func stop() async -> String {
        guard request != nil else { return text }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        return await withCheckedContinuation { c in
            finished = { c.resume(returning: $0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.finish() }
        }
    }

    private func finish() {
        let f = finished; finished = nil
        task = nil; request = nil
        f?(text)
    }

    func cancel() {
        if engine.isRunning { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        task?.cancel(); task = nil; request = nil
        let f = finished; finished = nil; f?(text)
    }
}

// MARK: - Screen capture

struct DisplayShot {
    let screen: NSScreen
    let image: CGImage      // native pixels
    let scale: CGFloat      // pixels per point
    var index: Int
}

enum Capture {
    static func allDisplays() async throws -> [DisplayShot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var shots: [DisplayShot] = []
        for d in content.displays {
            guard let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == d.displayID
            }) else { continue }
            let scale = screen.backingScaleFactor
            let cfg = SCStreamConfiguration()
            cfg.width = Int(CGFloat(d.width) * scale)
            cfg.height = Int(CGFloat(d.height) * scale)
            cfg.showsCursor = false
            let filter = SCContentFilter(display: d, excludingWindows: [])
            let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            shots.append(DisplayShot(screen: screen, image: img, scale: scale, index: 0))
        }
        // Main display first, then left to right.
        shots.sort { a, b in
            if a.screen == NSScreen.screens.first { return true }
            if b.screen == NSScreen.screens.first { return false }
            return a.screen.frame.minX < b.screen.frame.minX
        }
        for i in shots.indices { shots[i].index = i + 1 }
        return shots
    }
}

// MARK: - Image composition

enum Compose {
    /// The screenshot with the scribbles and the cursor drawn on, in native pixels.
    static func annotated(_ shot: DisplayShot, strokes: [[CGPoint]], cursor: CGPoint?) -> CGImage? {
        let w = shot.image.width, h = shot.image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(shot.image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Bitmap context and view share a bottom-left origin, so points just scale.
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.setStrokeColor(NSColor.systemRed.cgColor)
        ctx.setLineWidth(6 * shot.scale)
        for s in strokes where s.count > 1 {
            ctx.beginPath()
            ctx.move(to: CGPoint(x: s[0].x * shot.scale, y: s[0].y * shot.scale))
            for p in s.dropFirst() { ctx.addLine(to: CGPoint(x: p.x * shot.scale, y: p.y * shot.scale)) }
            ctx.strokePath()
        }
        if let c = cursor {
            let r = 18 * shot.scale
            ctx.setStrokeColor(NSColor.systemYellow.cgColor)
            ctx.setLineWidth(4 * shot.scale)
            ctx.strokeEllipse(in: CGRect(x: c.x * shot.scale - r, y: c.y * shot.scale - r, width: 2 * r, height: 2 * r))
        }
        return ctx.makeImage()
    }

    /// Bounding box of the scribbles in view points, padded, clamped to the screen.
    static func markedRect(_ strokes: [[CGPoint]], in size: CGSize) -> CGRect? {
        let pts = strokes.flatMap { $0 }
        guard pts.count > 1 else { return nil }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        var r = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        let pad = max(40, max(r.width, r.height) * 0.15)
        r = r.insetBy(dx: -pad, dy: -pad).intersection(CGRect(origin: .zero, size: size))
        return r.width > 20 && r.height > 20 ? r : nil
    }

    static func crop(_ img: CGImage, pointRect r: CGRect, scale: CGFloat) -> CGImage? {
        // CGImage cropping is top-left origin.
        let px = CGRect(x: r.minX * scale, y: CGFloat(img.height) - r.maxY * scale,
                        width: r.width * scale, height: r.height * scale)
        return img.cropping(to: px.integral)
    }

    static func jpeg(_ img: CGImage, maxEdge: CGFloat = Config.maxImageEdge) -> Data? {
        let w = CGFloat(img.width), h = CGFloat(img.height)
        let k = min(1, maxEdge / max(w, h))
        let nw = Int(w * k), nh = Int(h * k)
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        guard let small = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: small).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}

// MARK: - Claude

struct Attachment { let label: String; let file: URL }

enum Claude {
    static let system = """
    You are Remote, a voice assistant on the user's Mac. The user pressed a hotkey, \
    maybe scribbled on their screen, and asked a question out loud. You get screenshots \
    of every display, a transcript of what they said, and the app that was in front.

    How to read the images: red scribbles are the user pointing at what they mean, so \
    loose circles, underlines and arrows are the area of interest. A yellow ring marks \
    where the mouse pointer was. If there is a close-up image, it is the marked area at \
    higher resolution. With no scribbles, work out what they mean from their words, the \
    pointer, and the app in front.

    Your answer will be spoken aloud by text-to-speech, so write for the ear:
    - Plain sentences only: no markdown, lists, headings, code blocks, URLs, or emoji.
    - Answer first. Keep it to about two to four sentences, under sixty words, unless they ask for detail or a walkthrough.
    - Say identifiers, paths and numbers the way a person would say them.
    - If you can't tell what they mean, or the screenshot doesn't show enough, say so in a sentence and give your best guess.
    - If the transcript is empty, say in a sentence or two what the marked area (or the screen) is showing and what matters about it.
    """

    static func userText(transcript: String, frontApp: String, attachments: [Attachment]) -> String {
        let said = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        App in front: \(frontApp)
        Images: \(attachments.map(\.label).joined(separator: "; "))
        What they said: \(said.isEmpty ? "(nothing; they didn't speak)" : said)
        """
    }

    /// A thread is a Claude Code session: a new one starts with --session-id,
    /// follow-ups use --resume, and the same session can be opened in a terminal.
    struct Session { let id: String; let isNew: Bool; let name: String }

    /// Answers come from the local Claude Code login (`claude -p`), so they
    /// count against the user's Claude subscription, never API credits.
    static func ask(transcript: String, frontApp: String, attachments: [Attachment], session: Session) async throws -> (String, String) {
        (try await viaClaudeCode(transcript: transcript, frontApp: frontApp, attachments: attachments, session: session), "claude-code")
    }

    static var claudeBinary: String? {
        ["/opt/homebrew/bin/claude", "/usr/local/bin/claude",
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path,
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/local/claude").path]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    static func viaClaudeCode(transcript: String, frontApp: String, attachments: [Attachment], session: Session) async throws -> String {
        guard let bin = claudeBinary else {
            throw NSError(domain: "Remote", code: 2, userInfo: [NSLocalizedDescriptionKey: "Claude Code (the claude command) isn't installed"])
        }
        let files = attachments.map { "- \($0.label): \($0.file.path)" }.joined(separator: "\n")
        let prompt = """
        New question from Remote. Read each of these image files with the Read tool before answering:
        \(files)

        \(userText(transcript: transcript, frontApp: frontApp, attachments: attachments))

        Reply with only the words to be spoken.
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        var args = ["-p", prompt, "--model", Config.model, "--allowedTools", "Read", "--output-format", "text",
                    "--append-system-prompt", system + "\nEarlier turns in this session are earlier questions; use them for follow-ups."]
        args += session.isNew ? ["--session-id", session.id, "--name", session.name] : ["--resume", session.id]
        p.arguments = args
        // One fixed directory, so `claude --resume <id>` from there finds every thread.
        p.currentDirectoryURL = Config.supportDir
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        // Subscription only: an API key in the environment would make claude bill API credits.
        env["ANTHROPIC_API_KEY"] = nil; env["ANTHROPIC_AUTH_TOKEN"] = nil
        // Don't let the /readback Stop hook speak a recap of this helper session.
        env["READBACK_NESTED"] = "1"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let timeout = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: timeout)
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit(); timeout.cancel()
                let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if p.terminationStatus == 0 && !text.isEmpty { cont.resume(returning: text) }
                else {
                    let e = String(data: errData, encoding: .utf8) ?? ""
                    cont.resume(throwing: NSError(domain: "Remote", code: 3, userInfo: [NSLocalizedDescriptionKey: "claude -p failed (\(p.terminationStatus)): \(e.prefix(300))"]))
                }
            }
        }
    }
}

// MARK: - Speech

final class Speaker {
    private var proc: Process?
    var isSpeaking: Bool { proc?.isRunning ?? false }
    var onFinish: (() -> Void)?

    /// Speaks with the system voice (System Settings > Accessibility > Spoken Content),
    /// which is how a Siri voice gets used: `say -v` can't select Siri voices.
    func speak(file: URL) {
        stop()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-f", file.path]
        p.terminationHandler = { [weak self] _ in DispatchQueue.main.async { self?.onFinish?() } }
        try? p.run()
        proc = p
    }

    func speak(text: String) {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("remote-say.txt")
        try? text.write(to: f, atomically: true, encoding: .utf8)
        speak(file: f)
    }

    func stop() { if let p = proc, p.isRunning { p.terminate() }; proc = nil }
}

// MARK: - History (system of record)

struct Entry: Codable {
    var id: String
    var date: Date
    var transcript: String
    var frontApp: String
    var displays: Int
    var marked: Bool
    var backend: String?
    var model: String
    var answer: String?
    var error: String?
    var secondsToAnswer: Double?
    var threadID: String?
    var stopped: Bool?
}

/// A conversation thread = one Claude Code session.
struct ChatThread: Codable, Equatable {
    var id: String
    var title: String
    var created: Date
    var lastUsed: Date
}

enum Threads {
    static let continueWindow: TimeInterval = 15 * 60
    static var file: URL { Config.supportDir.appendingPathComponent("threads.json") }

    /// Most recently used first.
    static func all() -> [ChatThread] {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let d = try? Data(contentsOf: file), let ts = try? dec.decode([ChatThread].self, from: d) else { return [] }
        return ts.sorted { $0.lastUsed > $1.lastUsed }
    }

    static func upsert(_ t: ChatThread) {
        var ts = all().filter { $0.id != t.id }
        ts.insert(t, at: 0)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]; enc.dateEncodingStrategy = .iso8601
        try? enc.encode(Array(ts.prefix(Config.historyLimit))).write(to: file)
    }

    /// Turns in a thread, oldest first.
    static func turns(_ id: String) -> [Entry] {
        History.all().map(\.0).filter { $0.threadID == id }.sorted { $0.date < $1.date }
    }

    static func title(for transcript: String, frontApp: String) -> String {
        let t = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "About \(frontApp)" }
        return t.count > 44 ? String(t.prefix(44)) + "…" : t
    }
}

enum History {
    static func newDir() -> (String, URL) {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let id = f.string(from: Date())
        let u = Config.historyDir.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return (id, u)
    }

    static func save(_ e: Entry, in dir: URL) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        try? enc.encode(e).write(to: dir.appendingPathComponent("entry.json"))
        if let a = e.answer { try? a.write(to: dir.appendingPathComponent("answer.txt"), atomically: true, encoding: .utf8) }
    }

    /// Newest first.
    static func all() -> [(Entry, URL)] {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let dirs = (try? FileManager.default.contentsOfDirectory(at: Config.historyDir, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { d in
            guard let data = try? Data(contentsOf: d.appendingPathComponent("entry.json")),
                  let e = try? dec.decode(Entry.self, from: data) else { return nil }
            return (e, d)
        }.sorted { $0.0.date > $1.0.date }
    }

    /// Keeps every request in the newest three threads; drops the rest.
    static func prune() {
        let keep = Set(Threads.all().prefix(Config.historyLimit).map(\.id))
        for (e, d) in all() where !keep.contains(e.threadID ?? "") {
            try? FileManager.default.removeItem(at: d)
        }
    }
}

// MARK: - Overlay

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class OverlayView: NSView {
    let shot: DisplayShot
    var strokes: [[CGPoint]] = []
    var onKey: ((NSEvent) -> Void)?
    var onChange: (() -> Void)?
    private let backdrop: NSImage

    init(shot: DisplayShot) {
        self.shot = shot
        self.backdrop = NSImage(cgImage: shot.image, size: shot.screen.frame.size)
        super.init(frame: CGRect(origin: .zero, size: shot.screen.frame.size))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func keyDown(with event: NSEvent) { onKey?(event) }
    // Swallow key equivalents so stray shortcuts don't beep or act on the overlay.
    override func performKeyEquivalent(with event: NSEvent) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with e: NSEvent) { strokes.append([convert(e.locationInWindow, from: nil)]); needsDisplay = true }
    override func mouseDragged(with e: NSEvent) {
        guard !strokes.isEmpty else { return }
        strokes[strokes.count - 1].append(convert(e.locationInWindow, from: nil)); needsDisplay = true
    }
    override func mouseUp(with e: NSEvent) { onChange?() }
    override func rightMouseDown(with e: NSEvent) { clear() }

    func clear() { strokes.removeAll(); needsDisplay = true; onChange?() }

    override func draw(_ dirty: NSRect) {
        backdrop.draw(in: bounds)
        NSColor.black.withAlphaComponent(0.12).setFill(); bounds.fill()
        // Thin inner glow so it's obvious the screen is "live" for pointing.
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 10, yRadius: 10)
        border.lineWidth = 4; NSColor.systemRed.withAlphaComponent(0.65).setStroke(); border.stroke()

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 8, color: NSColor.systemRed.withAlphaComponent(0.6).cgColor)
        NSColor.systemRed.setStroke()
        for s in strokes where s.count > 1 {
            let p = NSBezierPath(); p.lineWidth = 6; p.lineCapStyle = .round; p.lineJoinStyle = .round
            p.move(to: s[0]); s.dropFirst().forEach { p.line(to: $0) }; p.stroke()
        }
        ctx.restoreGState()
    }
}

// MARK: - App

@MainActor
final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    enum State { case idle, capturing, listening, transcribing, thinking, approving, speaking }

    var state: State = .idle { didSet { updateIcon() } }
    var statusItem: NSStatusItem!
    var hotKey: HotKey?
    let speaker = Speaker()
    let model = UIModel()
    lazy var answerPanel = AnswerPanel(model: model)
    lazy var settings = SettingsWindowController(speaker: speaker)
    var escape: EscapeToStop?

    // Per-request
    var shots: [DisplayShot] = []
    var windows: [OverlayWindow] = []
    var views: [OverlayView] = []
    var hud: NSHostingView<ListeningHUD>?
    var frontApp = "unknown"
    var cursor: CGPoint = .zero
    let transcriber = Transcriber()
    var listening = false
    var requestToken = 0
    var agentRun: Agent.Run?
    lazy var pill = StatusPillPanel(model: model)
    var approvalWait: CheckedContinuation<Bool, Never>?
    var approvalTimeout: DispatchWorkItem?
    var returnHotKey: HotKey?
    var lastAnswerFile: URL?
    var cardThreadID: String?          // thread shown in the answer card
    var forceContinue = false          // "Follow up" button
    var hideWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu(); menu.delegate = self
        statusItem.menu = menu
        updateIcon()
        speaker.onFinish = { [weak self] in
            guard let self, self.state == .speaking else { return }
            self.state = .idle
            if self.model.phase == .speaking { self.model.phase = .idle }
            self.scheduleHide(after: 20)
        }
        model.onStop = { [weak self] in self?.stopSpeaking() }
        model.onReplay = { [weak self] in
            guard let self, let f = self.lastAnswerFile else { return }
            self.hideWork?.cancel()
            self.state = .speaking; self.model.phase = .speaking; self.speaker.speak(file: f)
        }
        model.onDismiss = { [weak self] in self?.stopSpeaking(); self?.answerPanel.orderOut(nil) }
        model.onFollowUp = { [weak self] in self?.forceContinue = true; self?.begin() }
        model.onOpenInTerminal = { [weak self] in if let id = self?.cardThreadID { self?.openInTerminal(id) } }
        hotKey = HotKey(keyCode: Config.hotKeyCode, modifiers: Config.hotKeyModifiers) { [weak self] in
            MainActor.assumeIsolated { self?.hotKeyPressed() }
        }
        transcriber.onPartial = { [weak self] t in
            MainActor.assumeIsolated { self?.heard(t) }
        }
        escape = EscapeToStop(isAppSpeaking: { [weak self] in
            guard let self else { return false }
            return self.speaker.isSpeaking || self.state == .thinking || self.state == .approving
        }, stopApp: { [weak self] in
            guard let self else { return }
            if self.state == .approving { self.finishApproval(false, reason: "esc"); return }
            if self.agentRun != nil { self.cancelAgent(reason: "esc"); return }
            self.stopSpeaking()
        })
        installBridge()
        AgentSocketServer.shared.start()
        NSApp.mainMenu = buildMainMenu()
        log("started; hotkey \(Config.hotKeyLabel); " + Permission.allCases.map { "\($0.rawValue)=\($0.granted ? "yes" : "NO")" }.joined(separator: ", "))
        // Launched by hand (Finder, Spotlight, Dock): show the window. At login: stay in the menu bar.
        if !launchedAtLogin() || !Permission.allGranted { settings.present() }
    }

    func launchedAtLogin() -> Bool {
        // Login items start before the user does anything; a hand launch comes with an open event.
        ProcessInfo.processInfo.systemUptime < 180
    }

    func buildMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let m = NSMenu()
        m.addItem(withTitle: "About Remote", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: ",").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Hide Remote", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        m.addItem(.separator())
        m.addItem(withTitle: "Quit Remote", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = m
        let winItem = NSMenuItem(); main.addItem(winItem)
        let w = NSMenu(title: "Window")
        w.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        w.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = w
        return main
    }

    // Opening the app again from Finder/Spotlight shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.present(); return false
    }

    func updateIcon() {
        let name: String
        switch state {
        case .idle: name = "waveform"
        case .capturing, .listening: name = "waveform.badge.mic"
        case .transcribing, .thinking, .approving: name = "ellipsis.circle"
        case .speaking: name = "speaker.wave.2.fill"
        }
        statusItem?.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: Config.appName)
    }

    // Menu is rebuilt each time it opens so history is current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let ask = menu.addItem(withTitle: "Ask About Screen", action: #selector(menuCapture), keyEquivalent: "a")
        ask.keyEquivalentModifierMask = [.option, .shift]; ask.target = self
        let stop = menu.addItem(withTitle: "Stop Speaking", action: #selector(menuStop), keyEquivalent: "")
        stop.target = self; stop.isEnabled = speaker.isSpeaking || agentRun != nil
        menu.addItem(.separator())
        let header = menu.addItem(withTitle: "Threads", action: nil, keyEquivalent: ""); header.isEnabled = false
        let threads = Threads.all()
        if threads.isEmpty { menu.addItem(withTitle: "Nothing yet", action: nil, keyEquivalent: "").isEnabled = false }
        let rel = RelativeDateTimeFormatter(); rel.unitsStyle = .short
        for (i, t) in threads.enumerated() {
            let n = Threads.turns(t.id).count
            let item = menu.addItem(withTitle: t.title, action: #selector(menuOpenThread(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = t.id
            item.image = NSImage(systemSymbolName: i == 0 ? "bubble.left.and.text.bubble.right.fill" : "bubble.left.and.text.bubble.right", accessibilityDescription: nil)
            item.toolTip = "\(n) question\(n == 1 ? "" : "s") · \(rel.localizedString(for: t.lastUsed, relativeTo: Date()))"
            let sub = NSMenu()
            sub.addItem(withTitle: "Show & Continue", action: #selector(menuOpenThread(_:)), keyEquivalent: "").representedObject = t.id
            sub.addItem(withTitle: "Open in Terminal", action: #selector(menuThreadTerminal(_:)), keyEquivalent: "").representedObject = t.id
            sub.items.forEach { $0.target = self }
            item.submenu = sub
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show History in Finder", action: #selector(menuShowHistory), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Remote", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc func menuCapture() { hotKeyPressed() }
    @objc func menuStop() {
        if agentRun != nil { cancelAgent(reason: "menu"); return }
        stopSpeaking()
    }
    @objc func menuSettings() { settings.present() }
    @objc func menuShowHistory() { NSWorkspace.shared.open(Config.historyDir) }
    /// Show a thread's card and make it the one ⌥⇧A continues.
    @objc func menuOpenThread(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String, var t = Threads.all().first(where: { $0.id == id }) else { return }
        t.lastUsed = Date(); Threads.upsert(t)
        showThread(id)
    }
    @objc func menuThreadTerminal(_ item: NSMenuItem) {
        if let id = item.representedObject as? String { openInTerminal(id) }
    }

    func showThread(_ id: String, phase: UIModel.Phase = .idle) {
        cardThreadID = id
        let turns = Threads.turns(id)
        model.threadTitle = Threads.all().first { $0.id == id }?.title ?? ""
        model.earlier = turns.dropLast().map { ($0.transcript, $0.answer ?? $0.error ?? "") }
        model.question = turns.last?.transcript ?? ""
        model.answer = turns.last?.answer ?? ""
        if let last = turns.last { lastAnswerFile = Config.historyDir.appendingPathComponent(last.id).appendingPathComponent("answer.txt") }
        model.phase = phase
        showAnswerPanel()
    }

    /// Opens the thread's Claude Code session so it can be continued by typing.
    func openInTerminal(_ id: String) {
        let dir = Config.supportDir.path
        let cmux = "/Applications/cmux.app/Contents/Resources/bin/cmux"
        if FileManager.default.isExecutableFile(atPath: cmux) {
            let p = Process(); p.executableURL = URL(fileURLWithPath: cmux)
            p.arguments = ["new-workspace", "--name", "Remote", "--cwd", dir, "--command", "claude --resume \(id)"]
            if (try? p.run()) != nil {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/cmux.app"))
                return
            }
        }
        let script = "tell application \"Terminal\" to do script \"cd '\(dir)' && claude --resume \(id)\"\ntell application \"Terminal\" to activate"
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }

    func stopSpeaking() {
        speaker.stop()
        if state == .speaking { state = .idle }
        if model.phase == .speaking { model.phase = .idle }
    }

    func showAnswerPanel() {
        hideWork?.cancel()
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
        answerPanel.show(on: screen)
        DispatchQueue.main.async { self.answerPanel.refit() }
    }

    func scheduleHide(after seconds: Double) {
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.answerPanel.orderOut(nil) }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    // MARK: Flow

    func hotKeyPressed() {
        switch state {
        case .listening: submit()
        case .capturing, .transcribing: break
        case .idle, .thinking, .approving, .speaking: begin()
        }
    }

    func begin() {
        let previous = agentRun
        agentRun = nil
        previous?.cancel()
        if approvalWait != nil { finishApproval(false, reason: "superseded") }
        if listening { transcriber.cancel(); listening = false }
        speaker.stop()
        answerPanel.orderOut(nil)
        pill.orderOut(nil)
        requestToken += 1          // a newer request supersedes one still thinking
        state = .capturing
        frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
        cursor = NSEvent.mouseLocation
        Task {
            do {
                shots = try await Capture.allDisplays()
            } catch {
                log("capture failed: \(error)")
                state = .idle
                fail("Remote needs Screen Recording permission. Allow it in Settings, then reopen the app.")
                settings.present()
                return
            }
            guard !shots.isEmpty else { state = .idle; fail("No displays to capture."); return }
            model.transcript = ""; model.marks = 0
            // Continue the latest thread if it was used recently (or "Follow up" was pressed).
            let latest = Threads.all().first
            model.threadTitle = latest?.title ?? ""
            model.hasThread = latest != nil
            model.continuing = latest != nil && (forceContinue || Date().timeIntervalSince(latest!.lastUsed) < Threads.continueWindow)
            forceContinue = false
            do { try transcriber.start(); listening = true }
            catch { listening = false; log("mic/transcriber failed to start: \(error.localizedDescription)") }
            model.canHear = listening
            model.phase = .listening
            state = .listening
            showOverlay()
        }
    }

    func showOverlay() {
        closeOverlay()
        let mouseScreen = NSScreen.screens.first { NSMouseInRect(cursor, $0.frame, false) } ?? NSScreen.main
        for shot in shots {
            let w = OverlayWindow(contentRect: shot.screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.level = .floating
            w.isOpaque = true
            w.hasShadow = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            w.setFrame(shot.screen.frame, display: false)
            let v = OverlayView(shot: shot)
            v.onKey = { [weak self] e in MainActor.assumeIsolated { self?.key(e) } }
            v.onChange = { [weak self] in MainActor.assumeIsolated { self?.model.marks = self?.views.reduce(0) { $0 + $1.strokes.count } ?? 0 } }
            w.contentView = v
            if shot.screen == mouseScreen {
                let h = NSHostingView(rootView: ListeningHUD(model: model))
                h.sizingOptions = []
                let size = CGSize(width: 660, height: 150)
                h.frame = CGRect(x: (v.bounds.width - size.width) / 2, y: 90, width: size.width, height: size.height)
                h.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
                v.addSubview(h)
                hud = h
            }
            windows.append(w); views.append(v)
        }
        NSApp.activate(ignoringOtherApps: true)
        for (w, v) in zip(windows, views) {
            w.makeKeyAndOrderFront(nil)
            if v.subviews.contains(where: { $0 === hud }) { w.makeKey(); w.makeFirstResponder(v) }
        }
    }

    func closeOverlay() {
        windows.forEach { $0.orderOut(nil) }
        windows = []; views = []; hud = nil
    }

    func key(_ e: NSEvent) {
        guard state == .listening else { return }
        switch Int(e.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter: submit()
        case kVK_Escape: cancel()
        case kVK_Tab: if model.hasThread { model.continuing.toggle() }
        case kVK_Delete, kVK_ForwardDelete: views.forEach { $0.clear() }
        default: break
        }
    }

    func cancel() {
        transcriber.cancel()
        listening = false
        state = .idle
        model.phase = .idle
        closeOverlay()
        log("cancelled")
    }

    func submit() {
        guard state == .listening else { return }
        let strokesByShot = views.map { $0.strokes }
        let captured = shots
        closeOverlay()   // the agent needs the live screen
        state = .transcribing
        model.phase = .thinking
        model.statusLine = "Working…"
        showPill()
        let token = requestToken
        Task {
            let transcript = listening ? await transcriber.stop() : ""
            listening = false
            await runAgent(transcript: transcript, strokesByShot: strokesByShot, captured: captured, token: token)
        }
    }

    func runAgent(transcript: String, strokesByShot: [[[CGPoint]]], captured: [DisplayShot], token: Int) async {
        state = .thinking
        model.question = transcript
        model.answer = ""
        model.phase = .thinking
        model.statusLine = "Working…"
        showPill()
        let started = Date()
        let (id, dir) = History.newDir()

        // Build the attachments: every display annotated, plus a close-up of the marks.
        var attachments: [Attachment] = []
        var marked = false
        for (i, shot) in captured.enumerated() {
            let strokes = i < strokesByShot.count ? strokesByShot[i] : []
            let local = NSMouseInRect(cursor, shot.screen.frame, false)
                ? CGPoint(x: cursor.x - shot.screen.frame.minX, y: cursor.y - shot.screen.frame.minY) : nil
            guard let img = Compose.annotated(shot, strokes: strokes, cursor: local),
                  let data = Compose.jpeg(img) else { continue }
            let file = dir.appendingPathComponent("display-\(shot.index).jpg")
            try? data.write(to: file)
            let where_ = captured.count > 1 ? "Display \(shot.index) of \(captured.count)" : "The screen"
            attachments.append(Attachment(label: where_ + (strokes.isEmpty ? "" : " (with the user's red marks)"), file: file))
            if let r = Compose.markedRect(strokes, in: shot.screen.frame.size),
               let crop = Compose.crop(img, pointRect: r, scale: shot.scale),
               let cd = Compose.jpeg(crop) {
                let cf = dir.appendingPathComponent("display-\(shot.index)-closeup.jpg")
                try? cd.write(to: cf)
                attachments.append(Attachment(label: "Close-up of the marked area on \(where_.lowercased())", file: cf))
                marked = true
            }
        }
        shots = []   // release the full-resolution captures
        if token != requestToken { return }

        // The thread: continue the latest one, or start a new Claude Code session.
        var thread: ChatThread
        var isNew: Bool
        if model.continuing, let latest = Threads.all().first {
            thread = latest; isNew = false
        } else {
            thread = ChatThread(id: UUID().uuidString.lowercased(), title: Threads.title(for: transcript, frontApp: frontApp),
                                created: started, lastUsed: started)
            isNew = true
        }
        thread.lastUsed = started
        Threads.upsert(thread)
        cardThreadID = thread.id
        model.threadTitle = thread.title
        model.earlier = Threads.turns(thread.id).map { ($0.transcript, $0.answer ?? $0.error ?? "") }

        var entry = Entry(id: id, date: started, transcript: transcript, frontApp: frontApp,
                          displays: attachments.count, marked: marked, backend: nil, model: Config.model)
        entry.threadID = thread.id
        History.save(entry, in: dir)
        History.prune()
        log("acting (\(isNew ? "new" : "continuing") thread \(thread.id.prefix(8))): \(transcript.prefix(120)) [\(attachments.count) images]")
        listenForStop()
        let holder = Agent.Run()
        agentRun = holder

        do {
            let answer = try await act(thread: thread, isNew: isNew, attachments: attachments, holder: holder, dir: dir)
            guard token == requestToken else { return }
            agentRun = nil
            stopCommandListener()
            entry.answer = answer
            entry.backend = "claude-code"
            entry.secondsToAnswer = Date().timeIntervalSince(started)
            History.save(entry, in: dir)
            log("answered via claude-code in \(String(format: "%.1f", entry.secondsToAnswer!))s")
            pill.orderOut(nil)
            lastAnswerFile = dir.appendingPathComponent("answer.txt")
            model.answer = answer
            model.phase = .speaking
            state = .speaking
            showAnswerPanel()
            speaker.speak(file: lastAnswerFile!)
            DispatchQueue.main.async { self.answerPanel.refit() }
        } catch is AgentStopped {
            guard token == requestToken else { return }
            agentRun = nil
            stopCommandListener()
            entry.stopped = true
            entry.answer = "Stopped."
            entry.secondsToAnswer = Date().timeIntervalSince(started)
            History.save(entry, in: dir)
            log("stopped")
            model.answer = "Stopped."
            model.phase = .stopped
            model.statusLine = "Stopped"
            state = .idle
            showPill()
            scheduleHidePill(after: 8)
        } catch {
            entry.error = error.localizedDescription
            History.save(entry, in: dir)
            log("ask failed: \(error.localizedDescription)")
            guard token == requestToken else { return }
            agentRun = nil
            stopCommandListener()
            fail("Sorry, I couldn't get an answer from Claude.")
        }
    }

    /// One turn. If resuming the Claude session fails, start it fresh under the same id.
    private func act(thread: ChatThread, isNew: Bool, attachments: [Attachment], holder: Agent.Run, dir: URL) async throws -> String {
        let name = "Remote · \(thread.title)"
        do {
            return try await Agent.run(transcript: model.question, frontApp: frontApp, attachments: attachments,
                                       session: .init(id: thread.id, isNew: isNew, name: name),
                                       threadDir: dir, approve: "ask", trace: nil, run: holder) { tool, input in
                log("model tool \(tool) \(input.prefix(180))")
            }
        } catch is AgentStopped {
            throw AgentStopped()
        } catch where !isNew {
            log("resume failed, starting the session fresh: \(error.localizedDescription)")
            let fresh = Agent.Run()
            agentRun = fresh
            return try await Agent.run(transcript: model.question, frontApp: frontApp, attachments: attachments,
                                       session: .init(id: thread.id, isNew: true, name: name),
                                       threadDir: dir, approve: "ask", trace: nil, run: fresh) { tool, input in
                log("model tool \(tool) \(input.prefix(180))")
            }
        }
    }

    func fail(_ message: String) {
        closeOverlay()
        pill.orderOut(nil)
        stopCommandListener()
        model.phase = .error(message)
        showAnswerPanel()
        state = .speaking
        speaker.speak(text: message)
    }

    func showPill() {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
        pill.show(on: screen, approving: model.phase == .approving)
    }

    func scheduleHidePill(after seconds: Double) {
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.pill.orderOut(nil) }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    func installBridge() {
        AgentBridge.shared.configure(progress: { [weak self] text in
            DispatchQueue.main.async {
                guard let self, self.agentRun != nil else { return }
                self.model.statusLine = text
                if self.state != .approving { self.model.phase = .thinking }
                self.speaker.speak(text: text)
                self.showPill()
            }
        }, approve: { [weak self] question, detail in
            let sem = DispatchSemaphore(value: 0)
            var allow = false
            DispatchQueue.main.async {
                guard let self else { sem.signal(); return }
                Task { @MainActor in
                    allow = await self.askApproval(question: question, detail: detail)
                    sem.signal()
                }
            }
            if sem.wait(timeout: .now() + 70) == .timedOut { return false }
            return allow
        })
    }

    func askApproval(question: String, detail: String) async -> Bool {
        log("approve ask: \(question) \(detail.prefix(160))")
        model.approvalQuestion = question
        model.statusLine = question
        model.phase = .approving
        state = .approving
        showPill()
        speaker.speak(text: question)
        if !listening { listenForStop() }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            approvalWait = cont
            let work = DispatchWorkItem { [weak self] in self?.finishApproval(false, reason: "timeout") }
            approvalTimeout = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
            returnHotKey = HotKey(keyCode: UInt32(kVK_Return), modifiers: 0) { [weak self] in
                MainActor.assumeIsolated { self?.finishApproval(true, reason: "return") }
            }
        }
    }

    func finishApproval(_ allow: Bool, reason: String) {
        guard let cont = approvalWait else { return }
        approvalWait = nil
        approvalTimeout?.cancel()
        approvalTimeout = nil
        returnHotKey = nil
        log("approve \(allow ? "yes" : "no") (\(reason))")
        if state == .approving {
            state = .thinking
            model.phase = .thinking
            model.statusLine = allow ? "Working…" : "Not doing that"
            showPill()
        }
        cont.resume(returning: allow)
    }

    func cancelAgent(reason: String) {
        log("stopping agent (\(reason))")
        agentRun?.cancel()
        speaker.stop()
        if approvalWait != nil { finishApproval(false, reason: reason) }
        model.phase = .stopped
        model.statusLine = "Stopped"
        model.answer = "Stopped."
        state = .thinking
        showPill()
    }

    func listenForStop() {
        do { try transcriber.start(); listening = true }
        catch { listening = false; log("command listener failed: \(error.localizedDescription)") }
    }

    func stopCommandListener() {
        guard state != .listening else { return }
        if listening { transcriber.cancel(); listening = false }
    }

    func heard(_ text: String) {
        if state == .listening { model.transcript = text; return }
        guard listening else { return }
        if saidStop(text) { cancelAgent(reason: "said stop"); return }
        if state == .approving, let yes = yesNo(text) { finishApproval(yes, reason: "speech") }
    }

    func saidStop(_ text: String) -> Bool { words(text).contains("stop") }

    func yesNo(_ text: String) -> Bool? {
        let w = words(text)
        let no: Set<String> = ["no", "nope", "nah", "cancel"]
        let yes: Set<String> = ["yes", "yeah", "yep", "yup", "ok", "okay", "sure"]
        let lower = text.lowercased()
        if lower.contains("do not") || lower.contains("don't") || w.contains(where: { no.contains($0) }) { return false }
        if lower.contains("go ahead") || w.contains(where: { yes.contains($0) }) { return true }
        return nil
    }

    func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter }.map(String.init)
    }
}

// MARK: - Self-test (no UI): capture, mark the centre, ask, print, speak.

func selfTest(_ question: String) async {
    do {
        let shots = try await Capture.allDisplays()
        print("displays: \(shots.map { "\($0.index): \($0.image.width)x\($0.image.height)" })")
        guard let s = shots.first else { print("no displays"); exit(1) }
        let c = CGPoint(x: s.screen.frame.width / 2, y: s.screen.frame.height / 2)
        let circle = (0...40).map { i -> CGPoint in
            let a = Double(i) / 40 * 2 * .pi
            return CGPoint(x: c.x + 220 * cos(a), y: c.y + 140 * sin(a))
        }
        let (_, dir) = History.newDir()
        guard let img = Compose.annotated(s, strokes: [circle], cursor: c), let d = Compose.jpeg(img),
              let r = Compose.markedRect([circle], in: s.screen.frame.size),
              let crop = Compose.crop(img, pointRect: r, scale: s.scale), let cd = Compose.jpeg(crop) else { print("compose failed"); exit(1) }
        let f1 = dir.appendingPathComponent("display-1.jpg"), f2 = dir.appendingPathComponent("display-1-closeup.jpg")
        try d.write(to: f1); try cd.write(to: f2)
        print("images: \(dir.path)")
        let t0 = Date()
        let sid = UUID().uuidString.lowercased()
        let (answer, backend) = try await Claude.ask(transcript: question, frontApp: "selftest",
            attachments: [Attachment(label: "The screen (with the user's red marks)", file: f1),
                          Attachment(label: "Close-up of the marked area on the screen", file: f2)],
            session: .init(id: sid, isNew: true, name: "Remote self-test"))
        print("backend: \(backend), \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
        print("answer 1: \(answer)")
        // Turn two in the same thread, no new marks: it must remember turn one.
        let t1 = Date()
        let (followUp, _) = try await Claude.ask(transcript: "What did I just ask you, and what was your answer? One sentence.",
            frontApp: "selftest", attachments: [Attachment(label: "The screen", file: f1)],
            session: .init(id: sid, isNew: false, name: ""))
        print("answer 2 (\(String(format: "%.1f", Date().timeIntervalSince(t1)))s): \(followUp)")
        print("session: \(sid)")
        try? FileManager.default.removeItem(at: dir)
        exit(0)
    } catch { print("selftest failed: \(error)"); exit(1) }
}

// MARK: - Main

/// Transcribe an audio file with the same on-device recognizer, write the text
/// next to it. Used to verify speech recognition without a live mic.
func transcribeFileTest(_ path: String) async {
    let out = URL(fileURLWithPath: path + ".txt")
    if let problem = await Transcriber.requestPermissions() { try? "ERROR: \(problem)".write(to: out, atomically: true, encoding: .utf8); exit(1) }
    guard let r = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else { exit(1) }
    let req = SFSpeechURLRecognitionRequest(url: URL(fileURLWithPath: path))
    req.requiresOnDeviceRecognition = r.supportsOnDeviceRecognition
    req.addsPunctuation = true
    r.recognitionTask(with: req) { result, error in
        if let result, result.isFinal {
            try? "ondevice=\(r.supportsOnDeviceRecognition) \(result.bestTranscription.formattedString)".write(to: out, atomically: true, encoding: .utf8); exit(0)
        }
        if let error { try? "ERROR: \(error.localizedDescription)".write(to: out, atomically: true, encoding: .utf8); exit(1) }
    }
}

let args = CommandLine.arguments
if args.contains("--mcp-server") {
    MCPServer.serve(args)
} else if args.contains("--mcp-selftest") {
    exit(MCPServer.selfTest())
} else if let i = args.firstIndex(of: "--selftest-agent") {
    let q = i + 1 < args.count && !args[i + 1].hasPrefix("--") ? args[i + 1] : "Open my Downloads folder"
    Task { await Agent.selfTest(request: q) }
    RunLoop.main.run()
} else if let i = args.firstIndex(of: "--transcribe-file"), i + 1 < args.count {
    let f = args[i + 1]
    Task { await transcribeFileTest(f) }
    RunLoop.main.run()
} else if let i = args.firstIndex(of: "--selftest") {
    let q = i + 1 < args.count ? args[i + 1] : "What's inside the red circle?"
    Task { await selfTest(q) }
    RunLoop.main.run()
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = App()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
