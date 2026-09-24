# Remote

A macOS menu bar app. Press ⌥⇧A to freeze every display under an overlay,
scribble on it to point at something, ask out loud, and hear Claude's answer.
Follow-ups stay in a thread. Open source (MIT) at github.com/shreyasnivas/read-aloud.

## Layout

```
Sources/main.swift     core: hotkeys, capture, overlay, transcription, Claude, speech,
                       history/threads, App controller, self-test, entry point
Sources/UI.swift       SwiftUI: UIModel, listening HUD, status pill, answer card,
                       Settings window, permissions, Claude Code login check
Sources/Agent.swift    operator loop: stream-json `claude -p`, process group, cancel
Sources/MCPServer.swift  MCP server and M1 tools, safety policy, socket to the app
Sources/Control.swift  M2 clicks, typing, and the accessibility tree
Sources/ThreadPane.swift  the background cmux pane per thread, takeover, `--follow`
Resources/AppIcon.icns app icon (generated, don't hand-edit)
tools/make-icon.swift  renders the icon: swift tools/make-icon.swift Resources/AppIcon.icns
Info.plist             LSUIElement app, mic + speech usage strings
build.sh               swiftc build → sign → install to /Applications → launch
tools/make-signing-cert.sh  one-time local signing certificate (keeps permissions across builds)
```

No Xcode project and no dependencies: just the command line tools and system
frameworks (AppKit, SwiftUI, ScreenCaptureKit, Speech, AVFoundation, Carbon,
ApplicationServices).

## Build, run, test

```bash
./build.sh                  # build, install to /Applications, relaunch
./build.sh --no-install     # build only, into build/
"build/Remote.app/Contents/MacOS/Remote" --selftest "What's in the red circle?"
                            # headless question path: capture, fake mark, two-turn thread
"build/Remote.app/Contents/MacOS/Remote" --selftest-agent "Open my Downloads folder"
                            # headless operator: approve auto-denies, prints tool calls
"build/Remote.app/Contents/MacOS/Remote" --mcp-selftest
                            # MCP server lists tools, calls spotlight and say_progress
open -n "/Applications/Remote.app" --args --transcribe-file x.aiff   # writes x.aiff.txt
"…/MacOS/Remote" --settings   # open Settings at launch (debugging layout)
```

Log: `~/Library/Logs/Remote.log`. The first line at each launch records the
state of Screen Recording, Microphone, Speech Recognition, and Accessibility. Crash reports:
`~/Library/Logs/DiagnosticReports/Remote-*.ips`. Delete `build/Remote.app`
after installing so only one copy with the bundle id exists.

## How it works

1. A Carbon hotkey (⌥⇧A) triggers ScreenCaptureKit screenshots of each display,
   and a frozen overlay window is shown on each screen.
2. SFSpeechRecognizer transcribes on-device while you talk. The HUD shows the
   live text. The microphone is only open during this recording, and again
   while a task is running so “stop” or a yes/no can be heard.
3. Return closes the overlay at once. A status pill stays up. Annotated
   screenshots, plus a close-up of the marks, go to `claude -p` (model
   `claude-opus-5`) as an operator: `--output-format stream-json`, the MCP
   server in this binary, `--chrome`, and a Bash allowlist checked in code. The server's tools
   open files and apps, search with Spotlight, run AppleScript, hand a long job
   to cmux, take a fresh screenshot, and speak one progress line. It can also
   click, type, and scroll using pixels from that screenshot, and read the
   accessibility tree. System Settings asks once. Anything that
   sends, deletes, buys, or is outside that allowlist asks first; Esc or a
   spoken "stop" kills the process group. A question is still just answered.
   cwd is `~/Library/Application Support/Remote/`. Timeout is 600 seconds.
4. The final line is spoken with `/usr/bin/say` (the system voice), and the
   answer card shows the thread. Progress lines before that are spoken too;
   other assistant text is not.

**Every thread gets a pane.** When a thread starts, Remote opens a cmux workspace
for it in the background, unfocused, running `Remote --follow <thread>`. That
follower prints the conversation as it happens by reading `history/`, so the
thread is always there to look at without taking the screen. Only one process
writes to a Claude Code session: the follower reads, voice writes. Press return
in the pane and it hands over, writing `taken-over/<thread>` in the support
directory and exec'ing `claude --resume <id>`; from then on Remote leaves that
thread alone and a spoken request starts a new one. Turn it off with
`defaults write dev.readaloud.ReadAloud threadPane -bool false`.

**Threads** are Claude Code sessions. A new thread uses `--session-id <uuid>
--name …` and follow-ups use `--resume <uuid>`. ⌥⇧A within 15 minutes continues
the latest thread; Tab in the overlay toggles. "Open in Terminal" runs
`claude --resume <id>` in cmux (falls back to Terminal.app). `threads.json` and
`history/<timestamp>/entry.json` are Remote's own record. Only the newest 3
threads are kept (`Config.historyLimit`).

