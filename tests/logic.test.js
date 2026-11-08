const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const L = require('./load-logic');

const fixture = fs.readFileSync(path.join(__dirname, '..', 'fixtures', 'list.json'), 'utf8');
const NOW = Date.parse('2026-11-08T16:00:00Z') / 1000;

test('parseList reads accounts and the active number', () => {
    const r = L.parseList(fixture);
    assert.equal(r.error, undefined);
    assert.equal(r.activeNumber, 1);
    assert.equal(r.accounts.length, 2);
});

test('parseList reports cswap errors and bad output', () => {
    assert.deepEqual(L.parseList('{"schemaVersion":1,"error":{"message":"boom"}}'), { error: 'cswap', message: 'boom' });
    assert.equal(L.parseList('not json').error, 'parse');
    assert.equal(L.parseList('null').error, 'parse');
    assert.equal(L.parseList('{"accounts":[]}').activeNumber, -1);
});

test('label prefers alias, then email, then number', () => {
    const [work, home] = L.parseList(fixture).accounts;
    assert.equal(L.label(work), 'work@example.com');
    assert.equal(L.label(home), 'home');
    assert.equal(L.label({ number: 3 }), '#3');
    assert.equal(L.label('2'), '2');
    assert.equal(L.label(null), '?');
});

test('usageOf falls back to lastGoodUsage; pct rounds and flags unknown', () => {
    const [work, home] = L.parseList(fixture).accounts;
    assert.equal(L.pct(L.usageOf(work).fiveHour), 15);
    assert.equal(L.pct(L.usageOf(home).sevenDay), 0);
    assert.equal(L.pct(L.usageOf(home).fiveHour), -1);
    assert.equal(L.usageOf({}), null);
});

test('level thresholds', () => {
    assert.equal(L.level(69, 70, 90), 'ok');
    assert.equal(L.level(70, 70, 90), 'warn');
    assert.equal(L.level(90, 70, 90), 'crit');
});

test('countdown formats days, hours and minutes', () => {
    assert.equal(L.countdown('2026-11-11T15:00:00Z', NOW), '2d 23h');
    assert.equal(L.countdown('2026-11-08T17:00:00Z', NOW), '1h 0m');
    assert.equal(L.countdown('2026-11-08T16:00:20Z', NOW), '1m');
    assert.equal(L.countdown('2026-11-08T15:00:00Z', NOW), null);
    assert.equal(L.countdown('', NOW), '');
    assert.equal(L.countdown('garbage', NOW), '');
});

test('parseSwitch', () => {
    assert.deepEqual(L.parseSwitch('{"switched":true,"to":{"number":2},"reason":null}'),
        { ok: true, switched: true, to: { number: 2 }, reason: '' });
    assert.equal(L.parseSwitch('{"switched":false,"reason":"no-target"}').reason, 'no-target');
    assert.equal(L.parseSwitch('{"error":{"message":"bad"}}').reason, 'bad');
    assert.equal(L.parseSwitch('').ok, false);
});

test('parseAutoEvent keeps only switch and all-exhausted', () => {
    assert.deepEqual(L.parseAutoEvent('{"event":"switch","to":{"email":"a@b"}}'), { kind: 'switch', to: { email: 'a@b' } });
    assert.equal(L.parseAutoEvent('{"event":"all-exhausted"}').kind, 'exhausted');
    assert.equal(L.parseAutoEvent('{"event":"poll"}').kind, null);
    assert.equal(L.parseAutoEvent('{oops').kind, null);
});

test('clampThreshold keeps cswap\'s accepted range', () => {
    assert.equal(L.clampThreshold('90'), 90);
    assert.equal(L.clampThreshold('100'), 99.9);
    assert.equal(L.clampThreshold(10), 50);
    assert.equal(L.clampThreshold('x; rm -rf ~'), 99.9);
    assert.equal(L.clampThreshold(undefined), 99.9);
});

test('lockFile never falls back to a shared /tmp', () => {
    assert.equal(L.lockFile('/run/user/1000', '/home/u'), '/run/user/1000/dms-claude-swap-auto.lock');
    assert.equal(L.lockFile('', '/home/u'), '/home/u/.cache/dms-claude-swap-auto.lock');
    assert.equal(L.lockFile(undefined, '/home/u'), '/home/u/.cache/dms-claude-swap-auto.lock');
});

test('switchArgs and addAccountCommand', () => {
    assert.deepEqual(L.switchArgs('best'), ['switch', '--strategy', 'best', '--json']);
    assert.deepEqual(L.switchArgs(2), ['switch', '2', '--json']);
    const cmd = L.addAccountCommand(['gnome-terminal', '--'], ['a', 'b', 'c', 'd']);
    assert.deepEqual(cmd.slice(0, 4), ['gnome-terminal', '--', 'sh', '-c']);
    assert.deepEqual(cmd.slice(-5), ['sh', 'a', 'b', 'c', 'd']);
});
