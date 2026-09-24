// MCP server inside the Remote binary (`Remote --mcp-server`).
// JSON-RPC 2.0, one message per line on stdin/stdout. Logs go to stderr
// and ~/Library/Logs/Remote.log, never to stdout.
//
// UI (approval, spoken progress) goes through a Unix socket to the running
// app. Headless runs pass `--approve deny` and never touch that socket.

import AppKit
import Darwin
import Foundation

// MARK: - Safety

/// Tiers from the build contract, enforced here rather than only in the prompt.
enum Safety {
    enum Decision: Equatable {
        case allow
        case ask(String)
    }

    static func decide(tool: String, input: [String: Any]) -> Decision {
        let blob = jsonCompact(["tool": tool, "input": input])
        if isTier3(blob) { return .ask(question(tool: tool, input: input)) }
        if tool == "Bash" || tool == "bash" {
            return bash(input["command"] as? String ?? "")
        }
        if tool == "Read" || tool == "Glob" || tool == "Grep" || tool == "WebFetch" || tool == "WebSearch" {
            return .allow
        }
        // Chrome integration: playing and clicking are free; posting, buying,
        // sending, and injected page scripts still ask.
        if tool.hasPrefix("mcp__claude-in-chrome__") || tool.hasPrefix("mcp__Claude_in_Chrome__") {
            if tool.contains("javascript") { return .ask(question(tool: tool, input: input)) }
            return .allow
        }
        return .ask(question(tool: tool, input: input))
    }

    /// Allowlisted Bash runs with no prompt. Anything with a substitution,
    /// a file redirect, a tier-3 word, or a command outside the list asks.
    static func bash(_ command: String) -> Decision {
        if isTier3(command) { return .ask(question(tool: "Bash", input: ["command": command])) }
        let parts = segments(command)
        if parts.isEmpty { return .ask("Allow this command?") }
        for part in parts {
            if !segmentIsAllowlisted(part) {
                return .ask(question(tool: "Bash", input: ["command": command]))
            }
        }
        return .allow
    }

