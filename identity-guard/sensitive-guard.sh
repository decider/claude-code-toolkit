#!/bin/bash
# Claude Code PreToolUse hook — keep the wrong GitHub identity out of the
# wrong repo. Two directions:
#   - sensitive repos: only a bot/service account may operate on them;
#     block your personal identity (push/merge/PR/release/create).
#   - personal repos: only your personal account may operate on them;
#     block bot/service accounts.
#
# Config (all optional — sensible defaults if absent):
#
#   ~/.claude/hooks/sensitive-repos.txt   one owner/repo regex per line
#   ~/.claude/hooks/personal-repos.txt    one owner/repo regex per line
#   ~/.claude/hooks/identity-guard.conf   shell-sourced settings:
#       BOT_LOGIN_PATTERN='-bot$'         egrep: which gh logins are bots
#       BOT_URL_PATTERN='[^:@]*-bot'      egrep: bot creds embedded in a URL
#       BOT_ACCOUNT_HINT='your-bot'       shown in "switch --user X" messages
#       PERSONAL_ACCOUNT_HINT='your-user' shown in personal-side messages
#
# With no config the guard no-ops (both repo lists empty → exit 0), so
# installing it is safe; it only acts once you list repos to protect.

SENSITIVE_LIST="$HOME/.claude/hooks/sensitive-repos.txt"
PERSONAL_LIST="$HOME/.claude/hooks/personal-repos.txt"
CONF="$HOME/.claude/hooks/identity-guard.conf"

# Defaults — overridable via the conf file.
BOT_LOGIN_PATTERN='-bot$'
BOT_URL_PATTERN='[^:@]*-bot'
BOT_ACCOUNT_HINT='your-bot-account'
PERSONAL_ACCOUNT_HINT='your-personal-account'
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"

# At least one list must exist + have entries.
SENSITIVE_REGEX=""
PERSONAL_REGEX=""
[ -f "$SENSITIVE_LIST" ] && \
  SENSITIVE_REGEX=$(grep -vE '^[[:space:]]*(#|$)' "$SENSITIVE_LIST" 2>/dev/null | tr '\n' '|' | sed 's/|$//')
[ -f "$PERSONAL_LIST" ] && \
  PERSONAL_REGEX=$(grep -vE '^[[:space:]]*(#|$)' "$PERSONAL_LIST" 2>/dev/null | tr '\n' '|' | sed 's/|$//')
[ -z "$SENSITIVE_REGEX" ] && [ -z "$PERSONAL_REGEX" ] && exit 0

