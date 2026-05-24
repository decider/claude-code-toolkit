#!/usr/bin/env bash
# Install the secret-scrub WORKING-TREES systemd user timer — Linux
# parallel to install-launchd-trees.sh on macOS. Reads the same config
# file (~/.config/secret-scrub/working-trees.txt) and invokes the
# same scrub-working-trees-runner.sh wrapper.
#
# Third leg of the scrubber tripod on Linux:
#   1. pre-commit hook          — staged files at commit time
#   2. install-systemd.sh       — ~/.claude session transcripts (timer)
#   3. install-systemd-trees.sh — working-tree files (THIS)
#
# Usage:
#   ./install-systemd-trees.sh            install + enable + start
#   ./install-systemd-trees.sh uninstall  stop + disable + remove
#   ./install-systemd-trees.sh status     show timer + last journal

set -euo pipefail
[ "$(uname -s)" = "Linux" ] || { echo "Linux only — use install-launchd-trees.sh on macOS" >&2; exit 1; }
command -v systemctl >/dev/null || { echo "systemctl not on PATH" >&2; exit 1; }

UNIT_NAME="secret-scrub-trees"
UNIT_DIR="$HOME/.config/systemd/user"
SERVICE="$UNIT_DIR/${UNIT_NAME}.service"
TIMER="$UNIT_DIR/${UNIT_NAME}.timer"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$ROOT/scrub-working-trees-runner.sh"
CFG_DIR="$HOME/.config/secret-scrub"
CFG="$CFG_DIR/working-trees.txt"
INTERVAL="${SECRET_SCRUB_INTERVAL:-30min}"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
info() { printf '  • %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }

write_service() {
  cat > "$1" <<EOF
[Unit]
Description=secret-scrub: redact secrets from working-tree files in user-configured repos
Documentation=https://github.com/decider/claude-code-toolkit/tree/main/secret-scrub

[Service]
Type=oneshot
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
ExecStart=/bin/bash $RUNNER
StandardOutput=journal
StandardError=journal
EOF
}

write_timer() {
  cat > "$1" <<EOF
[Unit]
Description=Run secret-scrub working-trees scan every $INTERVAL
Documentation=https://github.com/decider/claude-code-toolkit/tree/main/secret-scrub

[Timer]
Unit=${UNIT_NAME}.service
OnBootSec=2min
OnUnitActiveSec=$INTERVAL
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

write_initial_config() {
  mkdir -p "$CFG_DIR"
  cat > "$CFG" <<EOF
# secret-scrub working-trees config
# One git repo path per line. # for comments. ~ expands to \$HOME.
EOF
}

case "${1:-install}" in
install)
  [ -x "$RUNNER" ] || chmod +x "$RUNNER"
  mkdir -p "$UNIT_DIR"
  [ -f "$CFG" ] || { write_initial_config; ok "wrote empty config at $CFG"; warn "config is empty — add repo paths before timer does anything useful"; }

  TMPS="$(mktemp)"; TMPT="$(mktemp)"
  write_service "$TMPS"; write_timer "$TMPT"

  changed=0
  if [ ! -f "$SERVICE" ] || ! cmp -s "$TMPS" "$SERVICE"; then mv "$TMPS" "$SERVICE"; ok "wrote $SERVICE"; changed=1; else rm "$TMPS"; info "service unchanged"; fi
  if [ ! -f "$TIMER" ]   || ! cmp -s "$TMPT" "$TIMER";   then mv "$TMPT" "$TIMER";   ok "wrote $TIMER";   changed=1; else rm "$TMPT"; info "timer unchanged"; fi

  if [ "$changed" = "1" ]; then systemctl --user daemon-reload; ok "reloaded systemd user units"; fi
  systemctl --user enable --now "${UNIT_NAME}.timer" >/dev/null 2>&1 && ok "enabled + started ${UNIT_NAME}.timer (every $INTERVAL)" || warn "could not enable timer"

  info "view next firing: systemctl --user list-timers ${UNIT_NAME}.timer"
  info "view logs:        journalctl --user -u $UNIT_NAME --since today"
  info "edit config:      $CFG"
  ;;
uninstall)
  systemctl --user disable --now "${UNIT_NAME}.timer" >/dev/null 2>&1 && ok "disabled + stopped ${UNIT_NAME}.timer" || warn "${UNIT_NAME}.timer was not active"
  [ -f "$TIMER" ]   && rm "$TIMER"   && ok "removed $TIMER"
  [ -f "$SERVICE" ] && rm "$SERVICE" && ok "removed $SERVICE"
  systemctl --user daemon-reload 2>/dev/null || true
  info "config at $CFG preserved — delete manually if desired"
  ;;
status)
  if systemctl --user is-active --quiet "${UNIT_NAME}.timer"; then
    ok "timer active"
    systemctl --user list-timers "${UNIT_NAME}.timer" --no-pager 2>&1 | sed 's/^/    /'
    info "last 10 journal lines:"
    journalctl --user -u "$UNIT_NAME" -n 10 --no-pager 2>&1 | sed 's/^/    /'
  else
    warn "timer not active — run: ./install-systemd-trees.sh"
  fi
  printf '\n  active repos in %s:\n' "$CFG"
  if [ -f "$CFG" ]; then grep -vE '^[[:space:]]*(#|$)' "$CFG" | sed 's/^/    /'; else echo "    (config not present)"; fi
  ;;
*) echo "usage: $0 {install|uninstall|status}" >&2; exit 1 ;;
esac