    static func applescriptIsFree(_ script: String) -> Bool {
        let s = script.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return false }
        if isTier3(s) || hasMutation(s) { return false }
        let lower = s.lowercased()
        let reads = ["activate", "get ", "name of", "count ", "exists", "properties", "return ", "front window", "front document"]
        return reads.contains { lower.contains($0) }
    }

    static func question(tool: String, input: [String: Any]) -> String {
        let blob = jsonCompact(input)
        let lower = blob.lowercased()
        if lower.contains("send") || lower.contains("mail") {
            let raw = input.values.compactMap { $0 as? String }.joined(separator: "\n")
            if let name = recipientName(in: blob + "\n" + raw) { return "Send this to \(name)?" }
            return "Send this?"
        }
        if lower.contains("git push") || lower.contains("\"push\"") { return "Push this?" }
        if lower.range(of: #"\brm\b"#, options: .regularExpression) != nil { return "Delete this?" }
        if lower.contains("sudo") { return "Run this as admin?" }
        if lower.contains("system settings") || lower.contains("system preferences") { return "Change this setting?" }
        if tool == "Bash", let cmd = input["command"] as? String {
            let short = cmd.count > 60 ? String(cmd.prefix(60)) + "…" : cmd
            return "Allow \(short)?"
        }
        return "Allow \(tool)?"
    }

    /// Nil when the rules hold.
    static func selfCheck() -> String? {
        func bashAllow(_ c: String) -> Bool { if case .allow = bash(c) { return true }; return false }
        let cases: [(Bool, String)] = [
            (bashAllow("ls -la"), "ls"),
            (bashAllow("open ~/Downloads"), "open"),
            (bashAllow("mdfind kind:pdf"), "mdfind"),
            (bashAllow("cmux list-workspaces"), "cmux list"),
            (bashAllow("osascript -e 'tell application \"Finder\" to activate'"), "activate"),
            (bashAllow("head -n 5 ~/x"), "head"),
            (!bashAllow("rm -rf /tmp/x"), "rm"),
            (!bashAllow("ls && rm x"), "chained rm"),
            (!bashAllow("ls $(rm x)"), "substitution"),
            (!bashAllow("sudo ls"), "sudo"),
            (!bashAllow("git push"), "git push"),
            (!bashAllow("cat x > /tmp/out"), "redirect"),
            (!bashAllow("osascript send.scpt"), "osascript file"),
            (applescriptIsFree("tell application \"Finder\" to activate"), "as activate"),
            (applescriptIsFree("tell application \"Finder\" to get name of front window"), "as get"),
            (applescriptIsFree("tell application \"Finder\"\nset n to name of front window\nreturn n\nend tell"), "as local set"),
            (!applescriptIsFree("tell application \"Mail\" to send message 1"), "as send"),
            (!applescriptIsFree("tell application \"System Events\" to keystroke \"a\""), "as keystroke"),
            (!applescriptIsFree("tell application \"Finder\" to delete file \"x\""), "as delete"),
            (question(tool: "run_applescript", input: ["script": "tell application \"Microsoft Outlook\"\nmake new recipient with properties {name:\"Ankit Pandey\"}\nsend newMsg\nend tell"]) == "Send this to Ankit?", "send question"),
        ]
        let bad = cases.filter { !$0.0 }.map(\.1)
        return bad.isEmpty ? nil : "safety mismatch: \(bad.joined(separator: ", "))"
    }

    // MARK: internals

    static func isTier3(_ text: String) -> Bool {
        let pattern = #"\b(sudo|srm|unlink|sendmail)\b|\brm\b|\bmv\b|\bgit\s+push\b|\b(checkout|purchase)\b|\btrash\b"#
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func hasMutation(_ script: String) -> Bool {
        let lower = script.lowercased()
        let banned = ["keystroke", "key code", "click ", " click", "delete ", " move ", "duplicate ",
                      "send ", "reply ", "do shell script", "make new", " save", "quit", "close",
                      "open location", "empty trash", "restart", "shutdown", "eject "]
        if banned.contains(where: { lower.contains($0) }) { return true }
        let prop = #"set\s+(the\s+)?(name|value|text|contents|position|bounds|size|minimized|zoomed|index|visible|title)\s+of"#
        return lower.range(of: prop, options: .regularExpression) != nil
    }

    /// Matches "to Ankit" and an AppleScript recipient `name:"Ankit Pandey"`, including once JSON-escaped.
    private static func recipientName(in blob: String) -> String? {
        let patterns = [
            #"\bto\s+([A-Z][A-Za-z]+)"#,
            #"name:\s*\\?"([A-Z][a-z]+)"#,
        ]
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(blob.startIndex..., in: blob)
            guard let m = re.firstMatch(in: blob, range: range), m.numberOfRanges > 1,
                  let r = Range(m.range(at: 1), in: blob) else { continue }
            let name = String(blob[r])
            if let kept = keepRecipient(name) { return kept }
        }
        return nil
    }

    private static func keepRecipient(_ name: String) -> String? {
        let skip: Set = ["The", "This", "Mail", "Message", "Recipient", "Application", "Outlook", "Microsoft"]
        return skip.contains(name) ? nil : name
    }

    static func segments(_ command: String) -> [String] {
        var parts: [String] = []
        var cur = ""
        var quote: Character?
        var i = command.startIndex
        while i < command.endIndex {
            let c = command[i]
            if let q = quote {
                cur.append(c)
                if c == q { quote = nil }
                i = command.index(after: i)
                continue
            }
            if c == "'" || c == "\"" {
                quote = c
                cur.append(c)
                i = command.index(after: i)
                continue
            }
            if c == "\\" {
                cur.append(c)
                let n = command.index(after: i)
                if n < command.endIndex {
                    cur.append(command[n])
                    i = command.index(after: n)
                } else { i = n }
                continue
            }
            let n = command.index(after: i)
            let two = (c == "&" || c == "|") && n < command.endIndex && command[n] == c
            if c == "\n" || c == ";" || c == "|" || c == "&" {
                parts.append(cur)
                cur = ""
                i = two ? command.index(after: n) : n
                continue
            }
            cur.append(c)
            i = n
        }
        parts.append(cur)
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func segmentIsAllowlisted(_ segment: String) -> Bool {
        if segment.contains("$(") || segment.contains("`") || segment.contains("<(") { return false }
        let stripped = segment.replacingOccurrences(of: "2>&1", with: "")
            .replacingOccurrences(of: ">/dev/null", with: "")
            .replacingOccurrences(of: "2>/dev/null", with: "")
        if stripped.contains(">") { return false }
        var toks = tokens(segment)
        while let first = toks.first, first.contains("="), !first.hasPrefix("="), !first.hasPrefix("-"), toks.count > 1 {
            toks.removeFirst() // leading env assignment
        }
        guard let cmd = toks.first else { return false }
        switch cmd {
        case "open", "mdfind", "mdls", "ls", "cat", "head", "pbpaste":
            return true
        case "cmux":
            return toks.dropFirst().first?.hasPrefix("list-") == true
        case "osascript":
            return osascriptIsFree(toks)
        default:
            return false
        }
    }

    private static func osascriptIsFree(_ toks: [String]) -> Bool {
        var scripts: [String] = []
        var i = 1
        while i < toks.count {
            let t = toks[i]
            if t == "-e" {
                i += 1
                if i >= toks.count { return false }
                scripts.append(toks[i])
            } else if t == "-l" || t == "--language" {
                i += 1
            } else if t.hasPrefix("-") {
                // flag with no script text
            } else {
                return false // a script file we have not read
            }
            i += 1
        }
        guard !scripts.isEmpty else { return false }
        return applescriptIsFree(scripts.joined(separator: "\n"))
    }

    static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quote: Character?
        for c in s {
            if let q = quote {
                if c == q { quote = nil } else { cur.append(c) }
                continue
            }
            if c == "'" || c == "\"" { quote = c; continue }
            if c == " " || c == "\t" {
                if !cur.isEmpty { out.append(cur); cur = "" }
                continue
            }
            cur.append(c)
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}

// MARK: - Socket between the MCP process and the app

enum AgentSocket {
    static var path: String { Config.supportDir.appendingPathComponent("agent.sock").path }

    static func call(op: String, fields: [String: Any], timeout: TimeInterval) -> [String: Any]? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        guard connectUnix(fd, path) else { return nil }
        setTimeout(fd, timeout)
        var body: [String: Any] = ["op": op]
        for (k, v) in fields { body[k] = v }
        guard var data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        data.append(10)
        let wrote = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard wrote == data.count else { return nil }
        guard let line = readLine(fd, limit: 1024 * 1024) else { return nil }
        return jsonObject(line)
    }

    fileprivate static func connectUnix(_ fd: Int32, _ path: String) -> Bool {
        withAddr(path) { ptr, len in Darwin.connect(fd, ptr, len) == 0 }
    }

    fileprivate static func bindUnix(_ fd: Int32, _ path: String) -> Bool {
        unlink(path)
        return withAddr(path) { ptr, len in Darwin.bind(fd, ptr, len) == 0 }
    }

    private static func withAddr<R>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let ok = withUnsafeMutableBytes(of: &addr.sun_path) { buf -> Bool in
            let s = path.utf8CString
            guard s.count <= buf.count else { return false }
            s.withUnsafeBytes { buf.copyMemory(from: $0) }
            return true
        }
        precondition(ok, "socket path too long")
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, len) }
        }
    }

    fileprivate static func setTimeout(_ fd: Int32, _ seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    fileprivate static func readLine(_ fd: Int32, limit: Int) -> String? {
        var buf = [UInt8]()
        buf.reserveCapacity(256)
        var tmp = [UInt8](repeating: 0, count: 4096)
        while buf.count < limit {
            let n = read(fd, &tmp, tmp.count)
            if n <= 0 { return nil }
            buf.append(contentsOf: tmp.prefix(n))
            if let i = buf.firstIndex(of: 10) {
                return String(bytes: buf.prefix(upTo: i), encoding: .utf8)
            }
        }
        return nil
    }
}

