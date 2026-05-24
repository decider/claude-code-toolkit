#!/usr/bin/env bash
# Install the secret-scrub WORKING-TREES launchd job — runs every
# 30 min, scans the git repos listed in ~/.config/secret-scrub/
# working-trees.txt for secrets in uncommitted/untracked files.
#
# This is the third leg of the scrubber tripod:
#   1. pre-commit hook       — staged files at commit time
#   2. install-launchd.sh    — ~/.claude session transcripts (cron)
#   3. install-launchd-trees.sh (THIS)
#                            — working-tree files in your repos (cron)
#
# macOS only. Linux equivalent (systemd timer) is a TODO.
#
# Usage:
#   ./install-launchd-trees.sh            install (or update)
#   ./install-launchd-trees.sh uninstall  remove
#   ./install-launchd-trees.sh status     show launchctl state + last logs

set -euo pipefail
[ "$(uname -s)" = "Darwin" ] || { echo "macOS only — Linux systemd path not yet implemented" >&2; exit 1; }

LABEL="com.secret-scrub-trees"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$ROOT/scrub-working-trees-runner.sh"
CFG_DIR="$HOME/.config/secret-scrub"
CFG="$CFG_DIR/working-trees.txt"
INTERVAL="${SECRET_SCRUB_INTERVAL:-1800}"
LOG="/tmp/secret-scrub-trees.log"
ERR="/tmp/secret-scrub-trees.err"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
info() { printf '  • %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }

write_plist() {
  cat > "$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$RUNNER</string>
  </array>
  <key>StartInterval</key><integer>$INTERVAL</integer>
  <key>RunAtLoad</key><true/>
  <key>Nice</key><integer>10</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$ERR</string>
</dict>
</plist>
EOF
}

write_initial_config() {
  mkdir -p "$CFG_DIR"
  cat > "$CFG" <<EOF
# secret-scrub working-trees config
# One git repo path per line. Lines starting with # are comments.
# Tilde-expanded. Edit this file to add or remove repos.
#
# Examples:
#   ~/code/my-project
#   ~/repos/another-repo
#
EOF
}

case "${1:-install}" in
install)
  [ -x "$RUNNER" ] || chmod +x "$RUNNER"
  mkdir -p "$(dirname "$PLIST")"
  if [ ! -f "$CFG" ]; then
    write_initial_config
    ok "wrote empty config at $CFG"
    warn "config is empty — add repo paths before the timer does anything useful"
    info "  echo \$HOME/code/my-project >> $CFG"
  fi
  TMP="$(mktemp)"
  write_plist "$TMP"
  plutil -lint "$TMP" >/dev/null
  if [ -f "$PLIST" ] && cmp -s "$TMP" "$PLIST"; then
    info "plist unchanged at $PLIST"
    rm "$TMP"
  else
    mv "$TMP" "$PLIST"
    ok "wrote $PLIST"
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    ok "loaded launchd job — runs every $INTERVAL sec"
  fi
  info "logs: $LOG (stdout) + $ERR (stderr)"
  info "edit config: $CFG"
  info "status: ./install-launchd-trees.sh status"
  ;;
uninstall)
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null && ok "unloaded $LABEL" || warn "$LABEL was not loaded"
  [ -f "$PLIST" ] && rm "$PLIST" && ok "removed $PLIST" || info "no plist at $PLIST"
  info "config at $CFG preserved (your choices) — delete manually if desired"
  ;;
status)
  if launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -qE 'state = (running|waiting)'; then
    ok "loaded — last 5 log lines:"
    tail -5 "$LOG" 2>/dev/null | sed 's/^/    /'
    if [ -s "$ERR" ]; then warn "stderr (last 5):"; tail -5 "$ERR" | sed 's/^/    /'; fi
  else
    warn "not loaded — run: ./install-launchd-trees.sh"
  fi
  printf '\n  active repos in %s:\n' "$CFG"
  if [ -f "$CFG" ]; then grep -vE '^\s*(#|$)' "$CFG" | sed 's/^/    /'; else echo "    (config not present)"; fi
  ;;
*) echo "usage: $0 {install|uninstall|status}" >&2; exit 1 ;;
esac
