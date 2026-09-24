// SwiftUI surfaces: the listening HUD on the overlay, the answer card, and
// the Settings window. The app logic in main.swift drives `UIModel`.

import AppKit
import ApplicationServices
import AVFoundation
import ServiceManagement
import Speech
import SwiftUI

// MARK: - Model

@MainActor
final class UIModel: ObservableObject {
    enum Phase: Equatable { case idle, listening, thinking, approving, speaking, stopped, error(String) }

    @Published var phase: Phase = .idle
    @Published var transcript = ""
    @Published var canHear = true
    @Published var answer = ""
    @Published var question = ""
    @Published var marks = 0
    @Published var statusLine = ""
    @Published var approvalQuestion = ""
    @Published var approvalDetail = ""
    // Thread
    @Published var threadTitle = ""
    @Published var hasThread = false
    @Published var continuing = false
    @Published var earlier: [(q: String, a: String)] = []

    var onStop: () -> Void = {}
    var onFollowUp: () -> Void = {}
    var onOpenInTerminal: () -> Void = {}
    var onReplay: () -> Void = {}
    var onDismiss: () -> Void = {}
}

// MARK: - Claude Code login

struct ClaudeLogin {
    var installed = false, loggedIn = false, plan = ""

    /// `claude auth status` (JSON). Runs off the main thread.
    static func check() async -> ClaudeLogin {
        guard let bin = Claude.claudeBinary else { return ClaudeLogin() }
        return await Task.detached {
            let p = Process(); p.executableURL = URL(fileURLWithPath: bin); p.arguments = ["auth", "status"]
            var env = ProcessInfo.processInfo.environment
            env["ANTHROPIC_API_KEY"] = nil; env["ANTHROPIC_AUTH_TOKEN"] = nil
            p.environment = env
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
            guard (try? p.run()) != nil else { return ClaudeLogin(installed: true) }
            let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            return ClaudeLogin(installed: true, loggedIn: j["loggedIn"] as? Bool ?? false,
                               plan: (j["subscriptionType"] as? String ?? "").capitalized)
        }.value
    }
}

// MARK: - Permissions

enum Permission: String, CaseIterable, Identifiable {
    case screen = "Screen Recording", microphone = "Microphone", speech = "Speech Recognition", accessibility = "Accessibility"
    var id: String { rawValue }

    var why: String {
        switch self {
        case .screen: return "To see what you're pointing at."
        case .microphone: return "To hear your question."
        case .speech: return "To turn it into text, on this Mac."
        case .accessibility: return "To click and type when you ask."
        }
    }

    var granted: Bool {
        switch self {
        case .screen: return CGPreflightScreenCaptureAccess()
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .speech: return SFSpeechRecognizer.authorizationStatus() == .authorized
        case .accessibility: return AXIsProcessTrusted()
        }
    }

    var undetermined: Bool {
        switch self {
        case .screen, .accessibility: return false
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
        case .speech: return SFSpeechRecognizer.authorizationStatus() == .notDetermined
        }
    }

    var settingsURL: URL {
        let anchor: String
        switch self {
        case .screen: anchor = "Privacy_ScreenCapture"
        case .microphone: anchor = "Privacy_Microphone"
        case .speech: anchor = "Privacy_SpeechRecognition"
        case .accessibility: anchor = "Privacy_Accessibility"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    /// Ask via the system prompt when macOS still allows it, else open Settings.
    func request() async {
        switch self {
        case .screen:
            if !CGRequestScreenCaptureAccess() { NSWorkspace.shared.open(settingsURL) }
        case .accessibility:
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let opts = [key: true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(opts) { NSWorkspace.shared.open(settingsURL) }
        case .microphone:
            if undetermined { _ = await AVCaptureDevice.requestAccess(for: .audio) }
            else { NSWorkspace.shared.open(settingsURL) }
        case .speech:
            if undetermined { _ = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } } }
            else { NSWorkspace.shared.open(settingsURL) }
        }
    }

    static var allGranted: Bool { allCases.allSatisfy(\.granted) }
}

// MARK: - Pieces

struct Keycap: View {
    let key: String
    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.14)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.white.opacity(0.22), lineWidth: 0.5))
    }
}

