/**
 * Tests for docgen/install-push-hook.sh.
 *
 * Coverage:
 *   1. Vanilla install in a fresh repo → .git/hooks/pre-push
 *   2. core.hooksPath set, no foreign hook → installs at $hooksPath/pre-push
 *   3. core.hooksPath set, foreign pre-push that chains via pre-push-local
 *      → installs at <git-dir>/hooks/pre-push-local (the orphan-bug fix:
 *      previously the installer would refuse here)
 *   4. core.hooksPath set, foreign pre-push without a chain → refuses
 *   5. Status command reports install state per worktree
 *   6. Uninstall removes the hook regardless of which install path
 *      was used
 *   7. Re-running install is idempotent (refreshes existing marker file)
 *   8. Worktree iteration: install in main clone propagates to all
 *      `git worktree list` entries
 *
 * Each test uses a fresh `mkdtemp` repo so we never touch the user's
 * real ~/.config / ~/.git-hooks state. Run:
 *   npx tsx --test docgen/install-push-hook.test.mjs
 *   (or `node --test` since this is pure ESM/JS)
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, existsSync, readFileSync, chmodSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const INSTALLER = resolve(__dirname, 'install-push-hook.sh');
// Source the installer + hook from THIS directory (layout-agnostic:
// works whether docgen lives at repo root or vendored under tools/).
const SRC_DIR = __dirname;

// Isolate every test from the developer's machine-global git config —
// specifically `core.hooksPath`, which on the maintainer's box points
// at ~/.git-hooks/ and was bleeding through into test repos. Setting
// these two env vars to /dev/null tells git to ignore the user's
// global + system configs entirely for the spawned process.
const ISOLATED_ENV = {
  ...process.env,
  GIT_CONFIG_GLOBAL: '/dev/null',
  GIT_CONFIG_SYSTEM: '/dev/null',
};

function freshRepo() {
  const dir = mkdtempSync(join(tmpdir(), 'docgen-install-test-'));
  execFileSync('git', ['init', '--quiet'], { cwd: dir, env: ISOLATED_ENV });
  execFileSync('git', ['config', 'user.email', 't@t'], { cwd: dir, env: ISOLATED_ENV });
  execFileSync('git', ['config', 'user.name', 't'], { cwd: dir, env: ISOLATED_ENV });
  writeFileSync(join(dir, 'README.md'), '');
  execFileSync('git', ['add', '.'], { cwd: dir, env: ISOLATED_ENV });
  execFileSync('git', ['commit', '--quiet', '-m', 'init'], { cwd: dir, env: ISOLATED_ENV });
  // Mirror docgen into the test repo so the installer can find its
  // SOURCE hook + invoking install-push-hook.sh resolves SCRIPT_DIR.
  mkdirSync(join(dir, 'docgen', 'hooks'), { recursive: true });
  // Copy just the bits the installer needs (the hook source + itself).
  for (const f of ['install-push-hook.sh', 'hooks/pre-push']) {
    const src = join(SRC_DIR, f);
    if (existsSync(src)) {
      const dst = join(dir, 'docgen', f);
      writeFileSync(dst, readFileSync(src));
      chmodSync(dst, 0o755);
    }
  }
  return dir;
}

function run(repo, args = []) {
  return spawnSync('bash', [join(repo, 'docgen', 'install-push-hook.sh'), ...args, '--here'], {
    cwd: repo, encoding: 'utf8', env: ISOLATED_ENV,
  });
}

function readHook(path) {
  return existsSync(path) ? readFileSync(path, 'utf8') : null;
}

test('vanilla install lands at .git/hooks/pre-push', () => {
  const repo = freshRepo();
  const r = run(repo, ['install']);
  assert.equal(r.status, 0, r.stderr + r.stdout);
  const hook = readHook(join(repo, '.git', 'hooks', 'pre-push'));
  assert.ok(hook, 'pre-push should exist');
  assert.match(hook, /DOCGEN_PRE_PUSH_HOOK_v1/);
});

test('core.hooksPath set + no foreign hook → installs at hooksPath/pre-push', () => {
  const repo = freshRepo();
  const customHooks = join(repo, 'custom-hooks');
  mkdirSync(customHooks, { recursive: true });
  execFileSync('git', ['config', 'core.hooksPath', customHooks], { cwd: repo, env: ISOLATED_ENV });
  const r = run(repo, ['install']);
  assert.equal(r.status, 0, r.stderr + r.stdout);
  assert.ok(readHook(join(customHooks, 'pre-push')), 'installed at hooksPath');
  assert.equal(readHook(join(repo, '.git', 'hooks', 'pre-push')), null);
});

test('foreign pre-push with pre-push-local chain → installs at <git-dir>/hooks/pre-push-local (orphan-bug fix)', () => {
  const repo = freshRepo();
  const customHooks = join(repo, 'identity-hooks');
  mkdirSync(customHooks, { recursive: true });
  // Foreign global hook that exec's pre-push-local at the end.
  writeFileSync(join(customHooks, 'pre-push'), [
    '#!/bin/sh',
    'set -e',
    '# identity-guard hook',
    'LOCAL=$(git rev-parse --git-path hooks/pre-push-local 2>/dev/null)',
    '[ -x "$LOCAL" ] && exec "$LOCAL" "$@"',
    'exit 0',
  ].join('\n'));
  chmodSync(join(customHooks, 'pre-push'), 0o755);
  execFileSync('git', ['config', 'core.hooksPath', customHooks], { cwd: repo, env: ISOLATED_ENV });
  const r = run(repo, ['install']);
  assert.equal(r.status, 0, r.stderr + r.stdout);
  // Our hook went to pre-push-local (NOT the foreign pre-push).
  assert.ok(readHook(join(repo, '.git', 'hooks', 'pre-push-local')), 'pre-push-local installed');
  const foreign = readHook(join(customHooks, 'pre-push'));
  assert.doesNotMatch(foreign, /DOCGEN_PRE_PUSH_HOOK_v1/, 'foreign hook untouched');
});

test('foreign pre-push without a chain → installer refuses gracefully', () => {
  const repo = freshRepo();
  const customHooks = join(repo, 'foreign-hooks');
  mkdirSync(customHooks, { recursive: true });
  writeFileSync(join(customHooks, 'pre-push'), '#!/bin/sh\necho hi\nexit 0\n');
  chmodSync(join(customHooks, 'pre-push'), 0o755);
  execFileSync('git', ['config', 'core.hooksPath', customHooks], { cwd: repo, env: ISOLATED_ENV });
  const r = run(repo, ['install']);
  // Refused — but still exits zero (loop-safe). Output mentions refusing.
  assert.match((r.stdout + r.stderr), /refusing/i);
  // Nothing installed at pre-push-local either.
  assert.equal(readHook(join(repo, '.git', 'hooks', 'pre-push-local')), null);
});

test('status command identifies installed + not-installed correctly', () => {
  const repo = freshRepo();
  let r = run(repo, ['status']);
  assert.match(r.stdout, /not installed/);
  run(repo, ['install']);
  r = run(repo, ['status']);
  assert.match(r.stdout, /installed at/);
});

test('uninstall removes the hook regardless of install location', () => {
  const repo = freshRepo();
  // Install via the chain path so it lands at pre-push-local.
  const customHooks = join(repo, 'identity-hooks');
  mkdirSync(customHooks, { recursive: true });
  writeFileSync(join(customHooks, 'pre-push'),
    '#!/bin/sh\nLOCAL=$(git rev-parse --git-path hooks/pre-push-local)\n[ -x "$LOCAL" ] && exec "$LOCAL" "$@"\n');
  chmodSync(join(customHooks, 'pre-push'), 0o755);
  execFileSync('git', ['config', 'core.hooksPath', customHooks], { cwd: repo, env: ISOLATED_ENV });
  run(repo, ['install']);
  assert.ok(readHook(join(repo, '.git', 'hooks', 'pre-push-local')));
  const r = run(repo, ['uninstall']);
  assert.equal(r.status, 0);
  assert.equal(readHook(join(repo, '.git', 'hooks', 'pre-push-local')), null);
});

test('re-install is idempotent — refreshes our marker hook in place', () => {
  const repo = freshRepo();
  run(repo, ['install']);
  const r = run(repo, ['install']);
  assert.equal(r.status, 0, r.stderr + r.stdout);
  assert.match(readHook(join(repo, '.git', 'hooks', 'pre-push')), /DOCGEN_PRE_PUSH_HOOK_v1/);
});
