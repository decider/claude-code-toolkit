#!/usr/bin/env bash
# Install (or uninstall) the docgen pre-push hook for THIS repo only.
# Never edits a machine-global hooks setup.
#
# After install, every `git push` from this clone (or any of its
# worktrees) spawns a detached background runner that refreshes
# docgen READMEs and pushes them back. Loop-safe via DOCGEN_HOOK_SKIP=1.
#
#   ./tools/docgen/install-push-hook.sh                install in main clone + all worktrees
#   ./tools/docgen/install-push-hook.sh --here          install in current dir's git-dir only
#   ./tools/docgen/install-push-hook.sh uninstall       remove from all worktrees
#   ./tools/docgen/install-push-hook.sh status          show install state per worktree
#
# Coexistence:
#   - secret-scrub sets core.hooksPath to tools/secret-scrub/githooks.
#     We respect that — when core.hooksPath is set we install our
#     pre-push *into the same dir* alongside the pre-commit hook so
#     both tools work in this repo without conflict.
#
#   - The global identity-guard hook (~/.git-hooks/pre-push, used to
#     reject pushes with personal email) exec's `pre-push-local` from
#     the repo's git-dir at the end. When core.hooksPath points at
#     that global hook AND a non-ours pre-push lives there, we install
#     OUR hook at <git-dir>/hooks/pre-push-local so the chain wakes it
#     up.
#
#   - Worktrees: each worktree has its OWN .git/worktrees/<name>/hooks/
#     dir; the main clone's hooks DO NOT cascade. By default this
#     installer walks `git worktree list` and installs in each. Use
#     --here to install only in the current worktree (e.g. CI).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$SCRIPT_DIR/hooks/pre-push"
MARKER='DOCGEN_PRE_PUSH_HOOK_v1'

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
info() { printf '  • %s\n' "$*"; }
err()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; }

if [ ! -f "$SOURCE" ]; then
  err "source hook missing: $SOURCE"
  exit 1
fi

# Decide where to install for a given working tree, printing ONE path.
# Decision tree:
#   1. core.hooksPath unset            → <git-dir>/hooks/pre-push
#   2. hooksPath set, our marker at $hooksPath/pre-push
#                                       → reinstall there (refresh)
#   3. hooksPath set, no foreign hook   → $hooksPath/pre-push
#   4. hooksPath set, foreign pre-push that exec's pre-push-local
#                                       → <git-dir>/hooks/pre-push-local
#   5. hooksPath set, foreign pre-push without a chain
#                                       → "" (caller refuses)
resolve_install_target() {
  local wt_dir="$1" git_dir="$2" hooks_path
  hooks_path="$(git -C "$wt_dir" config core.hooksPath 2>/dev/null || true)"
  if [ -z "$hooks_path" ]; then
    printf '%s/hooks/pre-push' "$git_dir"; return
  fi
  local global_hook="$hooks_path/pre-push"
  if [ -f "$global_hook" ] && grep -q "$MARKER" "$global_hook" 2>/dev/null; then
    printf '%s' "$global_hook"; return
  fi
  if [ ! -f "$global_hook" ]; then
    printf '%s' "$global_hook"; return
  fi
  if grep -qE 'pre-push-local|hooks/pre-push-local' "$global_hook" 2>/dev/null; then
    printf '%s/hooks/pre-push-local' "$git_dir"; return
  fi
  printf ''
}

install_one() {
  local wt="$1" gd="$2" dest
  dest="$(resolve_install_target "$wt" "$gd")"
  if [ -z "$dest" ]; then
    warn "$wt: foreign pre-push at \$hooksPath without a chain — refusing."
    info "back up that hook or have it exec pre-push-local at the end."
    return 1
  fi
  if [ -f "$dest" ] && ! grep -q "$MARKER" "$dest" 2>/dev/null; then
    warn "$dest already exists and isn't ours — refusing to overwrite."
    info "remove or back it up, then re-run install."
    return 1
  fi
  mkdir -p "$(dirname "$dest")"
  cp "$SOURCE" "$dest"
  chmod +x "$dest"
  ok "$wt → $dest"
  return 0
}

uninstall_one() {
  local wt="$1" gd="$2" removed=0 hooks_path
  hooks_path="$(git -C "$wt" config core.hooksPath 2>/dev/null || true)"
  for cand in \
    "${hooks_path:+$hooks_path/pre-push}" \
    "$gd/hooks/pre-push" \
    "$gd/hooks/pre-push-local"
  do
    [ -z "$cand" ] && continue
    if [ -f "$cand" ] && grep -q "$MARKER" "$cand" 2>/dev/null; then
      rm -f "$cand"
      ok "$wt → removed $cand"
      removed=1
    fi
  done
  if [ $removed -eq 0 ]; then info "$wt: no docgen hook found."; fi
  return 0
}

status_one() {
  local wt="$1" gd="$2" dest
  dest="$(resolve_install_target "$wt" "$gd")"
  if [ -z "$dest" ]; then
    warn "$wt: would refuse to install (foreign hook without chain)"
    return
  fi
  if [ -f "$dest" ] && grep -q "$MARKER" "$dest" 2>/dev/null; then
    ok "$wt: installed at $dest"
  else
    info "$wt: not installed (would target $dest)"
  fi
}

each_worktree() {
  local fn="$1" cwd_root
  cwd_root="$(git rev-parse --show-toplevel 2>/dev/null || echo '')"
  if [ -z "$cwd_root" ]; then err "not inside a git repo."; return 1; fi
  git -C "$cwd_root" worktree list --porcelain 2>/dev/null \
    | awk '/^worktree /{print substr($0, 10)}' \
    | while read -r wt; do
        [ -d "$wt" ] || continue
        local gd
        gd="$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null || echo '')"
        [ -z "$gd" ] && continue
        "$fn" "$wt" "$gd" || true
      done
}

each_here() {
  local fn="$1" wt gd
  wt="$(git rev-parse --show-toplevel 2>/dev/null || echo '')"
  gd="$(git rev-parse --absolute-git-dir 2>/dev/null || echo '')"
  if [ -z "$wt" ] || [ -z "$gd" ]; then err "not inside a git repo."; return 1; fi
  "$fn" "$wt" "$gd"
}

main() {
  local cmd="install" only_here=0
  for a in "$@"; do
    case "$a" in
      install|uninstall|status) cmd="$a" ;;
      --here) only_here=1 ;;
      *) err "unknown arg: $a"; exit 2 ;;
    esac
  done
  local walker="each_worktree"
  [ "$only_here" -eq 1 ] && walker="each_here"
  case "$cmd" in
    install)
      "$walker" install_one
      printf '\n'
      info "every \`git push\` from any of the above will spawn a background docgen refresh."
      info "follow it live with: tail -F /tmp/docgen-push-hook.log"
      info "uninstall with: $0 uninstall"
      ;;
    uninstall) "$walker" uninstall_one ;;
    status)
      "$walker" status_one
      if [ -f /tmp/docgen-push-hook.log ]; then
        printf '\n'
        info "last 5 log lines from /tmp/docgen-push-hook.log:"
        tail -n 5 /tmp/docgen-push-hook.log | sed 's/^/    /'
      fi
      ;;
  esac
}

main "$@"