struct Hint: View {
    let key: String, label: String
    var body: some View {
        HStack(spacing: 5) { Keycap(key: key); Text(label) }
    }
}

struct PulsingDot: View {
    @State private var on = false
    var body: some View {
        Circle().fill(Color.red).frame(width: 10, height: 10)
            .overlay(Circle().stroke(Color.red.opacity(0.5), lineWidth: 6).scaleEffect(on ? 1.9 : 1).opacity(on ? 0 : 1))
            .onAppear { withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { on = true } }
    }
}

// MARK: - Listening HUD (sits on the overlay)

struct ListeningHUD: View {
    @ObservedObject var model: UIModel

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                if model.phase == .listening && model.canHear {
                    PulsingDot().padding(.top, 5)
                } else {
                    ProgressView().controlSize(.small).padding(.top, 1)
                }
                Text(headline)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(model.transcript.isEmpty ? .white.opacity(0.75) : .white)
                    .lineLimit(3).truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.easeOut(duration: 0.12), value: model.transcript)
            }
            if model.phase == .listening && model.hasThread {
                HStack(spacing: 6) {
                    Image(systemName: model.continuing ? "arrowshape.turn.up.right.fill" : "plus.bubble.fill")
                    Text(model.continuing ? "Continuing “\(model.threadTitle)”" : "New thread")
                        .lineLimit(1).truncationMode(.tail)
                    Keycap(key: "tab")
                    Text(model.continuing ? "new thread" : "continue").foregroundStyle(.white.opacity(0.6))
                    Spacer()
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(model.continuing ? Color(red: 0.72, green: 0.68, blue: 1) : .white.opacity(0.85))
            }
            if model.phase == .listening {
                HStack(spacing: 16) {
                    Hint(key: "⏎", label: "Ask")
                    Hint(key: "esc", label: "Cancel")
                    if model.marks > 0 { Hint(key: "⌫", label: "Clear marks") }
                    Spacer()
                    Text("Draw to point at something").foregroundStyle(.white.opacity(0.6))
                }
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .frame(width: 620)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.black.opacity(0.72)))
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
        .environment(\.colorScheme, .dark)
    }

    private var headline: String {
        if model.phase != .listening { return "Got it…" }
        if !model.canHear { return "I can't hear you (mic or speech permission is off). Press ⏎ to ask about the screen anyway." }
        return model.transcript.isEmpty ? "Listening… ask about what's on screen" : model.transcript
    }
}

// MARK: - Answer card (floating, while thinking and speaking)

