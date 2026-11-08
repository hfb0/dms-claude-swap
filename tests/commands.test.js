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
