#!/usr/bin/env bash
# Master installer for the Claude Code Toolkit.
# Wraps the sub-installers in tools/*/install.sh and runs the ones the
# user opts into. Always interactive — never auto-installs everything.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
info() { printf '  • %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }

prompt_yn() {
  local q="$1"
  printf '  ? %s [y/N] ' "$q"
  read -r ans
  [[ "$ans" =~ ^[Yy] ]]
}

echo "Claude Code Toolkit — interactive installer"
echo "Read docs/SAFETY.md before saying yes."
echo

# secret-scrub pre-commit
if [ -x secret-scrub/install.sh ]; then
  if prompt_yn "Install secret-scrub pre-commit hook (per-repo)?"; then
    secret-scrub/install.sh
    ok "secret-scrub pre-commit installed"
  else
    info "skipped secret-scrub pre-commit"
  fi
fi

# OS-appropriate scheduler picker. macOS → launchd, Linux → systemd
# user timer. The two scrubber scheduled jobs (sessions + working-trees)
# each have a launchd and a systemd installer; pick the right one.
OS="$(uname -s)"
case "$OS" in
  Darwin) SESSIONS_SCHED=secret-scrub/install-launchd.sh;  TREES_SCHED=secret-scrub/install-launchd-trees.sh ;;
  Linux)  SESSIONS_SCHED=secret-scrub/install-systemd.sh;  TREES_SCHED=secret-scrub/install-systemd-trees.sh ;;
  *)      SESSIONS_SCHED='';                                     TREES_SCHED='' ;;
esac

# secret-scrub session scrubber (scheduled — sessions transcripts)
if [ -n "$SESSIONS_SCHED" ] && [ -x "$SESSIONS_SCHED" ]; then
  if prompt_yn "Install secret-scrub SESSIONS scrubber (scans ~/.claude/projects every 30 min)?"; then
    "$SESSIONS_SCHED"
    ok "secret-scrub sessions scrubber installed ($OS)"
  else
    info "skipped sessions scrubber"
  fi
fi

# secret-scrub working-trees scrubber (scheduled — uncommitted files in
# your repos; the third leak pathway the pre-commit hook can't see)
if [ -n "$TREES_SCHED" ] && [ -x "$TREES_SCHED" ]; then
  if prompt_yn "Install secret-scrub WORKING-TREES scrubber (scans your repos for uncommitted secrets every 30 min)?"; then
    "$TREES_SCHED"
    ok "secret-scrub working-trees scrubber installed ($OS)"
    info "  → add repos to scan: edit ~/.config/secret-scrub/working-trees.txt"
  else
    info "skipped working-trees scrubber"
  fi
fi

# docgen pre-push
if [ -x docgen/install-push-hook.sh ]; then
  if prompt_yn "Install docgen pre-push hook (auto-refresh per-dir READMEs on push)?"; then
    docgen/install-push-hook.sh
    ok "docgen pre-push installed"
  else
    info "skipped docgen pre-push"
  fi
fi

# identity-guard (Claude Code PreToolUse hook — keeps the wrong GitHub
# account out of the wrong repo)
if [ -x identity-guard/install.sh ]; then
  if prompt_yn "Install identity-guard (blocks pushes/merges under the wrong GitHub account)?"; then
    identity-guard/install.sh
    ok "identity-guard installed"
    info "  → add repo patterns: ~/.claude/hooks/sensitive-repos.txt + personal-repos.txt"
  else
    info "skipped identity-guard"
  fi
fi

echo
ok "done."
if [ -n "$SESSIONS_SCHED" ]; then
  info "verify scrubbers: $SESSIONS_SCHED status ; $TREES_SCHED status"
fi
info "to uninstall: each tool has its own uninstall path — see tool README"
