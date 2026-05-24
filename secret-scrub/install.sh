#!/usr/bin/env bash
# Install (or uninstall) the secret-scrub pre-commit hook into a target
# git repo. Works standalone: this toolkit can live anywhere — the
# installed hook calls scrub.py by ABSOLUTE path, so the repo being
# guarded doesn't need the toolkit vendored inside it.
#
#   ./install.sh [install] [TARGET_REPO]   install (default TARGET = cwd's repo)
#   ./install.sh uninstall [TARGET_REPO]   remove
#
# Never edits machine-global git config — guards THIS target repo only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRUB_ABS="$SCRIPT_DIR/scrub.py"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
info() { printf '  • %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }

# Resolve target repo (arg 2, else cwd).
TARGET="${2:-$PWD}"
ROOT="$(git -C "$TARGET" rev-parse --show-toplevel 2>/dev/null || echo '')"
[ -n "$ROOT" ] || { echo "secret-scrub: $TARGET is not inside a git repo" >&2; exit 1; }

HOOKS_PATH="$(git -C "$ROOT" config core.hooksPath || echo '')"

# Case A iff a global hooks dir is set whose pre-commit delegates to a
# per-repo pre-commit-local. Then we co-exist by installing there.
is_case_a() {
  [ -n "$HOOKS_PATH" ] || return 1
  [ -f "$HOOKS_PATH/pre-commit" ] || return 1
  grep -q 'pre-commit-local' "$HOOKS_PATH/pre-commit"
}

# Generate a pre-commit hook that invokes scrub.py by absolute path.
write_hook() {
  cat > "$1" <<EOF
#!/usr/bin/env bash
# secret-scrub pre-commit hook (installed by claude-code-toolkit).
# Scrubs secrets from staged files before they enter a commit.
# Fails OPEN on internal error — a tool bug must not brick commits.
SCRUB="$SCRUB_ABS"
[ -f "\$SCRUB" ] || exit 0
command -v python3 >/dev/null 2>&1 || { echo "secret-scrub: python3 not found — skipping." >&2; exit 0; }
python3 "\$SCRUB" --staged
rc=\$?
[ "\$rc" -eq 1 ] && exit 1   # a secret remains — block the commit
exit 0                        # 0 = clean/scrubbed; other rc = internal error → fail open
EOF
  chmod +x "$1"
}

install() {
  local gitdir; gitdir="$(git -C "$ROOT" rev-parse --git-dir)"
  gitdir="$(cd "$ROOT" && cd "$gitdir" && pwd)"
  if is_case_a; then
    write_hook "$gitdir/hooks/pre-commit-local"
    ok "installed $gitdir/hooks/pre-commit-local (delegated by your global hook)"
  else
    local dest="$gitdir/hooks/pre-commit"
    if [ -f "$dest" ] && ! grep -q secret-scrub "$dest" 2>/dev/null; then
      warn "$dest already exists and isn't ours — backing up to pre-commit.bak"
      cp "$dest" "$dest.bak"
    fi
    write_hook "$dest"
    ok "installed $dest"
  fi
  info "guards commits in $ROOT only. scrub.py: $SCRUB_ABS"
}

uninstall() {
  local gitdir; gitdir="$(cd "$ROOT" && cd "$(git -C "$ROOT" rev-parse --git-dir)" && pwd)"
  for h in pre-commit pre-commit-local; do
    if [ -f "$gitdir/hooks/$h" ] && grep -q secret-scrub "$gitdir/hooks/$h" 2>/dev/null; then
      rm -f "$gitdir/hooks/$h"; ok "removed $gitdir/hooks/$h"
    fi
  done
}

case "${1:-install}" in
  install)   install ;;
  uninstall) uninstall ;;
  *) echo "usage: $0 [install|uninstall] [target-repo]" >&2; exit 1 ;;
esac
