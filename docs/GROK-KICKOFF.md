You are the builder for this repository. Claude (Opus) wrote the contract and will review; you do most of the work.

1. Run `samepage --task "Build M1 of docs/BUILD-CONTRACT.md"` and read the digest.
2. Read CLAUDE.md, then docs/BUILD-CONTRACT.md in full. The contract is the spec. CLAUDE.md's rules override it.
3. Implement milestone M1, then M2, on the current branch `operator-agent`. Small commits that each build. Never push, never touch main, never force-push.
4. Before claiming anything works: `./build.sh` must succeed, `--selftest`, `--selftest-agent` and `--mcp-selftest` must pass, and you must say exactly what you ran and what you saw.
5. Do not send synthetic keyboard or mouse events. Scenarios that need a person are left for Claude and Shreyas; list them.
6. At each milestone gate: append an entry to section 10 of the contract (what was built, what was tested and how, what is unverified), commit it, and run `samepage wip "M<n> gate reached"`. After the M2 gate, stop. Do not start M3.
7. If something in the contract is wrong or impossible, write it in the handoff log and choose the smallest sound fix. Only stop for an open question from section 9.
