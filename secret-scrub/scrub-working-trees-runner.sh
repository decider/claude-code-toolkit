#!/usr/bin/env bash
# Wrapper invoked by launchd / systemd timer. Reads the user's list of
# working-tree paths from a config file and feeds them to scrub.py.
#
# Config file format (one path per line, # = comment):
#   ~/.config/secret-scrub/working-trees.txt
#   ~/code/my-project
#   ~/code/another
#
# Override config path via SCRUB_WT_CONFIG env var.
#
# Bash 3.2 compatible (launchd executes /bin/bash which is 3.2 on macOS).
set -u
SCRUB_PY="${SCRUB_PY:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scrub.py}"
CFG="${SCRUB_WT_CONFIG:-$HOME/.config/secret-scrub/working-trees.txt}"

[ -f "$CFG" ] || { echo "secret-scrub-trees: no config at $CFG; nothing to scan" >&2; exit 0; }

# Read paths, skip comments + blanks, expand a leading ~ to $HOME.
# while-read into a plain array — no mapfile (bash 4+ only).
# NB: don't use ${line#~} — bash tilde-expands the PATTERN before
# matching, so a literal '~' in the input never gets stripped. Use
# explicit substring slicing instead (works in bash 2+).
paths=()
while IFS= read -r line; do
  if [ "${line:0:1}" = "~" ]; then
    line="$HOME${line:1}"
  fi
  paths+=("$line")
done < <(grep -vE '^[[:space:]]*(#|$)' "$CFG")

if [ "${#paths[@]}" = "0" ]; then
  echo "secret-scrub-trees: config $CFG is empty; nothing to scan" >&2
  exit 0
fi

# Pass 1 — working-tree files (uncommitted/untracked). Redacts in place.
/usr/bin/env python3 "$SCRUB_PY" --working-trees "${paths[@]}"

# Pass 2 — .git/config embedded credentials (the fourth leak pathway).
# DETECT-ONLY here: auto-stripping a token from a background job would
# silently change git's auth behavior (URL → tokenless → credential
# helper), which could surprise the user mid-work. So we only REPORT;
# findings land in this job's log and the operator runs
# `scrub.py --git-configs <path> --fix` deliberately. A non-zero exit
# (rc=1 = "credential found") must NOT mark the whole cron job failed —
# the report in the log is the signal.
/usr/bin/env python3 "$SCRUB_PY" --git-configs "${paths[@]}" || true

exit 0
