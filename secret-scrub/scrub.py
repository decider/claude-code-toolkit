#!/usr/bin/env python3
"""secret-scrub — keep secrets out of commits and Claude sessions.

  scrub.py --staged     pre-commit: scrub secrets from staged files
  scrub.py --sessions   redact secrets in ~/.claude session transcripts
  scrub.py --working-trees <path>...
                        scan modified + untracked files in one or more
                        git repos. Catches secrets that haven't yet been
                        committed (so the pre-commit hook never sees them
                        and the sessions scan doesn't cover them).

Exit codes (--staged): 0 = clean or scrubbed clean; 1 = a secret remains.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from detect import find_secrets, is_whole_file_secret  # noqa: E402

REDACTION = '[REDACTED]'


def _git(*args: str) -> str:
    r = subprocess.run(['git', *args], capture_output=True, text=True)
    if r.returncode != 0 and r.stderr.strip():
        print(f'secret-scrub: git {args[0]} failed: {r.stderr.strip()}',
              file=sys.stderr)
    return r.stdout


def _staged_files() -> list[str]:
    out = _git('diff', '--cached', '--name-only', '--diff-filter=ACM')
    return [line for line in out.splitlines() if line]


def _staged_content(rel: str) -> str | None:
    """Staged (index) content of `rel`, or None if binary/unreadable."""
    r = subprocess.run(['git', 'show', f':{rel}'], capture_output=True)
    if r.returncode != 0:
        return None
    try:
        return r.stdout.decode('utf-8')
    except UnicodeDecodeError:
        return None  # binary


def _is_text(path: Path) -> bool:
    try:
        path.read_text(encoding='utf-8')
        return True
    except (UnicodeDecodeError, OSError):
        return False


def _redact(text: str, findings) -> str:
    """Replace each finding span with REDACTION, last-to-first."""
    for f in sorted(findings, key=lambda x: x.start, reverse=True):
        text = text[:f.start] + REDACTION + text[f.end:]
    return text


def _ensure_gitignored(path: str) -> None:
    gi = Path('.gitignore')
    lines = gi.read_text().splitlines() if gi.exists() else []
    if path not in lines:
        with gi.open('a') as fh:
            fh.write(('' if not lines or lines[-1] == '' else '\n') + path + '\n')
        _git('add', '.gitignore')


def scrub_staged() -> int:
    caught: list[str] = []
    private_key_hit = False
    residual = False

    for rel in _staged_files():
        path = Path(rel)
        text = _staged_content(rel)
        if text is None:
            continue
        findings = find_secrets(text, rel)
        if not findings:
            continue

        if is_whole_file_secret(text, rel):
            _git('rm', '--cached', '--quiet', rel)
            _ensure_gitignored(rel)
            caught.append(f'  unstaged + gitignored: {rel} (whole-file secret)')
            if any(f.is_private_key for f in findings):
                private_key_hit = True
            # File is no longer staged — nothing residual to worry about.
        else:
            redacted = _redact(text, findings)
            path.write_text(redacted, encoding='utf-8')
            _git('add', rel)
            if any(f.is_private_key for f in findings):
                private_key_hit = True
            # Re-scan staged content to confirm redaction was complete.
            after = _staged_content(rel)
            if after is not None and find_secrets(after, rel):
                caught.append(f'  ⚠ redaction INCOMPLETE in: {rel} — residual secret remains')
                residual = True
            else:
                caught.append(f'  redacted {len(findings)} secret(s) in: {rel}')

    if caught:
        print('🔒 secret-scrub caught secrets before commit:', file=sys.stderr)
        for line in caught:
            print(line, file=sys.stderr)
        print('   Please do not commit secrets — paste them into a password '
              'manager, not the repo.', file=sys.stderr)
        if private_key_hit:
            print('   ⚠ A PRIVATE KEY was exposed and is now COMPROMISED — '
                  'rotate it (move funds to a new wallet).', file=sys.stderr)
    if residual:
        print('❌ a secret could not be scrubbed automatically — commit '
              'blocked. Remove it by hand.', file=sys.stderr)
        return 1
    return 0


def _sessions_dir() -> Path:
    # SECRET_SCRUB_SESSIONS_DIR overrides for tests; default is the real location.
    import os
    override = os.environ.get('SECRET_SCRUB_SESSIONS_DIR')
    if override:
        return Path(override)
    return Path.home() / '.claude' / 'projects'


_STATE_FILENAME = '.secret-scrub-state.json'


def _load_scan_state(state_path: Path) -> float:
    """Returns the last-scan unix timestamp, or 0 if no state.
       Corrupt / unreadable state falls back to 0 (full re-scan) and
       warns to stderr — never crashes the cron run."""
    if not state_path.exists():
        return 0
    try:
        import json
        return float(json.loads(state_path.read_text()).get('last_run_unix', 0))
    except Exception as e:
        print(f'secret-scrub: state file unreadable ({e}); doing full scan',
              file=sys.stderr)
        return 0


def _save_scan_state(state_path: Path, ts: float) -> None:
    import json
    try:
        state_path.write_text(json.dumps({'last_run_unix': ts}))
    except Exception as e:
        print(f'secret-scrub: could not persist state ({e})', file=sys.stderr)


def scrub_sessions(full: bool = False) -> int:
    """Scan session transcripts for secrets and redact in place.

    Incremental by default: only files modified since the last
    successful run are re-scanned. State is kept in a per-sessions-dir
    .secret-scrub-state.json. Pass full=True to force a complete scan
    (use this after the detector grows new patterns, or to be sure).
    """
    import time
    root = _sessions_dir()
    if not root.exists():
        print(f'secret-scrub: no sessions dir at {root}', file=sys.stderr)
        return 0

    state_path = root / _STATE_FILENAME
    last_run = 0 if full else _load_scan_state(state_path)

    scanned = 0
    skipped = 0
    redacted_files = 0
    for path in sorted(root.rglob('*')):
        # Don't recurse into our own state file (would always get
        # re-touched on every run and confuse skip stats).
        if path.name == _STATE_FILENAME:
            continue
        if not path.is_file() or not _is_text(path):
            continue
        # Incremental gate: skip files unmodified since last run.
        if last_run and path.stat().st_mtime <= last_run:
            skipped += 1
            continue
        scanned += 1
        text = path.read_text(encoding='utf-8')
        findings = find_secrets(text, path.name)
        if findings:
            path.write_text(_redact(text, findings), encoding='utf-8')
            redacted_files += 1
            print(f'  redacted {len(findings)} secret(s) in {path}',
                  file=sys.stderr)

    # Save end-of-run wall-clock. This deliberately HAPPENS AFTER the
    # scan so any redactions we just made (which bump file mtime to
    # ~now) get skipped on the next incremental run. Files written by
    # OTHER processes during the scan window may slip until the run
    # after next — acceptable: cron is 30-min cadence, so worst-case
    # detection latency is one cycle.
    _save_scan_state(state_path, time.time())
    mode = 'full' if full or not last_run else 'incremental'
    print(f'🔒 secret-scrub --sessions ({mode}): scanned {scanned}, '
          f'skipped {skipped}, cleaned {redacted_files} file(s).',
          file=sys.stderr)
    return 0


def scrub_working_trees(repo_paths: list[str]) -> int:
    """Scan modified + untracked files in each given git repo. Redact
    findings in place. Covers the third leak pathway:

      ~/.claude/projects/   covered by --sessions (launchd cron)
      staged-for-commit     covered by --staged   (pre-commit hook)
      working tree files    covered HERE          (separate cron)

    The pre-commit hook only fires on `git commit`. A secret sitting
    in an uncommitted/untracked file is invisible to it. This mode
    closes that gap.

    Uses `git status --porcelain -z` to enumerate modified + untracked
    files — respects .gitignore, skips deleted entries, skips
    submodules. Skips binary / non-text files.
    """
    import os
    import subprocess

    total_repos = 0
    total_scanned = 0
    total_redacted = 0
    for repo in repo_paths:
        if not os.path.isdir(os.path.join(repo, '.git')) \
           and not os.path.isfile(os.path.join(repo, '.git')):
            print(f'secret-scrub: {repo} is not a git repo; skipping',
                  file=sys.stderr)
            continue
        total_repos += 1

        # --porcelain -z gives us \0-separated entries safe for any
        # path. -uall includes untracked files inside untracked dirs.
        r = subprocess.run(
            ['git', '-C', repo, 'status', '--porcelain=v1', '-z',
             '--untracked-files=all'],
            capture_output=True, text=False)
        if r.returncode != 0:
            print(f'secret-scrub: git status failed in {repo}',
                  file=sys.stderr)
            continue

        # Parse \0-separated entries. Each entry: "XY <path>\0" where XY
        # is a 2-char status. Skip deleted (D in either column) and
        # entries with a -> rename (those have an extra "\0<oldpath>\0").
        entries = r.stdout.split(b'\0')
        files = []
        i = 0
        while i < len(entries):
            e = entries[i]
            if not e:
                i += 1; continue
            if len(e) < 4:
                i += 1; continue
            xy = e[:2].decode('ascii', 'replace')
            path = e[3:].decode('utf-8', 'replace')
            i += 1
            # Renames: the next entry is the old path; skip it.
            if 'R' in xy or 'C' in xy:
                i += 1
            # Skip deletions — file is gone.
            if 'D' in xy:
                continue
            files.append(path)

        for relpath in files:
            full = Path(repo) / relpath
            if not full.is_file():
                continue
            if not _is_text(full):
                continue
            try:
                text = full.read_text(encoding='utf-8')
            except (UnicodeDecodeError, OSError):
                continue
            total_scanned += 1
            findings = find_secrets(text, full.name)
            if findings:
                full.write_text(_redact(text, findings), encoding='utf-8')
                total_redacted += 1
                print(f'  redacted {len(findings)} secret(s) in {full}',
                      file=sys.stderr)

    print(f'🔒 secret-scrub --working-trees: {total_repos} repo(s), '
          f'scanned {total_scanned}, cleaned {total_redacted} file(s).',
          file=sys.stderr)
    return 0


_URL_CRED_RE = re.compile(
    r'(https?://)([^/\s:@]+):([^/\s@]+)@([^/\s]+)')


def scrub_git_configs(repo_paths: list[str], fix: bool = False) -> int:
    """Audit each repo's .git/config for embedded credentials — the
    FOURTH leak pathway the other three modes can't see:

      ~/.claude/projects/   --sessions
      staged-for-commit     --staged
      working-tree files    --working-trees
      .git/config           HERE   ← git-internal, skipped by all above

    A tokenized remote URL (https://user:TOKEN@host/...) puts a live
    credential in plaintext where `git remote -v` will happily echo it
    into any log. This is exactly the leak we just cleaned up.

    DETECT-ONLY by default — redacting a token in a remote URL would
    break auth (https://user:[REDACTED]@host won't authenticate), so
    we report + return rc=1 (alertable from cron/CI) instead of
    mangling the file. Pass fix=True to STRIP the embedded credential,
    converting the URL to tokenless (https://host/...) so git falls
    back to its credential helper — the correct remediation.

    Also scans ~/.gitconfig for an [url ...insteadOf] or credential
    entry that embeds a token.
    """
    import os

    targets = []
    for repo in repo_paths:
        cfg = os.path.join(repo, '.git', 'config')
        if os.path.isfile(cfg):
            targets.append(cfg)
        elif os.path.isfile(os.path.join(repo, '.git')):
            # worktree / submodule: .git is a file pointing at gitdir
            try:
                line = open(os.path.join(repo, '.git')).read().strip()
                if line.startswith('gitdir:'):
                    gd = line.split(':', 1)[1].strip()
                    gd = gd if os.path.isabs(gd) else os.path.join(repo, gd)
                    cfg = os.path.join(gd, 'config')
                    if os.path.isfile(cfg):
                        targets.append(cfg)
            except OSError:
                pass
        else:
            print(f'secret-scrub: {repo} is not a git repo; skipping',
                  file=sys.stderr)
    global_cfg = os.path.expanduser('~/.gitconfig')
    if os.path.isfile(global_cfg):
        targets.append(global_cfg)

    found = 0
    fixed = 0
    for cfg in targets:
        try:
            text = open(cfg, encoding='utf-8').read()
        except (OSError, UnicodeDecodeError):
            continue
        # Two signals: an embedded user:token@ in a URL, OR any token
        # detect.py recognises sitting loose in the file.
        url_hits = list(_URL_CRED_RE.finditer(text))
        det_hits = find_secrets(text)
        if not url_hits and not det_hits:
            continue
        found += 1
        print(f'  ⚠ credential in {cfg}', file=sys.stderr)
        for m in url_hits:
            user = m.group(2)
            print(f'      embedded URL credential: {m.group(1)}{user}:'
                  f'[token]@{m.group(4)}', file=sys.stderr)
        if fix and url_hits:
            # Strip user:token@ → tokenless URL. Keep scheme + host.
            new = _URL_CRED_RE.sub(r'\1\4', text)
            try:
                open(cfg, 'w', encoding='utf-8').write(new)
                fixed += 1
                print(f'      ✓ stripped credential — URL now tokenless '
                      f'(git will use its credential helper)',
                      file=sys.stderr)
            except OSError as e:
                print(f'      ✗ could not rewrite {cfg}: {e}',
                      file=sys.stderr)

    verb = 'fixed' if fix else 'found'
    print(f'🔒 secret-scrub --git-configs: scanned {len(targets)} config(s), '
          f'{verb} {fixed if fix else found} with embedded credentials.',
          file=sys.stderr)
    if found and not fix:
        print('   → re-run with --fix to strip them, then set up a '
              'credential helper:  gh auth setup-git', file=sys.stderr)
        return 1  # alertable: a plaintext credential exists
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument('--staged', action='store_true')
    g.add_argument('--sessions', action='store_true')
    g.add_argument('--working-trees', nargs='+', metavar='PATH',
                   help='One or more git repo paths to scan modified + '
                        'untracked files in. Covers the leak pathway '
                        'pre-commit + sessions both miss: secrets sitting '
                        'in uncommitted files.')
    g.add_argument('--git-configs', nargs='+', metavar='PATH',
                   help='One or more git repo paths to audit their '
                        '.git/config (plus ~/.gitconfig) for embedded '
                        'credentials — tokenized remote URLs that the '
                        'other modes can\'t see. Detect-only by default; '
                        'add --fix to strip them.')
    ap.add_argument('--full', action='store_true',
                    help='With --sessions: ignore incremental state, '
                         'rescan every file. Use after detect.py grows '
                         'new patterns.')
    ap.add_argument('--fix', action='store_true',
                    help='With --git-configs: strip embedded credentials '
                         'from remote URLs (make them tokenless). Without '
                         'this, --git-configs only reports + exits 1.')
    args = ap.parse_args()
    if args.staged:
        return scrub_staged()
    if args.working_trees:
        return scrub_working_trees(args.working_trees)
    if args.git_configs:
        return scrub_git_configs(args.git_configs, fix=args.fix)
    return scrub_sessions(full=args.full)


if __name__ == '__main__':
    sys.exit(main())
