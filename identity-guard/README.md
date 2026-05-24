# identity-guard — keep the wrong GitHub account out of the wrong repo

A Claude Code `PreToolUse` Bash hook that intercepts `gh` and `git` commands
and blocks them when the active GitHub identity doesn't match what the
target repo requires.

Two failure modes it catches:

1. **Personal identity on a sensitive repo** — you accidentally `git push`,
   `gh pr merge`, or `gh release create` while signed in as your personal
   GitHub account, against a repo that's supposed to be bot-owned. The
   commit/merge/release would carry your personal email forever.

2. **Bot identity on a personal repo** — mirror image. Your `-bot` account
   accidentally operates on a repo that should always carry your personal
   identity.

Both are easy to do when juggling multiple `gh auth` accounts. The guard
catches the wrong account at command time and tells you which switch to make.

## What it blocks

| Pattern | Blocks when |
|---|---|
| `gh repo create <sensitive-repo>` | …while signed in as non-bot |
| `git push|remote add|remote set-url <url-with-sensitive-repo>` | …without an embedded bot token in the URL |
| Bare `git push` | …in a sensitive-repo cwd, without bot token |
| `gh pr merge` | …on a sensitive repo as non-bot |
| `gh pr create` | …on a sensitive repo as non-bot (PR opener becomes squash-merge author) |
| `gh release create|edit` | …on a sensitive repo as non-bot |
| Same patterns mirrored | …on personal repos while signed in as a `-bot` account |

The "what counts as sensitive/personal" lists live in two text files (one
regex per line):

- `~/.claude/hooks/sensitive-repos.txt`
- `~/.claude/hooks/personal-repos.txt`

(See the `.example` files in this directory for the format.)

## Install

```sh
./install.sh
```

That:
1. Copies `sensitive-guard.sh` → `~/.claude/hooks/sensitive-guard.sh`
2. Creates empty `sensitive-repos.txt` and `personal-repos.txt` if absent
3. Adds a `PreToolUse` Bash hook entry to `~/.claude/settings.json`

Then add your patterns:

```sh
# Repos where only -bot accounts should operate
echo "myorg/sensitive-repo-pattern" >> ~/.claude/hooks/sensitive-repos.txt

# Repos where only your personal account should operate
echo "yourpersonalaccount/personal-repo" >> ~/.claude/hooks/personal-repos.txt
```

## Uninstall

```sh
./install.sh uninstall
```

Removes the hook entry from `settings.json` and the script from `~/.claude/hooks/`.
Leaves the `*.txt` lists in place (they're your config — preserved on purpose).

## Caveats

- **Best-effort, not bulletproof.** It parses `gh` and `git` command lines
  with regex. Heavily quoted / scripted invocations might bypass it. Treat
  it as a tripwire, not an airlock.
- **`--repo VALUE` (space form) has a known parse gap.** Use `--repo=VALUE`
  (equals form) for reliable detection when invoking explicitly.
- **The hook fires in Claude Code only.** A `gh` command typed directly in
  your terminal isn't checked. Pair with a `gh` shell wrapper function for
  full coverage (out of scope for this hook).

## Testing locally

```sh
# Confirm the hook is registered
jq '.hooks.PreToolUse[] | select(.hooks[0].command | contains("identity-guard"))' ~/.claude/settings.json

# Trigger it (should be blocked):
# (in a Claude Code session) gh repo create your-org/test-block
```
