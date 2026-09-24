// A visible home for every thread.
//
// A spoken request is already a Claude Code session; it just runs where nobody
// can see it. When a thread starts, Remote opens a cmux workspace for it in the
// background, unfocused, running `Remote --follow <thread>`. That follower
// prints the thread as it happens, reading Remote's own record, so you can look
// at the conversation at any point without it stealing the screen.
//
// Only one process ever writes to a Claude Code session. The follower reads;
// voice writes. Press return in the pane and the follower hands the session to
// you: it marks the thread as yours and execs `claude --resume <id>`. From then
// on Remote leaves that thread alone and a spoken request starts a new one.

import Foundation

enum ThreadPane {
    static let cmux = "/Applications/cmux.app/Contents/Resources/bin/cmux"

    /// Off with `defaults write dev.readaloud.ReadAloud threadPane -bool false`.
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: "threadPane") as? Bool ?? true
    }

    private static var paneFile: URL { Config.supportDir.appendingPathComponent("panes.json") }
    private static let lock = NSLock()

    private static func panes() -> [String: String] {
        guard let d = try? Data(contentsOf: paneFile),
              let m = try? JSONDecoder().decode([String: String].self, from: d) else { return [:] }
        return m
    }

    private static func remember(_ threadID: String, workspace: String) {
        lock.lock(); defer { lock.unlock() }
        var m = panes()
        m[threadID] = workspace
        // Keep the file to the threads we still keep.
        let live = Set(Threads.all().map(\.id))
        m = m.filter { live.contains($0.key) || $0.key == threadID }
        if let d = try? JSONEncoder().encode(m) { try? d.write(to: paneFile, options: .atomic) }
    }

    /// True when that workspace is still open in cmux.
    private static func workspaceLives(_ ref: String) -> Bool {
        guard let out = Shell.run(cmux, ["list-workspaces"], timeout: 5).stdout as String? else { return false }
        return out.contains(ref)
    }

    /// Opens the thread's pane if it has none, or leaves it alone if it has.
    /// Never focuses cmux: the pane is there to be glanced at, not to interrupt.
    static func ensure(_ thread: ChatThread) {
        guard enabled, FileManager.default.isExecutableFile(atPath: cmux) else { return }
        guard !Ownership.isTakenOver(thread.id) else { return }
        if let ref = panes()[thread.id], workspaceLives(ref) { return }

        let binary = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let name = "Remote · " + thread.title.prefix(40)
        let command = "\(shellQuote(binary)) --follow \(thread.id)"
        let r = Shell.run(cmux, ["new-workspace", "--name", String(name), "--cwd", Config.supportDir.path,
                                 "--command", command, "--focus", "false"], timeout: 10)
        // cmux answers "OK workspace:3".
        if let ref = r.stdout.split(separator: " ").first(where: { $0.hasPrefix("workspace:") }) {
            remember(thread.id, workspace: String(ref))
            log("thread pane \(ref) for \(thread.id.prefix(8))")
        } else if !r.stdout.isEmpty || !r.stderr.isEmpty {
            log("thread pane failed: \(r.stdout)\(r.stderr)".trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

/// Which threads the user has taken over by typing in their pane. Remote never
/// writes to a session after that, so the two of you can't interleave.
enum Ownership {
    private static var dir: URL {
        let u = Config.supportDir.appendingPathComponent("taken-over", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func isTakenOver(_ threadID: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(threadID).path)
    }

    static func takeOver(_ threadID: String) {
        try? Data().write(to: dir.appendingPathComponent(threadID))
    }

    /// Drops markers for threads that no longer exist, so the folder can't grow.
    static func prune() {
        let live = Set(Threads.all().map(\.id))
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where !live.contains(f.lastPathComponent) {
            try? FileManager.default.removeItem(at: f)
        }
    }
}

// MARK: - The follower (`Remote --follow <thread>`)

enum Follower {
    private static let dim = "\u{1B}[2m", bold = "\u{1B}[1m", accent = "\u{1B}[36m", off = "\u{1B}[0m"

    static func run(threadID: String) -> Never {
        // Line-buffered, so the thread appears as it happens even when stdout is a pipe.
        setvbuf(stdout, nil, _IOLBF, 0)
        let thread = Threads.all().first { $0.id == threadID }
        let title = thread?.title ?? threadID
        print("\(bold)\(title)\(off)")
        print("\(dim)Claude Code session \(threadID)\(off)")
        print("\(dim)Watching this thread. Speaking to Remote adds to it.\(off)")
        print("\(dim)Press return to take it over here; Remote then leaves it to you.\(off)\n")

        // Reading a line is what hands the session over, so it waits on its own thread.
        let handOver = DispatchQueue(label: "follow.stdin")
        handOver.async {
            // A closed stdin (no terminal, or the pane went away) is not a takeover.
            guard readLine(strippingNewline: true) != nil else { return }
            Ownership.takeOver(threadID)
            print("\n\(accent)Yours now. Remote will start a new thread when you speak.\(off)\n")
            let claude = Agent.operatorBinary() ?? "claude"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: claude)
            p.arguments = ["--resume", threadID]
            p.currentDirectoryURL = Config.supportDir
            var env = ProcessInfo.processInfo.environment
            env["ANTHROPIC_API_KEY"] = nil; env["ANTHROPIC_AUTH_TOKEN"] = nil
            env["READBACK_NESTED"] = "1"
            p.environment = env
            do { try p.run() } catch {
                print("Could not start claude: \(error.localizedDescription)")
                exit(1)
            }
            p.waitUntilExit()
            exit(p.terminationStatus)
        }

        // Printed state per turn: a turn appears when it starts and is completed
        // in place once it has an answer, so nothing prints twice.
        var printed: [String: Bool] = [:]   // turn id -> final
        while true {
            for turn in Threads.turns(threadID) {
                let final = turn.answer != nil || turn.error != nil
                if printed[turn.id] == true { continue }
                if printed[turn.id] == nil {
                    let said = turn.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    print("\(accent)you\(off)  \(said.isEmpty ? "(pointed at the screen)" : said)")
                    if !final { print("\(dim)remote  working…\(off)") }
                }
                if final {
                    if let a = turn.answer { print("\(bold)remote\(off)  \(a)\n") }
                    else if let e = turn.error { print("\(dim)remote  failed: \(e)\(off)\n") }
                }
                printed[turn.id] = final
            }
            Thread.sleep(forTimeInterval: 1.0)
        }
    }
}
