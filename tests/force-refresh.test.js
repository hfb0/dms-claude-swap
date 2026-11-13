// force-refresh.py against a fake claude_swap (tests/fake-cswap): which accounts it
// makes due, and how it fails when cswap's internals do not match.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const helper = path.join(__dirname, '..', 'force-refresh.py');

function runHelper(pythonPath, mode) {
    const log = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'claudeswap-')), 'calls.log');
    const env = { PATH: process.env.PATH, PYTHONPATH: pythonPath, PYTHONDONTWRITEBYTECODE: '1', FAKE_LOG: log, FAKE_MODE: mode || '' };
    const r = spawnSync('python3', [helper], { env, encoding: 'utf8' });
    const calls = fs.existsSync(log) ? fs.readFileSync(log, 'utf8').trim().split('\n').map(l => JSON.parse(l)) : [];
    return { r, calls };
}

test('marks due only accounts read 30 s ago or more, outside backoff and holds', () => {
    const { r, calls } = runHelper(path.join(__dirname, 'fake-cswap'));
    assert.equal(r.status, 0, r.stderr);
    assert.equal(r.stdout.trim(), 'due 2 5');
    assert.deepEqual(calls, [
        ['plan', { '2': [1000, 270], '5': [1000, null] }],   // keeps each account's interval
        ['collect', ['2', '5']],
    ]);
});

test('exits non-zero when cswap is missing or its internals changed', () => {
    assert.equal(runHelper(os.tmpdir()).r.status, 3);
    const broken = runHelper(path.join(__dirname, 'fake-cswap'), 'broken');
    assert.equal(broken.r.status, 2);
    assert.deepEqual(broken.calls, []);
});
