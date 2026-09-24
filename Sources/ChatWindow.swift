// The app, as a conversation.
//
// This window is what Remote looks like: threads on the left, the conversation
// on the right, a composer at the bottom. Each message is one request — what you
// said (spoken or typed), the screen it was looking at, what it did on your Mac,
// and what it said back. Settings live in the menu bar and in small popovers on
// the toolbar, so nothing ever replaces the conversation.

import AppKit
import SwiftUI

// MARK: - Store

/// What the window shows. The app writes into it as a turn runs, so a request
/// started with the hotkey appears here live.
@MainActor
final class ChatStore: ObservableObject {
    static let shared = ChatStore()

    @Published var threads: [ChatThread] = []
    @Published var selected: String?
    @Published var turns: [(Entry, URL)] = []

    /// The turn in flight, if any: shown at the end of the thread as it happens.
    @Published var liveThreadID: String?
    @Published var liveTranscript = ""
    @Published var liveActions: [String] = []
    @Published var liveStatus = ""
    @Published var speaking = false

    /// Set by the app so the composer can start a request from this window.
    var onAsk: ((String) -> Void)?
    var onListen: (() -> Void)?
    var onStop: (() -> Void)?
    var onContinueInCode: ((ChatThread) -> Void)?
    var onWatchPane: ((ChatThread) -> Void)?

    func refresh() {
        threads = Threads.all()
        if selected == nil || !threads.contains(where: { $0.id == selected }) {
            selected = liveThreadID ?? threads.first?.id
        }
        loadTurns()
    }

    func select(_ id: String) {
        selected = id
        loadTurns()
    }

    private func loadTurns() {
        guard let id = selected else { turns = []; return }
        let dirs = Dictionary(History.all().map { ($0.0.id, $0.1) }, uniquingKeysWith: { a, _ in a })
        turns = Threads.turns(id).compactMap { e in dirs[e.id].map { (e, $0) } }
    }

    // Called by the app as a request runs.
    func beginTurn(threadID: String, transcript: String) {
        liveThreadID = threadID
        liveTranscript = transcript
        liveActions = []
        liveStatus = "Working…"
        selected = threadID
        refresh()
    }

    func addAction(_ a: String) {
        liveActions.append(a)
        liveStatus = a
    }

    func endTurn() {
        liveThreadID = nil
        liveTranscript = ""
        liveActions = []
        liveStatus = ""
        refresh()
    }
}

// MARK: - Message

struct MessageView: View {
    let entry: Entry
    let dir: URL
    @State private var showShots = false

    private var images: [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // You
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(Color.accentColor.opacity(0.85)).frame(width: 22, height: 22)
                    .overlay(Image(systemName: entry.transcript.isEmpty ? "cursorarrow.rays" : "waveform")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.transcript.isEmpty ? "(pointed at the screen)" : entry.transcript)
                        .font(.system(size: 14)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !images.isEmpty {
                        Button {
                            showShots.toggle()
                        } label: {
                            Label("\(images.count) screenshot\(images.count == 1 ? "" : "s")",
                                  systemImage: showShots ? "chevron.down" : "chevron.right")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        if showShots {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(images, id: \.self) { url in
                                        if let img = NSImage(contentsOf: url) {
                                            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                                                .frame(width: 168, height: 100)
                                                .clipShape(RoundedRectangle(cornerRadius: 7))
                                                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor)))
                                                .onTapGesture { NSWorkspace.shared.open(url) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                Text(entry.date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }

            // Remote
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(Color(nsColor: .controlAccentColor).opacity(0.18)).frame(width: 22, height: 22)
                    .overlay(Image(systemName: "desktopcomputer").font(.system(size: 10, weight: .bold)))
                VStack(alignment: .leading, spacing: 7) {
                    if let actions = entry.actions, !actions.isEmpty {
                        ActionTrail(actions: actions)
                    }
                    if let answer = entry.answer {
                        Text(answer).font(.system(size: 14)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if let error = entry.error {
                        Text(error).font(.system(size: 13)).foregroundStyle(.red).textSelection(.enabled)
                    }
                    HStack(spacing: 12) {
                        if let s = entry.secondsToAnswer { Text(String(format: "%.1fs", s)) }
                        if entry.stopped == true { Text("stopped").foregroundStyle(.orange) }
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(entry.answer ?? entry.error ?? "", forType: .string)
                        }.buttonStyle(.link)
                        Button("Files") { NSWorkspace.shared.open(dir) }.buttonStyle(.link)
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 6)
    }
}

/// What it did, in the order it did it.
struct ActionTrail: View {
    let actions: [String]
    var live = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(actions.enumerated()), id: \.offset) { i, a in
                HStack(spacing: 7) {
                    Image(systemName: live && i == actions.count - 1 ? "circle.dotted" : "checkmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(live && i == actions.count - 1 ? Color.secondary : Color.green.opacity(0.8))
                    Text(a).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 9)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor).opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6)))
    }
}

// MARK: - Composer

struct Composer: View {
    @ObservedObject var store: ChatStore
    @ObservedObject var model: UIModel
    @State private var text = ""
    @FocusState private var focused: Bool

    private var listening: Bool { model.phase == .listening }
    private var working: Bool { store.liveThreadID != nil }

    var body: some View {
        VStack(spacing: 8) {
            if working {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(store.liveStatus).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("Stop") { store.onStop?() }.buttonStyle(.borderless).foregroundStyle(.red)
                }
            }
            HStack(spacing: 10) {
                Button {
                    store.onListen?()
                } label: {
                    Image(systemName: listening ? "waveform.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(listening ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help("Ask out loud — freezes the screen so you can point (\(Config.hotKeyLabel))")

                TextField("Ask Remote to do something on this Mac…", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(1...5)
                    .focused($focused)
                    .onSubmit(send)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(focused ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor)))

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 26))
                }
                .buttonStyle(.borderless)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || working)
                .keyboardShortcut(.return, modifiers: [])
            }
            HStack(spacing: 5) {
                Image(systemName: "camera.viewfinder").font(.system(size: 10))
                Text("Your screen goes with every request. \(Config.hotKeyLabel) anywhere to ask out loud and point.")
                Spacer()
            }
            .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(.bar)
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !working else { return }
        text = ""
        store.onAsk?(t)
    }
}

