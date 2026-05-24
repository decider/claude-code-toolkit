# Claude Code Toolkit

> Hooks and daemons that make working with [Claude Code](https://claude.ai/code)
> safer and lower-friction: secrets get scrubbed off your disk before
> they leak, per-directory READMEs stay fresh for agents, and identity
> guards keep the wrong GitHub account off the wrong repo.

Each tool stands alone — install only what you want. Clone once; the
installers wire hooks into your repos and a scheduled scrubber onto your
machine.

---

## What's in here

| tool | what it does | trigger |
|---|---|---|
| **[`secret-scrub`](secret-scrub/)** | Detects + redacts secrets — Solana keys, BIP39 mnemonics, GitHub/OpenAI tokens, PEM blocks, `*_SECRET=` env vars — across **four** leak pathways | git pre-commit + scheduled scans |
| **[`docgen`](docgen/)** | Generates a one-paragraph README per directory that Claude auto-loads as context when it reads files there | git pre-push + Claude Code PreToolUse |
| **[`identity-guard`](identity-guard/)** | Blocks pushes/merges/PRs/releases under the wrong GitHub account (personal identity on a bot repo, or vice-versa) | Claude Code PreToolUse |

### The four secret leak pathways `secret-scrub` covers

Most secret scanners catch one. A secret you handle while working with an
AI agent can leak from any of these — so `secret-scrub` watches all four:

1. **Staged files** at commit time → pre-commit hook
2. **Claude session transcripts** (`~/.claude/projects/*.jsonl`) → scheduled scan
3. **Working-tree files** — uncommitted/untracked secrets the pre-commit hook never sees → scheduled scan
4. **`.git/config`** — tokenized remote URLs (`https://user:TOKEN@host`) that `git remote -v` echoes into logs → scheduled audit

Pathway 4 is the one almost everything misses, because `.git/config`
lives inside `.git/` where `git status` can't see it.

---

## Quick start — let Claude set it up

Open Claude Code and paste:

```
Help me set up the Claude Code Toolkit from
https://github.com/decider/claude-code-toolkit — I'm not a developer,
so keep it plain-English, audit it for safety first, ask before each
install, and then run it for me.
```

Claude will clone it, walk the [safety audit](docs/SAFETY.md), and
install the pieces you choose. Expected time: ~5 minutes.

## Quick start — do it yourself

```sh
git clone https://github.com/decider/claude-code-toolkit
cd claude-code-toolkit

# Read the audit first — this code handles your secrets
less docs/SAFETY.md

# Interactive installer — asks before each component, installs nothing silently
./install.sh
```

Or install one tool at a time:

```sh
./secret-scrub/install.sh          # pre-commit hook (point at any repo)
./secret-scrub/install-launchd.sh  # macOS: scan ~/.claude/projects every 30 min
                                   # (Linux: install-systemd.sh)
./docgen/install-push-hook.sh      # auto-refresh per-dir READMEs on push
./identity-guard/install.sh        # wrong-account guard
```

---

## Safety

This toolkit handles your secrets, so it's built to be **verified, not
trusted**. [`docs/SAFETY.md`](docs/SAFETY.md) is a checklist you (or
Claude) run before installing anything:

- No outbound network in the scrubber — it's local-only
- No `eval`/`exec` on the file contents it scans
- Writes only to declared paths (`.git/hooks/`, scheduler dirs, the
  files being redacted)
- Install scripts do exactly what they advertise — no hidden hooks

A clean clone passes all of them. If a fork added something the
checklist would catch, that's the signal to stop.

---

## What it will NOT do for you

- **Rotate an already-leaked secret.** If the scrubber finds a live key,
  it redacts the on-disk copy — but that key is compromised and you must
  rotate it yourself.
- **Catch secrets pasted into the browser app.** It covers the Claude
  Code CLI's on-disk state, not server-side chat history.

---

## Requirements

- `python3` (3.9+) — secret-scrub
- `node` (18+) — docgen
- `git`, `gh` (GitHub CLI) — identity-guard, docgen push hook
- macOS (`launchd`) or Linux (`systemd --user`) — scheduled scrubbers

## License

MIT — see [LICENSE](LICENSE).
