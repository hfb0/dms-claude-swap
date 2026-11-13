// Runs the real shell wrappers from ClaudeSwapLogic.qml against a fake cswap.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn, spawnSync } = require('child_process');
const L = require('./load-logic');

function sandbox(withCswap) {
    const home = fs.mkdtempSync(path.join(os.tmpdir(), 'claudeswap-'));
    const bin = path.join(home, '.local', 'bin');
    fs.mkdirSync(bin, { recursive: true });
    if (withCswap) {
        fs.writeFileSync(path.join(bin, 'cswap'),
            '#!/bin/sh\necho "args:$*"\n[ "$1" = auto ] && exec sleep 30\nexit 0\n', { mode: 0o755 });
    }
    // HOME points at the sandbox so the ~/.local/bin prefix finds only the fake.
    const env = { HOME: home, PATH: '/usr/bin:/bin' };
    return { home, env };
}

function run(cmd, env) {
    return spawnSync(cmd[0], cmd.slice(1), { env, encoding: 'utf8' });
}

test('missing cswap exits with exitMissing', () => {
    const { env } = sandbox(false);
    assert.equal(run(L.runCommand(['list', '--json']), env).status, L.exitMissing);
});

test('arguments reach cswap unchanged', () => {
    const { env } = sandbox(true);
    const r = run(L.runCommand(['switch', 'a b', '--json']), env);
    assert.equal(r.status, 0);
    assert.equal(r.stdout.trim(), 'args:switch a b --json');
});

test('opening the lock does not truncate an existing file', async () => {
    const { home, env } = sandbox(true);
    const lock = path.join(home, 'precious.txt');
    fs.writeFileSync(lock, 'keep me');
    const p = spawn(...(c => [c[0], c.slice(1)])(L.autoCommand(lock, 99.9)), { env });
    await new Promise(r => setTimeout(r, 300));
    p.kill('SIGTERM');
    await new Promise(r => p.on('exit', r));
    assert.equal(fs.readFileSync(lock, 'utf8'), 'keep me');
});

test('shell metacharacters in arguments stay literal', () => {
    const { home, env } = sandbox(true);
    const marker = path.join(home, 'pwned');
    const r = run(L.runCommand(['switch', '$(touch ' + marker + ')', '; touch ' + marker]), env);
    assert.equal(r.status, 0);
    assert.equal(fs.existsSync(marker), false);
});

test('auto loop: one instance holds the lock, it is released on SIGTERM', async () => {
    const { home, env } = sandbox(true);
    const lock = path.join(home, 'auto.lock');
    const first = spawn(...(c => [c[0], c.slice(1)])(L.autoCommand(lock, 99.9)), { env });
    let out = '';
    first.stdout.on('data', d => { out += d; });
    await new Promise(r => setTimeout(r, 300));
    assert.match(out, /args:auto --json --threshold 99\.9/);

    assert.equal(run(L.autoCommand(lock, 90), env).status, L.exitLocked);

    first.kill('SIGTERM');
    await new Promise(r => first.on('exit', r));

    const again = spawn(...(c => [c[0], c.slice(1)])(L.autoCommand(lock, 90)), { env });
    await new Promise(r => setTimeout(r, 300));
    assert.equal(again.exitCode, null, 'lock should be free after the holder exits');
    again.kill('SIGTERM');
    await new Promise(r => again.on('exit', r));
});

test('add account saves the current account first, then signs in and saves the new one', () => {
    for (const firstAddFails of [false, true]) {
        const { home, env } = sandbox(false);
        const bin = path.join(home, '.local', 'bin');
        const log = path.join(home, 'calls.log');
        // The first `cswap add` may fail (nobody signed in yet); the flow must go on.
        fs.writeFileSync(path.join(bin, 'cswap'),
            `#!/bin/sh\necho "cswap $*" >> "${log}"\n` +
            (firstAddFails ? `[ -e "${log}.once" ] || { touch "${log}.once"; exit 1; }\n` : '') + 'exit 0\n', { mode: 0o755 });
        fs.writeFileSync(path.join(bin, 'claude'), `#!/bin/sh\necho "claude $*" >> "${log}"\nexit 0\n`, { mode: 0o755 });
        const cmd = L.addAccountCommand([], ['intro', 'added', 'failed', 'enter']);
        const r = spawnSync(cmd[0], cmd.slice(1), { env: { ...env, PATH: bin + ':/usr/bin:/bin' }, input: '\n', encoding: 'utf8' });
        assert.equal(r.status, 0);
        assert.deepEqual(fs.readFileSync(log, 'utf8').trim().split('\n'), ['cswap add', 'claude auth login', 'cswap add']);
        assert.match(r.stdout, /added/);
    }
});

// A cswap launcher whose shebang names `interp` (uv and pipx write a venv python there).
function launcher(home, interp) {
    fs.writeFileSync(path.join(home, '.local', 'bin', 'cswap'), `#!${interp}\nexit 0\n`, { mode: 0o755 });
}

test('forced refresh: missing cswap exits with exitMissing', () => {
    const { env } = sandbox(false);
    assert.equal(run(L.forceRefreshCommand('/x/force-refresh.py'), env).status, L.exitMissing);
});

test('forced refresh runs the helper with the interpreter cswap runs on, isolated', () => {
    const { home, env } = sandbox(false);
    const py = path.join(home, 'venv python');
    fs.writeFileSync(py, '#!/bin/sh\nfor a in "$@"; do echo "arg:$a"; done\n', { mode: 0o755 });
    launcher(home, py);
    const helper = path.join(home, 'my plugin', '$(touch pwned).py');
    const r = run(L.forceRefreshCommand(helper), env);
    assert.equal(r.status, 0);
    assert.deepEqual(r.stdout.trim().split('\n'), ['arg:-I', 'arg:' + helper]);
    assert.equal(fs.existsSync(path.join(home, 'pwned')), false);
});

test('forced refresh gives up when the launcher does not name an interpreter path', () => {
    const { home, env } = sandbox(false);
    launcher(home, '/usr/bin/env python3');
    const r = run(L.forceRefreshCommand('/x/force-refresh.py'), env);
    assert.notEqual(r.status, 0);
    assert.notEqual(r.status, L.exitMissing);
});
