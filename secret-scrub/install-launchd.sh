#!/usr/bin/env bash
# Install the secret-scrub launchd job — runs scrub.py --sessions on a
# schedule so secrets pasted into Claude get redacted from disk
# (~/.claude/projects/*.jsonl) without manual intervention.
#
# Idempotent — safe to re-run. Updates the plist + reloads if anything
# changed. Honors $DRY_RUN=1 for inspection without writing.
#
# Usage:
#   ./install-launchd.sh            install (or update)
#   ./install-launchd.sh uninstall  remove
#   ./install-launchd.sh status     show launchctl state + last logs
#
# macOS only. Linux equivalent (systemd timer) is a TODO — different
# shape of unit file, same principle.

set -euo pipefail
[ "$(uname -s)" = "Darwin" ] || { echo "macOS only — Linux systemd path not yet implemented" >&2; exit 1; }

LABEL="com.secret-scrub"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRUB_PY="$ROOT/secret-scrub/scrub.py"
INTERVAL="${SECRET_SCRUB_INTERVAL:-1800}"  # default 30 min; override via env
LOG="/tmp/secret-scrub.log"
ERR="/tmp/secret-scrub.err"

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
    <string>/usr/bin/python3</string>
    <string>$SCRUB_PY</string>
    <string>--sessions</string>
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

case "${1:-install}" in
install)
  [ -x "$SCRUB_PY" ] || chmod +x "$SCRUB_PY" 2>/dev/null
  mkdir -p "$(dirname "$PLIST")"
  TMP="$(mktemp)"
  write_plist "$TMP"
  plutil -lint "$TMP" >/dev/null
  if [ -f "$PLIST" ] && cmp -s "$TMP" "$PLIST"; then
    info "plist unchanged at $PLIST"
    rm "$TMP"
  else
    [ "${DRY_RUN:-0}" = "1" ] && { info "DRY_RUN — would write $PLIST"; cat "$TMP"; rm "$TMP"; exit 0; }
    mv "$TMP" "$PLIST"
    ok "wrote $PLIST"
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    ok "loaded launchd job — runs every $INTERVAL sec"
  fi
  info "logs: $LOG (stdout) + $ERR (stderr)"
  info "status: ./install-launchd.sh status"
  ;;
uninstall)
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null && ok "unloaded $LABEL" || warn "$LABEL was not loaded"
  [ -f "$PLIST" ] && rm "$PLIST" && ok "removed $PLIST" || info "no plist at $PLIST"
  ;;
status)
  if launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -qE 'state = (running|waiting)'; then
    ok "loaded — last 5 log lines:"
    tail -5 "$LOG" 2>/dev/null | sed 's/^/    /'
    [ -s "$ERR" ] && warn "stderr (last 5):" && tail -5 "$ERR" | sed 's/^/    /'
  else
    warn "not loaded — run: ./install-launchd.sh"
  fi
  ;;
*)
  echo "usage: $0 {install|uninstall|status}" >&2
  exit 1
  ;;
esac