**Esc** stops any speech system-wide, but only while something is speaking or
the agent is working. `EscapeToStop` registers the Esc hotkey then and releases
it afterwards. While a permission question is up, Esc means no. It also stops a
`say` started by any tool that writes its pid to `~/.cache/readback/say.pid`
(the author uses this with a readback Claude Code skill).

## Rules that came from real failures

- **Claude subscription only, never API credits.** Answers go through
  `claude -p`. `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` are stripped from
  the child env. Don't add an API-key path back.
- **Set `READBACK_NESTED=1` for every `claude` child.** Stop hooks that speak
  recaps check it and skip the helper session instead of talking over the answer.
- **The safety policy has to cover every channel, not just text.** Bash and
  AppleScript text were checked while clicks, typing and `open_target` were not,
  so the agent could press Send, run a `.command` file, or press a button through
  AppleScript UI scripting (`perform action "AXPress"`) with no question asked.
  A click reads the accessibility label under the pointer and asks on
  send/delete/buy-like buttons, typing asks in a password field, `open_target`
  asks before running a file or handing a URL to a custom scheme, and reading a
  credentials path asks. Add a case to `Safety.selfCheck()` for every new rule.

- **Every one of those checks has to fail closed, and normalise first.** Three
  bypasses came from failing open: an unlabelled icon button read as "safe"
  (now it asks), `file:///…/x.command` skipped the runnable check because a
  recognised scheme returned early (now a file URL is decoded back to a path),
  and a trailing slash beat `hasSuffix(".app")`. AppleScript's own `read` and
  `POSIX file` were missed because the script check only looked for mutation,
  not for reading. A keyword list is a bar, not a boundary: a button labelled
  "Ship it" still matches nothing.

- **Approvals are authenticated and scoped.** Each launch writes a fresh secret
  to `agent.token`; the MCP children carry it and the socket refuses anything
  else, so another local process can't answer "allow" for you. The approve
  hotkey is ⌥⇧Y, never a bare Return: a global Return meant any Enter pressed
  anywhere approved the pending question. The pill shows the real command, not
  only the spoken summary.

- **The operator sees only its own tools.** `--strict-mcp-config` keeps the
  child away from the user's other MCP servers. Without it a web page it reads
  sits next to tools that can read mail and calendars.

- **The bundle id stays `dev.readaloud.ReadAloud`.** The app is called Remote; the
  identifier is not, on purpose. TCC keys the Screen Recording, Microphone, Speech
  and Accessibility grants to the bundle id, so changing it means granting all four
  again, with a relaunch for Screen Recording. Rename it only as a deliberate step.

- **Sign with a stable identity.** `build.sh` signs with a local self-signed
  certificate (`tools/make-signing-cert.sh`; name from `SIGN_IDENTITY` or an
  untracked `.signing-identity` file). The designated requirement is the bundle id plus
  the certificate leaf, so TCC permissions survive rebuilds. Ad-hoc signing
  resets Screen Recording, Microphone, Speech Recognition, and Accessibility on every build. If permissions look
  on but are refused, run `tccutil reset All dev.readaloud.ReadAloud` and
  grant again. Screen Recording needs a relaunch (Settings has Quit & Reopen).
- **Keep SwiftUI hosting views fixed-size** (`sizingOptions = []`, explicit
  frames). A self-sizing Settings window plus the 1.5s permission refresh threw
  an AppKit "Update Constraints in Window" exception loop and crashed the app.
- **Order windows front with `orderFrontRegardless()`.** As an accessory app,
  activation isn't guaranteed and windows open behind other apps.
- **Don't drive a dictation app by faking its hotkey.** An earlier version
  tapped Handy's left-Control toggle. A missed tap desynchronised it and could
  leave the mic recording in the background. Transcription is in-app on purpose.
- **Be careful with synthetic keyboard or mouse input when testing.** Events go
  to whatever is focused. A synthetic ⌥⇧A with the app not running typed "Å"
  into a terminal, and a stray Esc can interrupt a Claude session. Check that
  the app is running first, and don't do it while the user is typing.

<!-- samepage:start -->
This project uses **samepage**. Shared brain: `.samepage/`, at the main checkout, shared by every worktree. At session start run `samepage` (add `--task "<what you are about to do>"` when you know it): it prints a short digest of who else is open, what each is doing, the live memory rows and the last lessons. If OVERLAP names a pane, ask before editing those files. Write your own note early with `samepage wip`. Follow `.samepage/PROTOCOL.md`. Do not copy that protocol into this file.
<!-- samepage:end -->
