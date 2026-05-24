#!/usr/bin/env bash
# Install the secret-scrub systemd timer — runs scrub.py --sessions on
# a schedule (Linux equivalent of install-launchd.sh on macOS).
#
# Uses systemd user units (--user) so no sudo / root required. Units
# live in ~/.config/systemd/user/ and only the calling user can
# inspect/control them.
#
# Usage:
#   ./install-systemd.sh            install + enable + start
#   ./install-systemd.sh uninstall  stop + disable + remove unit files
#   ./install-systemd.sh status     show timer + last service log
#
# Linux only. macOS uses install-launchd.sh.

set -euo pipefail
[ "$(uname -s)" = "Linux" ] || { echo "Linux only — use install-launchd.sh on macOS" >&2; exit 1; }
command -v systemctl >/dev/null || { echo "systemctl not on PATH — distro without systemd?" >&2; exit 1; }

UNIT_NAME="secret-scrub"
UNIT_DIR="$HOME/.config/systemd/user"
SERVICE="$UNIT_DIR/${UNIT_NAME}.service"
TIMER="$UNIT_DIR/${UNIT_NAME}.timer"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRUB_PY="$ROOT/secret-scrub/scrub.py"
INTERVAL="${SECRET_SCRUB_INTERVAL:-30min}"  # e.g. 15min, 1h, 2h

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
info() { printf '  • %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }

write_service() {
  cat > "$1" <<EOF
[Unit]
Description=secret-scrub: redact secrets from Claude session transcripts
Documentation=https://github.com/decider/claude-code-toolkit/tree/main/secret-scrub

[Service]
Type=oneshot
# Low-priority — we don't want to compete with foreground work.
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
ExecStart=/usr/bin/env python3 $SCRUB_PY --sessions
# Logs flow to journald by default. Tail with:
#   journalctl --user -u $UNIT_NAME --since today
StandardOutput=journal
StandardError=journal
EOF
}

write_timer() {
  cat > "$1" <<EOF
[Unit]
Description=Run secret-scrub every $INTERVAL
Documentation=https://github.com/decider/claude-code-toolkit/tree/main/secret-scrub

[Timer]
Unit=${UNIT_NAME}.service
# Fire shortly after boot/login, then on the interval.
OnBootSec=2min
OnUnitActiveSec=$INTERVAL
# Persistent=true means a missed run (laptop asleep) catches up on
# wake instead of just waiting for the next interval boundary.
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

case "${1:-install}" in
install)
  [ -x "$SCRUB_PY" ] || chmod +x "$SCRUB_PY" 2>/dev/null
  mkdir -p "$UNIT_DIR"
  TMPS="$(mktemp)"; TMPT="$(mktemp)"
  write_service "$TMPS"
  write_timer "$TMPT"

  changed=0
  if [ ! -f "$SERVICE" ] || ! cmp -s "$TMPS" "$SERVICE"; then mv "$TMPS" "$SERVICE"; ok "wrote $SERVICE"; changed=1; else rm "$TMPS"; info "service unchanged"; fi
  if [ ! -f "$TIMER" ]   || ! cmp -s "$TMPT" "$TIMER";   then mv "$TMPT" "$TIMER";   ok "wrote $TIMER";   changed=1; else rm "$TMPT"; info "timer unchanged"; fi

  if [ "$changed" = "1" ]; then
    systemctl --user daemon-reload
    ok "reloaded systemd user units"
  fi

  systemctl --user enable --now "${UNIT_NAME}.timer" >/dev/null 2>&1 && ok "enabled + started ${UNIT_NAME}.timer (every $INTERVAL)" || warn "could not enable timer"
  info "view next firing: systemctl --user list-timers ${UNIT_NAME}.timer"
  info "view logs:        journalctl --user -u $UNIT_NAME --since today"
  info "status:           ./install-systemd.sh status"
  ;;
uninstall)
  systemctl --user disable --now "${UNIT_NAME}.timer" >/dev/null 2>&1 && ok "disabled + stopped ${UNIT_NAME}.timer" || warn "${UNIT_NAME}.timer was not active"
  [ -f "$TIMER" ]   && rm "$TIMER"   && ok "removed $TIMER"
  [ -f "$SERVICE" ] && rm "$SERVICE" && ok "removed $SERVICE"
  systemctl --user daemon-reload 2>/dev/null || true
  ;;
status)
  if systemctl --user is-active --quiet "${UNIT_NAME}.timer"; then
    ok "timer active"
    systemctl --user list-timers "${UNIT_NAME}.timer" --no-pager 2>&1 | sed 's/^/    /'
    echo
    info "last 10 journal lines:"
    journalctl --user -u "$UNIT_NAME" -n 10 --no-pager 2>&1 | sed 's/^/    /'
  else
    warn "timer not active — run: ./install-systemd.sh"
  fi
  ;;
*)
  echo "usage: $0 {install|uninstall|status}" >&2
  exit 1
  ;;
esac