struct AnswerCard: View {
    @ObservedObject var model: UIModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(tint).font(.system(size: 13, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { model.onDismiss() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Close")
            }
            if !model.threadTitle.isEmpty && !model.earlier.isEmpty {
                Text("\(model.threadTitle) · \(model.earlier.count + 1) questions")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary).lineLimit(1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(model.earlier.enumerated()), id: \.offset) { _, t in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.q.isEmpty ? "(about the screen)" : t.q).font(.system(size: 12, weight: .medium))
                                Text(t.a).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110)
                Divider()
            }
            if !model.question.isEmpty {
                Text("“\(model.question)”").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            }
            switch model.phase {
            case .thinking, .approving:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(model.statusLine.isEmpty ? "Working…" : model.statusLine).foregroundStyle(.secondary) }
                    .font(.system(size: 14))
            case .stopped:
                Text("Stopped.").font(.system(size: 14))
            case .error(let message):
                Text(message).font(.system(size: 14))
            default:
                ScrollView { Text(model.answer).font(.system(size: 15)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 150)
                HStack(spacing: 8) {
                    if model.phase == .speaking {
                        Button { model.onStop() } label: { Label("Stop", systemImage: "stop.fill") }
                    } else {
                        Button { model.onReplay() } label: { Label("Replay", systemImage: "play.fill") }
                    }
                    Button {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.answer, forType: .string)
                    } label: { Label("Copy", systemImage: "doc.on.doc") }
                    Spacer()
                    Button { model.onOpenInTerminal() } label: { Label("Open in Terminal", systemImage: "terminal") }
                        .help("Continue this thread by typing, in Claude Code")
                    Button { model.onFollowUp() } label: { Label("Follow up", systemImage: "arrowshape.turn.up.right") }
                        .keyboardShortcut(.defaultAction)
                        .help("Ask a follow-up in this thread (or press ⌥⇧A within 15 minutes)")
                }
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 540)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.primary.opacity(0.08), lineWidth: 0.5))
        .padding(20) // room for the shadow
        .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
    }

    private var title: String {
        switch model.phase {
        case .thinking: return "Working"
        case .approving: return "Asking"
        case .speaking: return "Reading aloud"
        case .stopped: return "Stopped"
        case .error: return "Something went wrong"
        default: return "Remote"
        }
    }
    private var icon: String {
        switch model.phase {
        case .thinking: return "sparkles"
        case .approving: return "questionmark.circle.fill"
        case .speaking: return "speaker.wave.2.fill"
        case .stopped: return "stop.fill"
        case .error: return "exclamationmark.triangle.fill"
        default: return "waveform"
        }
    }
    private var tint: Color {
        if case .error = model.phase { return .orange }
        return .accentColor
    }
}

final class AnswerPanel: NSPanel {
    init(model: UIModel) {
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: AnswerCard(model: model))
        host.sizingOptions = []
        contentView = host
    }

    /// Bottom centre of the screen the pointer is on.
    func show(on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main, let host = contentView else { return }
        let size = host.fittingSize
        let f = screen.visibleFrame
        setFrame(CGRect(x: f.midX - size.width / 2, y: f.minY + 24, width: size.width, height: size.height), display: true)
        orderFrontRegardless()
    }

    func refit() {
        guard isVisible, let host = contentView else { return }
        let size = host.fittingSize
        setFrame(CGRect(x: frame.midX - size.width / 2, y: frame.minY, width: size.width, height: size.height), display: true, animate: false)
    }
}

// MARK: - Status pill (the listening HUD, shrunk, while the agent works)

