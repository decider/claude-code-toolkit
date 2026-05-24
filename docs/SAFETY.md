# Safety Audit

This is the audit Claude (or you) should run before installing anything
from this toolkit. It's deliberately framed as "verify this clone,
don't trust the maintainer."

## The threat model

The toolkit's job is to handle secrets — by definition, it has the
opportunity to mishandle them. The risks worth checking for:

1. **Exfiltration** — does any tool send file contents (or any data)
   over the network? It should not. Scrubber is local-only; docgen
   calls `claude -p` (your authenticated CLI, your subscription) and
   nothing else.
2. **Code execution** — does any tool `eval()` or `exec()` the file
   contents it scans? It should not. Scrubber regexes are pure pattern
   matches; docgen passes content as text to `claude -p` (no execution).
3. **Hidden install behavior** — do install scripts contain anything
   beyond what they advertise? Each `install.sh` should do exactly the
   one thing it says (set a hook, write a plist, etc.).
4. **Overreach** — does any tool write outside its declared paths?
   Expected paths: `.git/hooks/`, `~/Library/LaunchAgents/`, files
   inside `~/.claude/projects/` (scrubber redacting in place).

## Audit checklist

Run each of these, expect the noted result.

### 1. No outbound network anywhere in scrubber

```sh
grep -rEn 'urlopen|requests|http\.client|fetch\(|curl |wget |subprocess.*http' tools/secret-scrub/
```

Expected: no matches.

### 2. No code execution on file contents

```sh
grep -rEn 'eval\(|exec\(|os\.system|shell=True|subprocess.*input=text' tools/secret-scrub/ tools/docgen/
```

Expected: no matches (other than test fixtures that exercise the
detector's safety, if any).

### 3. Writes are bounded to declared paths

```sh
grep -rEn 'write_text\(|writeFileSync\(|open\(.*[''"]w[''"]' tools/secret-scrub/ tools/docgen/
```

Expected paths only:
- `.git/hooks/<hook-name>` (install scripts wiring hooks)
- `~/Library/LaunchAgents/com.secret-scrub.plist` (launchd installer)
- Files inside the user's specified sessions dir (scrubber redacting in place)
- `<dir>/README.md` (docgen)
- `.docgen/state.json` (docgen's per-repo state)

Anything writing to `/tmp/<something-other-than-logs>`, `~/.ssh/`, `/usr/`,
or arbitrary user paths is a red flag.

### 4. Install scripts do only what they advertise

```sh
cat tools/secret-scrub/install.sh
cat tools/secret-scrub/install-launchd.sh
cat tools/docgen/install-push-hook.sh
```

Expected: each is a small bash script that:
- Optionally backs up an existing hook
- Sets `core.hooksPath` or writes one file
- Prints what it did

No hidden `curl | bash`, no `eval`, no installing other tools.

### 5. No npm / pip postinstall surprises

```sh
# If any package.json or pyproject.toml exists in the toolkit:
find tools/claude-code-toolkit tools/secret-scrub tools/docgen -name package.json -o -name pyproject.toml
```

If found, check for `scripts.preinstall`, `scripts.postinstall`,
`scripts.prepare`, or `[build-system]` doing anything unexpected.

## When to refuse

If any of the audit checks fails — there's an outbound `curl`, an
unexpected `eval`, an install script that touches `~/.ssh/`, anything
that doesn't match the description — **stop the install** and tell the
user what you found.

A clean clone passes all 5. If a fork added something this list would
catch, the fork is the problem; surface that to the user.