/// Callbacks the running app installs. The socket thread blocks in `approve`.
final class AgentBridge: @unchecked Sendable {
    static let shared = AgentBridge()
    private let lock = NSLock()
    private var progressFn: (String) -> Void = { _ in }
    private var approveFn: (String, String) -> Bool = { _, _ in false }

    func configure(progress: @escaping (String) -> Void, approve: @escaping (String, String) -> Bool) {
        lock.lock(); progressFn = progress; approveFn = approve; lock.unlock()
    }

    func progress(_ text: String) {
        lock.lock(); let f = progressFn; lock.unlock(); f(text)
    }

    func approve(question: String, detail: String) -> Bool {
        lock.lock(); let f = approveFn; lock.unlock(); return f(question, detail)
    }
}

final class AgentSocketServer {
    static let shared = AgentSocketServer()
    private var started = false

    func start() {
        if started { return }
        started = true
        Thread.detachNewThread { self.loop() }
    }

    private func loop() {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { log("agent socket: \(errno)"); return }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        let path = AgentSocket.path
        guard AgentSocket.bindUnix(fd, path) else { log("agent socket bind failed: \(errno)"); close(fd); return }
        chmod(path, 0o600)
        guard listen(fd, 4) == 0 else { close(fd); return }
        log("agent socket listening")
        while true {
            let c = accept(fd, nil, nil)
            if c < 0 { continue }
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            AgentSocket.setTimeout(c, 70)
            if let line = AgentSocket.readLine(c, limit: 1024 * 1024), let req = jsonObject(line) {
                let reply = handle(req)
                if var data = try? JSONSerialization.data(withJSONObject: reply) {
                    data.append(10)
                    _ = data.withUnsafeBytes { write(c, $0.baseAddress, $0.count) }
                }
            }
            close(c)
        }
    }