struct StatusPill: View {
    @ObservedObject var model: UIModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if model.phase == .approving {
                    Image(systemName: "questionmark.circle.fill").foregroundStyle(.yellow)
                } else if model.phase == .stopped {
                    Image(systemName: "stop.fill").foregroundStyle(.white.opacity(0.8))
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(headline)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.phase == .approving {
                if !model.approvalDetail.isEmpty {
                    Text(model.approvalDetail)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 14) {
                    Hint(key: "⌥⇧Y", label: "Yes")
                    Hint(key: "esc", label: "No")
                    Text("or say it").foregroundStyle(.white.opacity(0.6))
                }
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(width: model.phase == .approving ? 460 : 400, height: model.phase == .approving ? 150 : 52, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.black.opacity(0.78)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
    }

    private var headline: String {
        switch model.phase {
        case .approving: return model.approvalQuestion.isEmpty ? "Allow this?" : model.approvalQuestion
        case .stopped: return "Stopped"
        default: return model.statusLine.isEmpty ? "Working…" : model.statusLine
        }
    }
}

final class StatusPillPanel: NSPanel {
    private let host: NSHostingView<StatusPill>

    init(model: UIModel) {
        let host = NSHostingView(rootView: StatusPill(model: model))
        host.sizingOptions = []
        self.host = host
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 76),
                   styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        contentView = host
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    /// Explicit frames. A self-sizing host plus a timer crashed Settings; this stays fixed.
    func show(on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        let approving = modelPhaseApproving
        let size = approving ? CGSize(width: 480, height: 174) : CGSize(width: 420, height: 76)
        host.frame = CGRect(origin: .zero, size: size)
        let f = screen.visibleFrame
        setFrame(CGRect(x: f.midX - size.width / 2, y: f.minY + 28, width: size.width, height: size.height), display: true)
        orderFrontRegardless()
    }

    private var modelPhaseApproving: Bool {
        // The hosting view's root is not exposed; the window is resized by the app
        // passing the phase through a stored flag set just before show.
        approving
    }

    private var approving = false

    func show(on screen: NSScreen?, approving: Bool) {
        self.approving = approving
        show(on: screen)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @State private var tick = 0
    @State private var login = ClaudeLogin(installed: true, loggedIn: true)
    @State private var atLogin = SMAppService.mainApp.status == .enabled
    let speaker: Speaker
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Remote").font(.title3.weight(.semibold))
                        HStack(spacing: 4) {
                            Text("Press"); Keycap(key: Config.hotKeyLabel).foregroundStyle(.primary)
                            Text("anywhere, point, and ask.")
                        }
                        .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Permissions") {
                let _ = tick   // re-read permission state on each refresh
                ForEach(Permission.allCases) { p in
                    HStack {
                        Image(systemName: p.granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(p.granted ? .green : .orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.rawValue)
                            Text(p.why).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !p.granted {
                            Button(p.undetermined ? "Allow…" : "Open Settings") { Task { await p.request(); tick += 1 } }
                        }
                    }
                }
                if !Permission.screen.granted {
                    HStack {
                        Text("After switching Remote on in System Settings, reopen the app so macOS applies it.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Quit & Reopen") { Relaunch.now() }
                    }
                }
            }

            Section {
                HStack {
                    Image(systemName: login.loggedIn ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(login.loggedIn ? .green : .orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(login.loggedIn ? "Claude Code, \(login.plan.isEmpty ? "logged in" : login.plan + " plan")"
                             : login.installed ? "Claude Code isn't logged in" : "Claude Code isn't installed")
                        Text(login.loggedIn ? "Answers use your subscription, not API credits."
                             : login.installed ? "Run claude in Terminal and log in with your Claude account."
                             : "Install Claude Code, then log in with your Claude account.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Check again") { Task { login = await ClaudeLogin.check() } }
                }
            } header: {
                Text("Claude")
            }
            .task { login = await ClaudeLogin.check() }

            Section {
                HStack {
                    Text("Voice")
                    Spacer()
                    Button("Test") { speaker.speak(text: "This is how Remote sounds.") }
                    Button("Change Voice…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent")!)
                    }
                }
                Toggle("Open at login", isOn: $atLogin)
                    .onChange(of: atLogin) { _, on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        catch { log("login item: \(error)"); atLogin = SMAppService.mainApp.status == .enabled }
                    }
            } header: {
                Text("General")
            } footer: {
                Text("Remote speaks with your Mac's System Voice. To use a Siri voice, pick one under Spoken Content.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 700)
        .onReceive(timer) { _ in tick += 1 }
    }
}

enum Relaunch {
    static func now() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.7; /usr/bin/open \"\(path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }
}

/// While the window is open Remote is a normal app (Dock icon, ⌘Q, ⌘,);
/// when it's closed it lives in the menu bar only.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    convenience init(speaker: Speaker) {
        // Fixed size on purpose: a self-sizing hosting view plus the live
        // permission refresh makes AppKit's layout loop and throw.
        let host = NSHostingView(rootView: SettingsView(speaker: speaker))
        host.sizingOptions = []
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 700),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.contentView = host
        w.title = "Remote"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        self.init(window: w)
        w.delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func present() {
        NSApp.setActivationPolicy(.regular)
        if !(window?.isVisible ?? false) { window?.center() }
        showWindow(nil)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()   // an accessory app can't count on activation
    }
}
