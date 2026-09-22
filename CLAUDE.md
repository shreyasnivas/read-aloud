# Read Aloud

A macOS menu bar app. Press ⌥⇧A to freeze every display under an overlay,
scribble on it to point at something, ask out loud, and hear Claude's answer.
Follow-ups stay in a thread. Open source (MIT) at github.com/shreyasnivas/read-aloud.

## Layout

```
Sources/main.swift     core: hotkeys, capture, overlay, transcription, Claude, speech,
                       history/threads, App controller, self-test, entry point
Sources/UI.swift       SwiftUI: UIModel, listening HUD, answer card, Settings window,
                       permissions, Claude Code login check
Resources/AppIcon.icns app icon (generated, don't hand-edit)
tools/make-icon.swift  renders the icon: swift tools/make-icon.swift Resources/AppIcon.icns
Info.plist             LSUIElement app, mic + speech usage strings
build.sh               swiftc build → sign → install to /Applications → launch
tools/make-signing-cert.sh  one-time local signing certificate (keeps permissions across builds)
```

No Xcode project and no dependencies: just the command line tools and system
frameworks (AppKit, SwiftUI, ScreenCaptureKit, Speech, AVFoundation, Carbon).

## Build, run, test

```bash
./build.sh                  # build, install to /Applications, relaunch
./build.sh --no-install     # build only, into build/
"build/Read Aloud.app/Contents/MacOS/ReadAloud" --selftest "What's in the red circle?"
                            # headless: capture, fake mark, two-turn thread via claude -p
open -n "/Applications/Read Aloud.app" --args --transcribe-file x.aiff   # writes x.aiff.txt
"…/MacOS/ReadAloud" --settings   # open Settings at launch (debugging layout)
```

Log: `~/Library/Logs/ReadAloud.log`. The first line at each launch records the
state of all three permissions. Crash reports:
`~/Library/Logs/DiagnosticReports/ReadAloud-*.ips`. Delete `build/Read Aloud.app`
after installing so only one copy with the bundle id exists.

## How it works

1. A Carbon hotkey (⌥⇧A) triggers ScreenCaptureKit screenshots of each display,
   and a frozen overlay window is shown on each screen.
2. SFSpeechRecognizer transcribes on-device while you talk. The HUD shows the
   live text.
3. Return sends the annotated screenshots plus a close-up of the marks to
   `claude -p` (model `claude-opus-5`), with `--allowedTools Read`, cwd
   `~/Library/Application Support/Read Aloud/`.
4. The answer is spoken with `/usr/bin/say` (the system voice), and the answer
   card shows the thread.

**Threads** are Claude Code sessions. A new thread uses `--session-id <uuid>
--name …` and follow-ups use `--resume <uuid>`. ⌥⇧A within 15 minutes continues
the latest thread; Tab in the overlay toggles. "Open in Terminal" runs
`claude --resume <id>` in cmux (falls back to Terminal.app). `threads.json` and
`history/<timestamp>/entry.json` are Read Aloud's own record. Only the newest 3
threads are kept (`Config.historyLimit`).

**Esc** stops any speech system-wide, but only while something is speaking.
`EscapeToStop` registers the Esc hotkey during playback and releases it
afterwards. It also stops a `say` started by any tool that writes its pid to
`~/.cache/readback/say.pid` (the author uses this with a readback Claude Code skill).

## Rules that came from real failures

- **Claude subscription only, never API credits.** Answers go through
  `claude -p`. `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` are stripped from
  the child env. Don't add an API-key path back.
- **Set `READBACK_NESTED=1` for every `claude` child.** Stop hooks that speak
  recaps check it and skip the helper session instead of talking over the answer.
- **Sign with a stable identity.** `build.sh` signs with a local self-signed
  certificate (`tools/make-signing-cert.sh`; name from `SIGN_IDENTITY` or an
  untracked `.signing-identity` file). The designated requirement is the bundle id plus
  the certificate leaf, so TCC permissions survive rebuilds. Ad-hoc signing
  resets Screen Recording, Mic and Speech on every build. If permissions look
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