input=$(cat)
cmd=$(echo "$input" | python3 -c "
import sys, json
try: d=json.load(sys.stdin); print(d.get('tool_input', {}).get('command', ''))
except: print('')
" 2>/dev/null || echo "")
cwd=$(echo "$input" | python3 -c "
import sys, json
try:
  d = json.load(sys.stdin)
  print(d.get('cwd', '') or d.get('tool_input', {}).get('cwd', ''))
except: print('')
" 2>/dev/null || echo "")
cwd="${cwd:-$PWD}"

# Skip if the command is editing the hook itself (avoid self-block on updates)
case "$cmd" in
  *.claude/hooks/*) exit 0 ;;
esac

deny=""

# Pattern A: gh repo create against a sensitive repo
if echo "$cmd" | grep -qE "gh +repo +create +($SENSITIVE_REGEX)"; then
  deny="Blocked: 'gh repo create' against a guarded repo would attach your personal GitHub account as the creator. Use a service account or have a teammate create it."
fi

# Pattern B: explicit URL forms of push / remote add / set-url
if [ -z "$deny" ] && echo "$cmd" | grep -qE "git +(push|remote +add|remote +set-url).*github\.com[:/]($SENSITIVE_REGEX)"; then
  if ! echo "$cmd" | grep -qE "https?://($BOT_URL_PATTERN)[^@]*@github\.com"; then
    deny="Blocked: git op on a guarded repo without embedded bot credentials in the URL. The push event would land on your personal profile."
  fi
fi

# Pattern C: bare 'git push' — resolve remote via the cwd's git config
if [ -z "$deny" ] && echo "$cmd" | grep -qE '^[[:space:]]*git +push\b' && [ -n "$cwd" ] && { [ -d "$cwd/.git" ] || [ -f "$cwd/.git" ]; }; then
  remote=$(echo "$cmd" | sed -E 's/^[[:space:]]*git +push//' | tr -s ' ' | tr ' ' '\n' \
    | grep -vE '^(-.*|[[:space:]]*$|main|master|HEAD|.*:.*)$' | head -1 || true)
  remote="${remote:-origin}"
  url=$(git -C "$cwd" remote get-url "$remote" 2>/dev/null || echo "")
  if [ -n "$url" ] && echo "$url" | grep -qE "$SENSITIVE_REGEX"; then
    if ! echo "$url" | grep -qE "https?://($BOT_URL_PATTERN)[^@]*@github\.com"; then
      deny="Blocked: git push to remote '$remote' resolves to a guarded repo without embedded bot credentials. The push event would land on your personal account."
    fi
  fi
fi

# Pattern D: 'gh pr merge' against a sensitive repo while signed in as a
# non-bot account. The merge happens server-side, so Patterns B/C (which
# inspect git push URLs) never see it — this is how a personal identity
# ends up on a guarded repo's merge commits.
if [ -z "$deny" ] && echo "$cmd" | grep -qE 'gh +pr +merge\b'; then
  target=$(echo "$cmd" | grep -oE -- '(--repo|-R)[ =]+[^ ]+' | sed -E 's/(--repo|-R)[ =]+//' | head -1)
  if [ -z "$target" ] && [ -n "$cwd" ] && { [ -d "$cwd/.git" ] || [ -f "$cwd/.git" ]; }; then
    target=$(git -C "$cwd" remote get-url origin 2>/dev/null || echo "")
  fi
  if [ -n "$target" ] && echo "$target" | grep -qE "$SENSITIVE_REGEX"; then
    login=$(gh api user --jq .login 2>/dev/null || echo "")
    if ! echo "$login" | grep -qE "$BOT_LOGIN_PATTERN"; then
      if [ -z "$login" ]; then
        deny="Blocked: 'gh pr merge' on a guarded repo, but the active GitHub account could not be verified. Run 'gh auth switch --user $BOT_ACCOUNT_HINT' first, then retry."
      else
        deny="Blocked: 'gh pr merge' on a guarded repo while signed in as '$login'. The merge commit would carry that personal identity. Run 'gh auth switch --user $BOT_ACCOUNT_HINT' first, then retry."
      fi
    fi
  fi
fi

# Pattern I: 'gh pr create' against a sensitive repo while signed in as a
# non-bot account. The PR-opener identity is what GitHub stamps as the
# AUTHOR on any future squash-merge commit (committer becomes web-flow).
# Catching this at create-time is the only prevention — once the PR
# exists under a personal account, every squash attributes to that
# account regardless of who authored the underlying commits.
if [ -z "$deny" ] && echo "$cmd" | grep -qE 'gh +pr +create\b'; then
  target=$(echo "$cmd" | grep -oE -- '(--repo|-R)[ =]+[^ ]+' | sed -E 's/(--repo|-R)[ =]+//' | head -1)
  if [ -z "$target" ] && [ -n "$cwd" ] && { [ -d "$cwd/.git" ] || [ -f "$cwd/.git" ]; }; then
    target=$(git -C "$cwd" remote get-url origin 2>/dev/null || echo "")
  fi
  if [ -n "$target" ] && echo "$target" | grep -qE "$SENSITIVE_REGEX"; then
    login=$(gh api user --jq .login 2>/dev/null || echo "")
    if ! echo "$login" | grep -qE "$BOT_LOGIN_PATTERN"; then
      if [ -z "$login" ]; then
        deny="Blocked: 'gh pr create' on a guarded repo, but the active GitHub account could not be verified. Run 'gh auth switch --user $BOT_ACCOUNT_HINT' first, then retry."
      else
        deny="Blocked: 'gh pr create' on a guarded repo while signed in as '$login'. The PR opener becomes the AUTHOR on any future squash-merge commit (GitHub's documented behavior). Run 'gh auth switch --user $BOT_ACCOUNT_HINT' first, then retry."
      fi
    fi
  fi
fi

# Pattern K: 'gh release create|edit|delete' against a sensitive repo
# while signed in as a non-bot account. Release notes carry the active
# user's identity as the release author — same identity-leak class as
# Pattern I, for tagged releases.
if [ -z "$deny" ] && echo "$cmd" | grep -qE 'gh +release +(create|edit|delete)\b'; then
  target=$(echo "$cmd" | grep -oE -- '(--repo|-R)[ =]+[^ ]+' | sed -E 's/(--repo|-R)[ =]+//' | head -1)
  if [ -z "$target" ] && [ -n "$cwd" ] && { [ -d "$cwd/.git" ] || [ -f "$cwd/.git" ]; }; then
    target=$(git -C "$cwd" remote get-url origin 2>/dev/null || echo "")
  fi
  if [ -n "$target" ] && echo "$target" | grep -qE "$SENSITIVE_REGEX"; then
    login=$(gh api user --jq .login 2>/dev/null || echo "")
    if ! echo "$login" | grep -qE "$BOT_LOGIN_PATTERN"; then
      if [ -z "$login" ]; then
        deny="Blocked: 'gh release' on a guarded repo, but the active GitHub account could not be verified. Run 'gh auth switch --user $BOT_ACCOUNT_HINT' first, then retry."
      else
        deny="Blocked: 'gh release' on a guarded repo while signed in as '$login'. The release would be attributed to that personal identity. Run 'gh auth switch --user $BOT_ACCOUNT_HINT' first, then retry."
      fi
    fi
  fi
fi

# ─── Personal-repo protection (mirror of patterns above) ──────────────
# Keep bot/service accounts OUT of personal repos that should always
# carry your own identity.

# Pattern E: gh repo create against a personal repo while signed in as a bot.
if [ -z "$deny" ] && [ -n "$PERSONAL_REGEX" ] \
    && echo "$cmd" | grep -qE "gh +repo +create +($PERSONAL_REGEX)"; then
  login=$(gh api user --jq .login 2>/dev/null || echo "")
  if echo "$login" | grep -qE "$BOT_LOGIN_PATTERN"; then
    deny="Blocked: 'gh repo create' against a personal repo while signed in as bot account '$login'. The repo would be created under the bot's profile. Run 'gh auth switch --user $PERSONAL_ACCOUNT_HINT' first, then retry."
  fi
fi

# Pattern F: git push to a personal repo with embedded BOT creds in URL.
if [ -z "$deny" ] && [ -n "$PERSONAL_REGEX" ] \
    && echo "$cmd" | grep -qE "git +(push|remote +add|remote +set-url).*github\.com[:/]($PERSONAL_REGEX)"; then
  if echo "$cmd" | grep -qE "https?://($BOT_URL_PATTERN)[^@]*@github\.com"; then
    deny="Blocked: git op against a personal repo with embedded BOT credentials in the URL. The push event would land on the bot's profile."
  fi
fi

# Pattern G: bare 'git push' on a personal repo while gh login is a bot.
if [ -z "$deny" ] && [ -n "$PERSONAL_REGEX" ] \
    && echo "$cmd" | grep -qE '^[[:space:]]*git +push\b' \
    && [ -n "$cwd" ] && { [ -d "$cwd/.git" ] || [ -f "$cwd/.git" ]; }; then
  remote=$(echo "$cmd" | sed -E 's/^[[:space:]]*git +push//' | tr -s ' ' | tr ' ' '\n' \
    | grep -vE '^(-.*|[[:space:]]*$|main|master|HEAD|.*:.*)$' | head -1 || true)
  remote="${remote:-origin}"
  url=$(git -C "$cwd" remote get-url "$remote" 2>/dev/null || echo "")
  if [ -n "$url" ] && echo "$url" | grep -qE "$PERSONAL_REGEX"; then
    login=$(gh api user --jq .login 2>/dev/null || echo "")
    if echo "$login" | grep -qE "$BOT_LOGIN_PATTERN"; then
      deny="Blocked: git push to personal repo via remote '$remote' while signed in as bot account '$login'. The push event would land on the bot's profile. Run 'gh auth switch --user $PERSONAL_ACCOUNT_HINT' first, then retry."
    fi
  fi
fi

# Pattern H: 'gh pr merge' against a personal repo while signed in as a bot.
if [ -z "$deny" ] && [ -n "$PERSONAL_REGEX" ] \
    && echo "$cmd" | grep -qE 'gh +pr +merge\b'; then
  target=$(echo "$cmd" | grep -oE -- '(--repo|-R)[ =]+[^ ]+' | sed -E 's/(--repo|-R)[ =]+//' | head -1)
  if [ -z "$target" ] && [ -n "$cwd" ] && { [ -d "$cwd/.git" ] || [ -f "$cwd/.git" ]; }; then
    target=$(git -C "$cwd" remote get-url origin 2>/dev/null || echo "")
  fi
  if [ -n "$target" ] && echo "$target" | grep -qE "$PERSONAL_REGEX"; then
    login=$(gh api user --jq .login 2>/dev/null || echo "")
    if echo "$login" | grep -qE "$BOT_LOGIN_PATTERN"; then
      deny="Blocked: 'gh pr merge' on a personal repo while signed in as bot account '$login'. The merge commit would carry the bot's identity. Run 'gh auth switch --user $PERSONAL_ACCOUNT_HINT' first, then retry."
    fi
  fi
fi

# Pattern J: 'gh pr create' against a personal repo while signed in as a bot.
if [ -z "$deny" ] && [ -n "$PERSONAL_REGEX" ] \
    && echo "$cmd" | grep -qE 'gh +pr +create\b'; then
  target=$(echo "$cmd" | grep -oE -- '(--repo|-R)[ =]+[^ ]+' | sed -E 's/(--repo|-R)[ =]+//' | head -1)
  if [ -z "$target" ] && [ -n "$cwd" ] && { [ -d "$cwd/.git" ] || [ -f "$cwd/.git" ]; }; then
    target=$(git -C "$cwd" remote get-url origin 2>/dev/null || echo "")
  fi
  if [ -n "$target" ] && echo "$target" | grep -qE "$PERSONAL_REGEX"; then
    login=$(gh api user --jq .login 2>/dev/null || echo "")
    if echo "$login" | grep -qE "$BOT_LOGIN_PATTERN"; then
      deny="Blocked: 'gh pr create' on a personal repo while signed in as bot account '$login'. The PR opener becomes the AUTHOR on any future squash-merge commit. Run 'gh auth switch --user $PERSONAL_ACCOUNT_HINT' first, then retry."
    fi
  fi
fi

# Pattern L: 'gh release' against a personal repo while signed in as a bot.
if [ -z "$deny" ] && [ -n "$PERSONAL_REGEX" ] \
    && echo "$cmd" | grep -qE 'gh +release +(create|edit|delete)\b'; then
  target=$(echo "$cmd" | grep -oE -- '(--repo|-R)[ =]+[^ ]+' | sed -E 's/(--repo|-R)[ =]+//' | head -1)
  if [ -z "$target" ] && [ -n "$cwd" ] && { [ -d "$cwd/.git" ] || [ -f "$cwd/.git" ]; }; then
    target=$(git -C "$cwd" remote get-url origin 2>/dev/null || echo "")
  fi
  if [ -n "$target" ] && echo "$target" | grep -qE "$PERSONAL_REGEX"; then
    login=$(gh api user --jq .login 2>/dev/null || echo "")
    if echo "$login" | grep -qE "$BOT_LOGIN_PATTERN"; then
      deny="Blocked: 'gh release' on a personal repo while signed in as bot account '$login'. The release would carry the bot's identity. Run 'gh auth switch --user $PERSONAL_ACCOUNT_HINT' first, then retry."
    fi
  fi
fi

if [ -n "$deny" ]; then
  python3 -c "
import json
print(json.dumps({
  'hookSpecificOutput': {
    'hookEventName': 'PreToolUse',
    'permissionDecision': 'deny',
    'permissionDecisionReason': '''$deny'''
  }
}))
"
fi
exit 0