    private func handle(_ req: [String: Any]) -> [String: Any] {
        switch req["op"] as? String {
        case "progress":
            AgentBridge.shared.progress(req["text"] as? String ?? "")
            return ["ok": true]
        case "approve":
            let q = req["question"] as? String ?? "Allow this?"
            let d = req["detail"] as? String ?? ""
            let allow = AgentBridge.shared.approve(question: q, detail: d)
            return ["ok": true, "allow": allow]
        case "frontmost":
            // The MCP child often sees loginwindow. The running app has the real one.
            let wanted = (req["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let app: NSRunningApplication?
            if let wanted, !wanted.isEmpty {
                app = NSWorkspace.shared.runningApplications.first {
                    $0.localizedName?.caseInsensitiveCompare(wanted) == .orderedSame
                        || $0.bundleIdentifier?.caseInsensitiveCompare(wanted) == .orderedSame
                }
            } else {
                app = NSWorkspace.shared.frontmostApplication
            }
            guard let app else { return ["ok": false] }
            return ["ok": true, "name": app.localizedName ?? "", "bundle": app.bundleIdentifier ?? "", "pid": Int(app.processIdentifier)]
        default:
            return ["ok": false]
        }
    }
}

// MARK: - Server

struct MCPOptions {
    var approve = "ask"   // "ask" or "deny"
    var threadDir: URL?
    var trace: URL?

    static func parse(_ args: [String]) -> MCPOptions {
        var o = MCPOptions()
        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if let a = value(after: "--approve") { o.approve = a }
        if let d = value(after: "--thread-dir") { o.threadDir = URL(fileURLWithPath: d) }
        if let t = value(after: "--trace") { o.trace = URL(fileURLWithPath: t) }
        return o
    }
}

enum MCPServer {
    static func serve(_ args: [String]) -> Never {
        signal(SIGPIPE, SIG_IGN)
        let options = MCPOptions.parse(args)
        Thread.detachNewThread {
            Server(options: options).loop()
            fflush(stdout)
            exit(0)
        }
        dispatchMain()
    }

    /// Spawns this binary as the server, lists tools, calls spotlight and say_progress.
    static func selfTest() -> Int32 {
        if let problem = Safety.selfCheck() {
            print(problem)
            return 1
        }
        if let problem = Control.coordinateCheck() {
            print("coord: \(problem)")
            return 1
        }
        if NSScreen.screens.first != nil { print("coord: ok") }
        print("safety: ok")
        let exe = Agent.executablePath()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("remote-mcp-selftest-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["--mcp-server", "--approve", "deny", "--thread-dir", dir.path]
        let input = Pipe(), output = Pipe(), err = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = err
        do { try p.run() } catch {
            print("mcp-selftest failed to spawn: \(error)")
            return 1
        }
        let client = MCPClient(write: input.fileHandleForWriting, read: output.fileHandleForReading)
        var failures: [String] = []
        do {
            let initR = try client.request(method: "initialize", params: [
                "protocolVersion": "2024-11-05",
                "capabilities": [:],
                "clientInfo": ["name": "remote-selftest", "version": "0.1.0"],
            ])
            let ver = (initR["serverInfo"] as? [String: Any])?["name"] as? String
            if ver != "remote" { failures.append("initialize name \(ver ?? "nil")") }
            client.notify(method: "notifications/initialized")
            let listed = try client.request(method: "tools/list", params: [:])
            let tools = (listed["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            print("tools: \(tools.joined(separator: ", "))")
            for name in ["approve", "say_progress", "open_target", "spotlight", "run_applescript", "cmux_handoff", "screenshot",
                          "click", "type_text", "key", "scroll", "ax_tree"] {
                if !tools.contains(name) { failures.append("missing tool \(name)") }
            }
            let spot = try client.call("spotlight", ["query": "kMDItemFSName == 'CLAUDE.md'c"])
            if spot.isError { failures.append("spotlight error: \(spot.text.prefix(200))") }
            else if spot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { failures.append("spotlight empty") }
            else { print("spotlight: \(spot.text.split(separator: "\n").prefix(3).joined(separator: " | "))") }
            let said = try client.call("say_progress", ["text": "mcp selftest"])
            if said.isError || !said.text.contains("mcp selftest") { failures.append("say_progress: \(said.text.prefix(200))") }
            else { print("say_progress: \(said.text)") }
            let denied = try client.call("approve", ["tool_name": "Bash", "input": ["command": "osascript -e 'tell application \"Mail\" to send message 1'"]])
            if !denied.text.contains("\"behavior\":\"deny\"") && !denied.text.contains("\"behavior\": \"deny\"") {
                failures.append("approve did not deny send: \(denied.text.prefix(200))")
            } else { print("approve deny: ok") }
            let allowed = try client.call("approve", ["tool_name": "Bash", "input": ["command": "open ~/Downloads"]])
            if !allowed.text.contains("\"behavior\":\"allow\"") && !allowed.text.contains("\"behavior\": \"allow\"") {
                failures.append("approve did not allow open: \(allowed.text.prefix(200))")
            } else { print("approve allow: ok") }
            let click = try client.call("click", ["x": 10, "y": 10, "display": 1])
            if !click.isError || !click.text.localizedCaseInsensitiveContains("denied") {
                failures.append("headless click was not denied: \(click.text.prefix(160))")
            } else { print("click headless deny: ok") }
            let tree = try client.call("ax_tree", [:])
            let preview = tree.text.replacingOccurrences(of: "\n", with: " | ")
            print("ax_tree: \(preview.prefix(140))")
        } catch {
            failures.append("\(error)")
        }
        p.terminate()
        if !failures.isEmpty {
            let e = String(data: err.fileHandleForReading.readData(ofLength: 4000), encoding: .utf8) ?? ""
            print("mcp-selftest failed: \(failures.joined(separator: "; "))")
            if !e.isEmpty { print("stderr: \(e.prefix(500))") }
            return 1
        }
        print("mcp-selftest: ok")
        return 0
    }
}

struct ToolResult { var text: String; var isError: Bool }

private final class Server {
    let options: MCPOptions
    private let speaker = Speaker()

    init(options: MCPOptions) { self.options = options }

    func loop() {
        let fh = FileHandle.standardInput
        var buf = Data()
        while true {
            let chunk = fh.availableData
            if chunk.isEmpty { break }
            buf.append(chunk)
            while let nl = buf.firstIndex(of: 10) {
                let line = buf.prefix(upTo: nl)
                buf.removeSubrange(...nl)
                guard !line.isEmpty, let msg = jsonObject(Data(line)) else { continue }
                if let reply = handle(msg), var data = try? JSONSerialization.data(withJSONObject: reply) {
                    data.append(10)
                    FileHandle.standardOutput.write(data)
                    fflush(stdout)
                }
            }
        }
    }

    private func handle(_ msg: [String: Any]) -> [String: Any]? {
        guard let id = msg["id"] else { return nil } // notification
        let method = msg["method"] as? String ?? ""
        switch method {
        case "initialize":
            let params = msg["params"] as? [String: Any] ?? [:]
            let ver = params["protocolVersion"] as? String ?? "2024-11-05"
            return rpc(id, [
                "protocolVersion": ver,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "remote", "version": "0.1.0"],
            ])
        case "ping":
            return rpc(id, [:])
        case "tools/list":
            return rpc(id, ["tools": toolDefs()])
        case "tools/call":
            let params = msg["params"] as? [String: Any] ?? [:]
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            let result = call(name, args)
            return rpc(id, ["content": [["type": "text", "text": result.text]], "isError": result.isError])
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]]
        }
    }

    private func rpc(_ id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func toolDefs() -> [[String: Any]] {
        let tools: [[String: Any]] = [
            tool("approve", "Permission check. Returns JSON with behavior allow or deny.", [
                "tool_name": str("The tool asking permission"),
                "input": obj("The tool input"),
                "tool_use_id": str("Tool use id"),
            ], required: ["tool_name", "input"]),
            tool("say_progress", "Speak one short line (under eight words) and show it. The next line cuts this one off.", [
                "text": str("Words to speak"),
            ], required: ["text"]),
            tool("open_target", "Open a file, folder, URL, or application. Use reveal true to show the file in Finder. Does not ask.", [
                "target": str("Path, URL, or app name"),
                "reveal": boolProp("Reveal in Finder instead of opening"),
            ], required: ["target"]),
            tool("spotlight", "Search with mdfind. Returns the top 10 matches with paths and last-used dates, newest first.", [
                "query": str("Spotlight query, such as pricing deck or kMDItemDisplayName == '*deck*'c"),
                "kind": str("Optional kind filter, such as pdf or presentation"),
                "days": num("Only items used in the last N days"),
            ], required: ["query"]),
            tool("run_applescript", "Run an AppleScript. Activating an app or reading its state needs no approval. Sending, deleting, clicking, or changing things asks first.", [
                "script": str("AppleScript source"),
            ], required: ["script"]),
            tool("cmux_handoff", "Start a Claude Code session in a new cmux workspace and return immediately. Falls back to Terminal.", [
                "cwd": str("Working directory"),
                "task": str("The task Claude should start on"),
                "name": str("Workspace name"),
            ], required: ["cwd", "task"]),
            tool("screenshot", "Take a fresh screenshot of one display or all of them. Returns file paths and pixel sizes. Coordinates for later clicks are pixels in these images.", [
                "display": num("1-based display index. Omit for every display."),
            ], required: []),
        ]
        return tools + Control.toolDefs()
    }

    private func call(_ name: String, _ args: [String: Any]) -> ToolResult {
        switch name {
        case "approve": return ToolResult(text: approveTool(args), isError: false)
        case "say_progress": return sayProgress(args)
        case "open_target": return openTarget(args)
        case "spotlight": return spotlight(args)
        case "run_applescript": return runAppleScript(args)
        case "cmux_handoff": return cmuxHandoff(args)
        case "screenshot": return screenshot(args)
        default:
            if let extra = Control.perform(name, args, confirm: { self.confirm(question: $0, detail: $1) }, allowInput: options.approve != "deny") {
                return extra
            }
            trace("tool \(name) decision=error unknown")
            return ToolResult(text: "Unknown tool \(name)", isError: true)
        }
    }

    private func approveTool(_ args: [String: Any]) -> String {
        let toolName = args["tool_name"] as? String ?? ""
        let input = args["input"] as? [String: Any] ?? [:]
        let decision = Safety.decide(tool: toolName, input: input)
        switch decision {
        case .allow:
            trace("tool approve \(toolName) decision=allow")
            return decisionJSON(allow: true, input: input, message: nil)
        case .ask(let question):
            let detail = jsonCompact(input)
            if confirm(question: question, detail: detail) {
                trace("tool approve \(toolName) decision=allow question=\(question)")
                return decisionJSON(allow: true, input: input, message: nil)
            }
            trace("tool approve \(toolName) decision=deny question=\(question)")
            return decisionJSON(allow: false, input: nil, message: "The user said no. Do not do this.")
        }
    }

    private func decisionJSON(allow: Bool, input: [String: Any]?, message: String?) -> String {
        var obj: [String: Any]
        if allow {
            obj = ["behavior": "allow", "updatedInput": input ?? [:], "decisionClassification": "user_temporary"]
        } else {
            obj = ["behavior": "deny", "message": message ?? "The user said no.", "decisionClassification": "user_reject"]
        }
        return jsonCompact(obj)
    }

    /// Asks the person, unless this run is headless (`--approve deny`), which denies.
    private func confirm(question: String, detail: String) -> Bool {
        if options.approve == "deny" {
            trace("approve auto-deny: \(question)")
            return false
        }
        let reply = AgentSocket.call(op: "approve", fields: ["question": question, "detail": String(detail.prefix(500))], timeout: 65)
        return reply?["allow"] as? Bool ?? false
    }

    private func sayProgress(_ args: [String: Any]) -> ToolResult {
        let text = ((args["text"] as? String) ?? (args["message"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return ToolResult(text: "Missing text", isError: true) }
        let line = text.count > 180 ? String(text.prefix(180)) : text
        trace("tool say_progress \(line) decision=allow")
        if options.approve == "ask" {
            let sent = AgentSocket.call(op: "progress", fields: ["text": line], timeout: 3)
            if sent == nil { speaker.speak(text: line) }
        }
        return ToolResult(text: "Said: \(line)", isError: false)
    }

    private func openTarget(_ args: [String: Any]) -> ToolResult {
        let target = (args["target"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return ToolResult(text: "Missing target", isError: true) }
        let reveal = args["reveal"] as? Bool ?? false
        trace("tool open_target \(target) reveal=\(reveal) decision=allow")
        var argv: [String] = []
        if reveal { argv.append("-R") }
        let expanded = (target as NSString).expandingTildeInPath
        let isURL = expanded.contains("://")
        let exists = FileManager.default.fileExists(atPath: expanded)
        if !reveal && !isURL && !expanded.contains("/") && !exists {
            argv.append(contentsOf: ["-a", target])
        } else {
            argv.append(expanded)
        }
        let ran = Shell.run("/usr/bin/open", argv, timeout: 15)
        if ran.status != 0 {
            return ToolResult(text: "open failed: \(ran.stderr.prefix(300))", isError: true)
        }
        return ToolResult(text: "Opened \(target)", isError: false)
    }

    private func spotlight(_ args: [String: Any]) -> ToolResult {
        let query = (args["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return ToolResult(text: "Missing query", isError: true) }
        trace("tool spotlight \(query) decision=allow")
        var q = query
        if let kind = args["kind"] as? String, !kind.isEmpty, !q.lowercased().contains("kind:") {
            q += " && kind:\(kind)"
        }
        if let days = number(args["days"]), days > 0 {
            q += " && kMDItemLastUsedDate >= $time.today(-\(Int(days)))"
        }
        let ran = Shell.run("/usr/bin/mdfind", ["-attr", "kMDItemLastUsedDate", q], timeout: 25)
        if ran.status != 0 {
            return ToolResult(text: "mdfind failed: \(ran.stderr.prefix(300))", isError: true)
        }
        var hits: [(path: String, used: Date?)] = []
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        for raw in ran.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            let path: String
            let used: Date?
            if let range = line.range(of: "kMDItemLastUsedDate") {
                path = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let rest = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                let value = rest.hasPrefix("=") ? rest.dropFirst().trimmingCharacters(in: .whitespaces) : rest
                if value == "(null)" || value.isEmpty { used = nil }
                else { used = df.date(from: String(value)) }
            } else {
                path = line.trimmingCharacters(in: .whitespaces)
                used = nil
            }
            guard !path.isEmpty else { continue }
            hits.append((path, used))
        }
        hits.sort { a, b in
            switch (a.used, b.used) {
            case let (x?, y?): return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.path < b.path
            }
        }
        let top = hits.prefix(10)
        if top.isEmpty { return ToolResult(text: "No matches.", isError: false) }
        let lines = top.enumerated().map { i, hit -> String in
            let when = hit.used.map { df.string(from: $0) } ?? "unknown"
            return "\(i + 1). \(hit.path)\n   last used: \(when)"
        }
        return ToolResult(text: lines.joined(separator: "\n"), isError: false)
    }

    private func runAppleScript(_ args: [String: Any]) -> ToolResult {
        let script = args["script"] as? String ?? ""
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ToolResult(text: "Missing script", isError: true)
        }
        if Safety.applescriptIsFree(script) {
            trace("tool run_applescript decision=allow")
        } else {
            let q = Safety.question(tool: "run_applescript", input: ["script": script])
            if !confirm(question: q, detail: script) {
                trace("tool run_applescript decision=deny")
                return ToolResult(text: "Denied. The script did not run.", isError: true)
            }
            trace("tool run_applescript decision=allow-after-ask")
        }
        let ran = Shell.run("/usr/bin/osascript", ["-e", script], timeout: 30)
        let text = (ran.stdout + ran.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        if ran.status != 0 { return ToolResult(text: "osascript failed: \(text.prefix(500))", isError: true) }
        return ToolResult(text: text.isEmpty ? "Done." : String(text.prefix(2000)), isError: false)
    }

    private func cmuxHandoff(_ args: [String: Any]) -> ToolResult {
        let cwd = ((args["cwd"] as? String ?? "") as NSString).expandingTildeInPath
        let task = args["task"] as? String ?? ""
        let name = (args["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? (args["name"] as? String)! : "Remote"
        guard !cwd.isEmpty, !task.isEmpty else { return ToolResult(text: "Need cwd and task", isError: true) }
        trace("tool cmux_handoff cwd=\(cwd) decision=allow")
        let command = "claude \(shellQuote(task))"
        let cmux = "/Applications/cmux.app/Contents/Resources/bin/cmux"
        if FileManager.default.isExecutableFile(atPath: cmux) {
            let ran = Shell.run(cmux, ["new-workspace", "--name", name, "--cwd", cwd, "--command", command], timeout: 8)
            if ran.status == 0 {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/cmux.app"))
                return ToolResult(text: "Started it in cmux.", isError: false)
            }
            log("cmux handoff failed: \(ran.stderr.prefix(200))")
        }
        let cd = shellQuote(cwd)
        let source = "tell application \"Terminal\" to do script \"cd \(cd) && \(command)\"\ntell application \"Terminal\" to activate"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if error != nil {
            return ToolResult(text: "Could not open a terminal for the handoff.", isError: true)
        }
        return ToolResult(text: "Started it in Terminal.", isError: false)
    }

    private func screenshot(_ args: [String: Any]) -> ToolResult {
        trace("tool screenshot decision=allow")
        let want = number(args["display"]).map { Int($0) }
        var shots: [DisplayShot] = []
        var captureError: String?
        let sem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            do { shots = try await Capture.allDisplays() }
            catch { captureError = error.localizedDescription }
            sem.signal()
        }
        if sem.wait(timeout: .now() + 25) == .timedOut {
            return ToolResult(text: "Screenshot timed out", isError: true)
        }
        if let captureError { return ToolResult(text: "Screenshot failed: \(captureError)", isError: true) }
        if let want { shots = shots.filter { $0.index == want } }
        guard !shots.isEmpty else { return ToolResult(text: "No displays.", isError: true) }
        let dir = options.threadDir ?? Config.supportDir.appendingPathComponent("captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var lines: [String] = []
        for shot in shots {
            guard let data = Compose.jpeg(shot.image) else { continue }
            let file = dir.appendingPathComponent("live-\(shot.index)-\(Int(Date().timeIntervalSince1970)).jpg")
            try? data.write(to: file)
            lines.append("display \(shot.index): \(file.path) (\(shot.image.width)x\(shot.image.height) pixels, scale \(shot.scale))")
        }
        guard !lines.isEmpty else { return ToolResult(text: "Could not save screenshots.", isError: true) }
        return ToolResult(text: lines.joined(separator: "\n"), isError: false)
    }

    func trace(_ line: String) {
        log(line)
        guard let url = options.trace else { return }
        let text = line + "\n"
        if FileManager.default.fileExists(atPath: url.path), let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(text.data(using: .utf8)!)
            try? h.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

func tool(_ name: String, _ description: String, _ props: [String: Any], required: [String]) -> [String: Any] {
    [
        "name": name,
        "description": description,
        "inputSchema": [
            "type": "object",
            "properties": props,
            "required": required,
        ],
    ]
}
func str(_ d: String) -> [String: Any] { ["type": "string", "description": d] }
func boolProp(_ d: String) -> [String: Any] { ["type": "boolean", "description": d] }
func num(_ d: String) -> [String: Any] { ["type": "number", "description": d] }
func obj(_ d: String) -> [String: Any] { ["type": "object", "description": d] }

func number(_ value: Any?) -> Double? {
    if let n = value as? NSNumber { return n.doubleValue }
    if let s = value as? String { return Double(s) }
    return nil
}

func jsonObject(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}
func jsonObject(_ s: String) -> [String: Any]? {
    jsonObject(Data(s.utf8))
}
func jsonCompact(_ obj: Any) -> String {
    guard JSONSerialization.isValidJSONObject(obj),
          let d = try? JSONSerialization.data(withJSONObject: obj),
          let s = String(data: d, encoding: .utf8) else { return String(describing: obj) }
    return s
}

private func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

enum Shell {
    struct Output { var status: Int32; var stdout: String; var stderr: String }
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval) -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch {
            return Output(status: 127, stdout: "", stderr: error.localizedDescription)
        }
        let timed = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timed)
        let group = DispatchGroup()
        var oData = Data(), eData = Data()
        group.enter()
        DispatchQueue.global().async { oData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { eData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.wait()
        p.waitUntilExit()
        timed.cancel()
        return Output(status: p.terminationStatus,
                      stdout: String(data: oData, encoding: .utf8) ?? "",
                      stderr: String(data: eData, encoding: .utf8) ?? "")
    }
}

private final class MCPClient {
    let write: FileHandle
    let read: FileHandle
    private var next = 1
    private var buf = Data()

    init(write: FileHandle, read: FileHandle) {
        self.write = write
        self.read = read
    }

    func request(method: String, params: [String: Any]) throws -> [String: Any] {
        let id = next; next += 1
        try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let msg = try readMessage()
        if let err = msg["error"] { throw NSError(domain: "Remote", code: 4, userInfo: [NSLocalizedDescriptionKey: "\(err)"]) }
        return msg["result"] as? [String: Any] ?? [:]
    }

    func notify(method: String) {
        try? send(["jsonrpc": "2.0", "method": method])
    }

    func call(_ name: String, _ args: [String: Any]) throws -> ToolResult {
        let result = try request(method: "tools/call", params: ["name": name, "arguments": args])
        let content = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        let isError = result["isError"] as? Bool ?? false
        return ToolResult(text: content, isError: isError)
    }

    private func send(_ obj: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: obj)
        data.append(10)
        try write.write(contentsOf: data)
    }

    private func readMessage() throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let nl = buf.firstIndex(of: 10) {
                let line = buf.prefix(upTo: nl)
                buf.removeSubrange(...nl)
                if line.isEmpty { continue }
                if let obj = jsonObject(Data(line)) { return obj }
            }
            let chunk = read.availableData
            if chunk.isEmpty { break }
            buf.append(chunk)
        }
        throw NSError(domain: "Remote", code: 5, userInfo: [NSLocalizedDescriptionKey: "no MCP response"])
    }
}
