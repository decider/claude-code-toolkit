#!/usr/bin/env bash
# Install (or uninstall) the identity-guard PreToolUse hook for
# Claude Code. Idempotent — re-running is safe.
#
# Usage:
#   ./install.sh             install hook into ~/.claude/settings.json
#   ./install.sh uninstall   remove it
#   ./install.sh status      show install state
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="$HOME/.claude/hooks"
DEST_SCRIPT="$DEST_DIR/identity-guard.sh"
SENSITIVE_LIST="$DEST_DIR/sensitive-repos.txt"
PERSONAL_LIST="$DEST_DIR/personal-repos.txt"
SETTINGS="$HOME/.claude/settings.json"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
info() { printf '  • %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }

case "${1:-install}" in
install)
  mkdir -p "$DEST_DIR"
  cp "$ROOT/sensitive-guard.sh" "$DEST_SCRIPT"
  chmod +x "$DEST_SCRIPT"
  ok "installed guard script at $DEST_SCRIPT"

  [ -f "$SENSITIVE_LIST" ] || { cp "$ROOT/sensitive-repos.txt.example" "$SENSITIVE_LIST"; ok "created $SENSITIVE_LIST (edit to add patterns)"; }
  [ -f "$PERSONAL_LIST" ]  || { cp "$ROOT/personal-repos.txt.example"  "$PERSONAL_LIST";  ok "created $PERSONAL_LIST (edit to add patterns)"; }

  # Register hook in settings.json (idempotent).
  if [ ! -f "$SETTINGS" ]; then
    echo '{"hooks":{}}' > "$SETTINGS"
    info "created $SETTINGS"
  fi
  if ! command -v jq >/dev/null; then
    warn "jq not installed — please manually add the PreToolUse hook for $DEST_SCRIPT to $SETTINGS"
    info "Example entry:"
    cat <<EXAMPLE
{
  "matcher": "Bash",
  "hooks": [{"type": "command", "command": "$DEST_SCRIPT"}]
}
EXAMPLE
    exit 0
  fi
  TMP="$(mktemp)"
  jq --arg cmd "$DEST_SCRIPT" '
    .hooks //= {} |
    .hooks.PreToolUse //= [] |
    if any(.hooks.PreToolUse[]; .hooks // [] | any(.command == $cmd))
    then .
    else .hooks.PreToolUse += [{"matcher": "Bash", "hooks": [{"type": "command", "command": $cmd}]}]
    end
  ' "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"
  ok "registered PreToolUse hook in $SETTINGS"
  info "edit $SENSITIVE_LIST + $PERSONAL_LIST to add your patterns"
  ;;
uninstall)
  if [ -f "$DEST_SCRIPT" ]; then rm "$DEST_SCRIPT"; ok "removed $DEST_SCRIPT"; fi
  if [ -f "$SETTINGS" ] && command -v jq >/dev/null; then
    TMP="$(mktemp)"
    jq --arg cmd "$DEST_SCRIPT" '
      .hooks.PreToolUse |= map(select((.hooks // [] | any(.command == $cmd)) | not))
    ' "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"
    ok "deregistered from $SETTINGS"
  fi
  info "lists at $SENSITIVE_LIST / $PERSONAL_LIST preserved (your config)"
  ;;
status)
  if [ -x "$DEST_SCRIPT" ]; then ok "guard script installed at $DEST_SCRIPT"
  else warn "guard script NOT installed"; fi
  if [ -f "$SETTINGS" ] && command -v jq >/dev/null && \
     jq --arg cmd "$DEST_SCRIPT" '.hooks.PreToolUse // [] | any(.hooks // [] | any(.command == $cmd))' "$SETTINGS" | grep -q true; then
    ok "registered in $SETTINGS"
  else
    warn "NOT registered in $SETTINGS"
  fi
  for L in "$SENSITIVE_LIST" "$PERSONAL_LIST"; do
    if [ -f "$L" ]; then
      count=$(grep -vcE '^\s*(#|$)' "$L" 2>/dev/null || echo 0)
      info "$L: $count active pattern(s)"
    fi
  done
  ;;
*)
  echo "usage: $0 {install|uninstall|status}" >&2; exit 1 ;;
esac
