// The thread, on screen.
//
// Every request is one message: what you said, the screenshots that went with
// it, what the agent actually did, and what it answered. Threads are listed
// newest first, and any thread can be carried on in a cmux pane running
// samepage and Claude Code on the same session.

import AppKit
import SwiftUI

struct TurnView: View {
    let entry: Entry
    let dir: URL
    let onCopy: (String) -> Void

    private var images: [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.transcript.isEmpty ? "(pointed at the screen)" : entry.transcript)
                    .font(.system(size: 14, weight: .semibold))
                    .textSelection(.enabled)
                Spacer()
                Text(entry.date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button {
                    onCopy(entry.transcript)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy this transcript")
            }

            if !images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(images, id: \.self) { url in
                            if let img = NSImage(contentsOf: url) {
                                Image(nsImage: img)
                                    .resizable().aspectRatio(contentMode: .fill)
                                    .frame(width: 104, height: 62)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                                    .onTapGesture { NSWorkspace.shared.open(url) }
                                    .help(url.lastPathComponent)
                            }
                        }
                    }
                }
            }

            if let actions = entry.actions, !actions.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(actions.prefix(12).enumerated()), id: \.offset) { _, a in
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.turn.down.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                            Text(a).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    if actions.count > 12 {
                        Text("and \(actions.count - 12) more").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
            }

            if let answer = entry.answer {
                Text(answer).font(.system(size: 13)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let error = entry.error {
                Text(error).font(.system(size: 13)).foregroundStyle(.red).textSelection(.enabled)
            }

            HStack(spacing: 10) {
                if let s = entry.secondsToAnswer {
                    Label(String(format: "%.1fs", s), systemImage: "clock").labelStyle(.titleAndIcon)
                }
                Button("Show files") { NSWorkspace.shared.open(dir) }.buttonStyle(.link)
                if entry.stopped == true { Text("stopped").foregroundStyle(.orange) }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator))
    }
}

struct HistoryView: View {
    @State private var threads: [ChatThread] = Threads.all()
    @State private var selected: String?
    @State private var copied = false
    var onContinue: (ChatThread) -> Void
    var onOpenPane: (ChatThread) -> Void

    private var thread: ChatThread? {
        threads.first { $0.id == selected } ?? threads.first
    }

    private var turns: [(Entry, URL)] {
        guard let id = thread?.id else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: History.all().map { ($0.0.id, $0.1) })
        return Threads.turns(id).compactMap { e in byID[e.id].map { (e, $0) } }
    }

    var body: some View {
        HSplitView {
            List(selection: $selected) {
                ForEach(threads, id: \.id) { t in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                        Text(t.lastUsed.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        if Ownership.isTakenOver(t.id) {
                            Text("yours in cmux").font(.system(size: 10)).foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 3)
                    .tag(t.id)
                }
            }
            .frame(minWidth: 220, idealWidth: 250, maxWidth: 320)

            VStack(spacing: 0) {
                if let t = thread {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                            Text("\(turns.count) message\(turns.count == 1 ? "" : "s") · session \(t.id.prefix(8))")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Watch in cmux") { onOpenPane(t) }
                            .help("Open the background pane that follows this thread")
                        Button("Continue in Claude Code") { onContinue(t) }
                            .keyboardShortcut(.defaultAction)
                            .help("Opens a cmux pane running samepage and this Claude Code session")
                    }
                    .padding(14)
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(turns, id: \.0.id) { turn, dir in
                                TurnView(entry: turn, dir: dir) { text in
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(text, forType: .string)
                                    copied = true
                                }
                            }
                            if turns.isEmpty {
                                Text("Nothing recorded in this thread yet.")
                                    .foregroundStyle(.secondary).padding(.top, 30)
                            }
                        }
                        .padding(14)
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "text.bubble").font(.system(size: 30)).foregroundStyle(.tertiary)
                        Text("No threads yet. Press \(Config.hotKeyLabel) and ask for something.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 460)
        }
        .frame(minWidth: 760, minHeight: 460)
        .onAppear { threads = Threads.all(); selected = selected ?? threads.first?.id }
        .overlay(alignment: .bottom) {
            if copied {
                Text("Copied").padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(.thinMaterial)).padding(.bottom, 14)
                    .task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
            }
        }
    }
}

@MainActor
final class HistoryWindowController {
    private var window: NSWindow?
    var onContinue: ((ChatThread) -> Void)?
    var onOpenPane: ((ChatThread) -> Void)?

    func present() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            w.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = HistoryView(
            onContinue: { [weak self] t in self?.onContinue?(t) },
            onOpenPane: { [weak self] t in self?.onOpenPane?(t) })
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        host.frame = CGRect(x: 0, y: 0, width: 900, height: 560)
        let w = NSWindow(contentRect: host.frame,
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Remote — History"
        w.contentView = host
        w.center()
        w.isReleasedWhenClosed = false
        window = w
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }
}