// MARK: - Window

struct ChatView: View {
    @ObservedObject var store: ChatStore
    @ObservedObject var model: UIModel
    var onTestVoice: () -> Void
    @State private var showBehaviour = false
    @State private var showPermissions = false

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { store.selected }, set: { if let v = $0 { store.select(v) } })) {
                Section("Threads") {
                    ForEach(store.threads, id: \.id) { t in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                            HStack(spacing: 5) {
                                Text(t.lastUsed.formatted(date: .abbreviated, time: .shortened))
                                if Ownership.isTakenOver(t.id) {
                                    Text("· in cmux").foregroundStyle(.orange)
                                }
                            }
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                        .tag(t.id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            VStack(spacing: 0) {
                if !Permission.allGranted {
                    PermissionBanner(show: $showPermissions)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(Array(store.turns.enumerated()), id: \.element.0.id) { i, pair in
                                MessageView(entry: pair.0, dir: pair.1)
                                if i < store.turns.count - 1 { Divider().opacity(0.4) }
                            }
                            if store.liveThreadID != nil, store.liveThreadID == store.selected {
                                LiveTurn(store: store).id("live")
                            }
                            if store.turns.isEmpty && store.liveThreadID == nil {
                                EmptyChat()
                            }
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Newest at the bottom, the way a conversation reads.
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: store.turns.count) { _, _ in
                        withAnimation { proxy.scrollTo(store.turns.last?.0.id, anchor: .bottom) }
                    }
                    .onChange(of: store.liveActions.count) { _, _ in
                        withAnimation { proxy.scrollTo("live", anchor: .bottom) }
                    }
                }
                Divider()
                Composer(store: store, model: model)
            }
            .toolbar {
                ToolbarItemGroup {
                    if let t = store.threads.first(where: { $0.id == store.selected }) {
                        Button { store.onWatchPane?(t) } label: { Image(systemName: "rectangle.split.2x1") }
                            .help("Watch this thread in a cmux pane")
                        Button { store.onContinueInCode?(t) } label: { Image(systemName: "terminal") }
                            .help("Continue this thread in Claude Code")
                    }
                    Button { showBehaviour.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                        .help("Behaviour")
                        .popover(isPresented: $showBehaviour, arrowEdge: .bottom) {
                            BehaviourPopover(onTestVoice: onTestVoice).frame(width: 340)
                        }
                }
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        .onAppear { store.refresh() }
    }
}

struct EmptyChat: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform").font(.system(size: 34)).foregroundStyle(.tertiary)
            Text("Talk to this Mac").font(.title3.weight(.medium))
            Text("Press \(Config.hotKeyLabel) anywhere, point at something, and say what you want done.\nOr type it below. Your screen goes with every request.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).font(.system(size: 13))
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }
}

/// The request in flight, drawn like a message that hasn't finished.
struct LiveTurn: View {
    @ObservedObject var store: ChatStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(Color.accentColor.opacity(0.85)).frame(width: 22, height: 22)
                    .overlay(Image(systemName: "waveform").font(.system(size: 10, weight: .bold)).foregroundStyle(.white))
                Text(store.liveTranscript.isEmpty ? "(pointed at the screen)" : store.liveTranscript)
                    .font(.system(size: 14))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(Color(nsColor: .controlAccentColor).opacity(0.18)).frame(width: 22, height: 22)
                    .overlay(ProgressView().controlSize(.mini))
                VStack(alignment: .leading, spacing: 7) {
                    if store.liveActions.isEmpty {
                        Text(store.liveStatus.isEmpty ? "Working…" : store.liveStatus)
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    } else {
                        ActionTrail(actions: store.liveActions, live: true)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 6)
    }
}

struct PermissionBanner: View {
    @Binding var show: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Remote needs \(Permission.allCases.filter { !$0.granted }.map(\.rawValue).joined(separator: ", ")) to work.")
                .font(.system(size: 12))
            Spacer()
            Button("Fix…") { show.toggle() }
                .popover(isPresented: $show, arrowEdge: .bottom) {
                    PermissionsPopover().frame(width: 360)
                }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }
}

// MARK: - The window itself

@MainActor
final class ChatWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: UIModel
    private let onTestVoice: () -> Void

    init(model: UIModel, onTestVoice: @escaping () -> Void) {
        self.model = model
        self.onTestVoice = onTestVoice
    }

    func present() {
        ChatStore.shared.refresh()
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            w.orderFrontRegardless()
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingView(rootView: ChatView(store: ChatStore.shared, model: model, onTestVoice: onTestVoice))
        host.sizingOptions = []
        host.frame = CGRect(x: 0, y: 0, width: 980, height: 660)
        let w = NSWindow(contentRect: host.frame,
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Remote"
        w.subtitle = "\(Config.hotKeyLabel) anywhere"
        w.contentView = host
        w.center()
        w.isReleasedWhenClosed = false
        w.delegate = self
        window = w
        // A menu-bar app has to ask for the Dock and the menu bar while a real
        // window is open, or its menus are not reachable.
        NSApp.setActivationPolicy(.regular)
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Back to the menu bar when the conversation is closed.
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
