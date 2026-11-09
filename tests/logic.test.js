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

// ---- pace and alerts ----
const RESET = '2026-11-11T15:00:00.261113+00:00';
const acct = (n, five, week) => ({ number: n, alias: 'a' + n, usage: { fiveHour: five, sevenDay: week } });

test('pace reads cswap weekly pace fields and ignores windows without them', () => {
    assert.deepEqual(L.pace({ pct: 99, expectedPct: 64, aheadOfPace: true, willLastToReset: false }),
        { expected: 64, ahead: true, delta: 35 });
    assert.deepEqual(L.pace({ pct: 2, expectedPct: 23.5, aheadOfPace: false }), { expected: 23.5, ahead: false, delta: -22 });
    assert.equal(L.pace({ pct: 10 }), null);
    assert.equal(L.pace(null), null);
});

test('windowKey is stable across the sub-second drift of resetsAt', () => {
    assert.equal(L.windowKey(1, 'sevenDay', { resetsAt: '2026-11-11T14:59:59.619987+00:00' }),
                 L.windowKey(1, 'sevenDay', { resetsAt: RESET }));
    assert.notEqual(L.windowKey(1, 'sevenDay', { resetsAt: RESET }),
                    L.windowKey(1, 'sevenDay', { resetsAt: '2026-11-18T15:00:00Z' }));
});

test('usageAlerts fires the highest crossed level once per window cycle', () => {
    const opts = { levels: true, pace: false };
    let r = L.usageAlerts(acct(1, { pct: 10 }, { pct: 88, resetsAt: RESET }), {}, opts, NOW);
    assert.deepEqual(r.alerts.map(a => [a.kind, a.window, a.level]), [['level', 'sevenDay', 85]]);
    // same level again: silent
    r = L.usageAlerts(acct(1, { pct: 10 }, { pct: 89, resetsAt: RESET }), r.sent, opts, NOW);
    assert.equal(r.alerts.length, 0);
    // next level: fires
    r = L.usageAlerts(acct(1, { pct: 10 }, { pct: 96, resetsAt: RESET }), r.sent, opts, NOW);
    assert.deepEqual(r.alerts.map(a => a.level), [95]);
    // new cycle (different reset) starts over
    r = L.usageAlerts(acct(1, { pct: 10 }, { pct: 80, resetsAt: '2026-11-18T15:00:00Z' }), r.sent, opts, NOW);
    assert.deepEqual(r.alerts.map(a => a.level), [75]);
});

test('usageAlerts keeps other accounts\' state and drops expired cycles', () => {
    const opts = { levels: true, pace: false };
    const old = L.windowKey(9, 'fiveHour', { resetsAt: '2026-11-08T15:00:00Z' });   // before NOW
    let r = L.usageAlerts(acct(1, null, { pct: 76, resetsAt: RESET }), { [old]: 75 }, opts, NOW);
    assert.equal(old in r.sent, false);
    r = L.usageAlerts(acct(2, null, { pct: 50, resetsAt: RESET }), r.sent, opts, NOW);
    r = L.usageAlerts(acct(1, null, { pct: 77, resetsAt: RESET }), r.sent, opts, NOW);
    assert.equal(r.alerts.length, 0, 'switching away and back must not re-alert');
});

test('usageAlerts pace alert needs cswap\'s ahead marker and fires once', () => {
    const opts = { levels: false, pace: true };
    const week = { pct: 60, resetsAt: RESET, expectedPct: 40, aheadOfPace: true, willLastToReset: false };
    let r = L.usageAlerts(acct(1, null, week), {}, opts, NOW);
    assert.deepEqual(r.alerts.map(a => [a.kind, a.window, a.pct, a.expected]), [['pace', 'sevenDay', 60, 40]]);
    r = L.usageAlerts(acct(1, null, week), r.sent, opts, NOW);
    assert.equal(r.alerts.length, 0);
    // over expected but under cswap's noise gate: silent
    r = L.usageAlerts(acct(1, null, { ...week, aheadOfPace: false }), {}, opts, NOW);
    assert.equal(r.alerts.length, 0);
    // already past the top level: the level alert says it, no pace alert
    r = L.usageAlerts(acct(1, null, { ...week, pct: 97 }), {}, opts, NOW);
    assert.equal(r.alerts.length, 0);
});

test('usageAlerts ignores stale lastGoodUsage, unknown pct and disabled options', () => {
    const stale = { number: 1, lastGoodUsage: { sevenDay: { pct: 99, resetsAt: RESET } } };
    assert.equal(L.usageAlerts(stale, {}, { levels: true, pace: true }, NOW).alerts.length, 0);
    assert.equal(L.usageAlerts(acct(1, { pct: null }, null), {}, { levels: true, pace: true }, NOW).alerts.length, 0);
    assert.equal(L.usageAlerts(acct(1, null, { pct: 99, resetsAt: RESET }), {}, { levels: false, pace: false }, NOW).alerts.length, 0);
    assert.deepEqual(L.usageAlerts(null, { k: 1 }, { levels: true, pace: true }, NOW), { alerts: [], sent: { k: 1 } });
});

test('notifyCommand escapes markup and tags per account window', () => {
    const cmd = L.notifyCommand('T <b>', 'a & b', 'critical', 'claudeSwap-1-sevenDay');
    assert.deepEqual(cmd, ['dms', 'notify', '-a', 'Claude Swap', '-u', 'critical',
        '-h', 'string:x-dms-tag:claudeSwap-1-sevenDay', 'T &lt;b&gt;', 'a &amp; b']);
});

// ---- alias editing ----
test('normalizeAlias mirrors cswap\'s rules; empty means remove', () => {
    assert.deepEqual(L.normalizeAlias('  Work.Dev_2 '), { value: 'work.dev_2', error: '' });
    assert.deepEqual(L.normalizeAlias('   '), { value: '', error: '' });
    assert.equal(L.normalizeAlias('123').error, 'numeric');
    assert.equal(L.normalizeAlias('-rf').error, 'dash');
    assert.equal(L.normalizeAlias('my work').error, 'chars');
    assert.equal(L.normalizeAlias('a;rm').error, 'chars');
    assert.equal(L.normalizeAlias('çá').error, 'chars');
});

test('aliasArgs sets or unsets by slot number', () => {
    assert.deepEqual(L.aliasArgs(2, 'dev'), ['alias', '2', 'dev']);
    assert.deepEqual(L.aliasArgs(2, ''), ['alias', '2', '--unset']);
});

// ---- compact bar ----
test('tightest picks the window with the highest known usage', () => {
    assert.equal(L.tightest({ fiveHour: { pct: 2 }, sevenDay: { pct: 99 } }).pct, 99);
    assert.equal(L.tightest({ fiveHour: { pct: 40 }, sevenDay: { pct: 10 } }).pct, 40);
    assert.equal(L.tightest({ fiveHour: { pct: null }, sevenDay: { pct: 5 } }).pct, 5);
    assert.equal(L.tightest({ fiveHour: { pct: null } }), null);
    assert.equal(L.tightest(null), null);
});

// ---- custom threshold ----
test('parseThreshold accepts 50–100 (comma or dot), else null', () => {
    assert.equal(L.parseThreshold('87'), 87);
    assert.equal(L.parseThreshold(' 92,5 % '), 92.5);
    assert.equal(L.parseThreshold('100'), 100);
    assert.equal(L.parseThreshold('49'), null);
    assert.equal(L.parseThreshold('101'), null);
    assert.equal(L.parseThreshold('abc'), null);
    assert.equal(L.parseThreshold('9e1'), null);
    assert.equal(L.parseThreshold(''), null);
});

test('100 means "at limit" and reaches cswap as 99.9', () => {
    assert.equal(L.clampThreshold(100), 99.9);
    assert.equal(L.isPresetThreshold(100, [80, 90, 95, 100]), true);
    assert.equal(L.isPresetThreshold(99.9, [80, 90, 95, 100]), true);
    assert.equal(L.isPresetThreshold(87, [80, 90, 95, 100]), false);
});

test('color levels line up with the alert levels', () => {
    const warn = L.alertLevels[0], crit = L.alertLevels[L.alertLevels.length - 1];
    assert.deepEqual([warn, crit], [75, 95]);
    assert.equal(L.level(74, warn, crit), 'ok');
    assert.equal(L.level(75, warn, crit), 'warn');
    assert.equal(L.level(94, warn, crit), 'warn');
    assert.equal(L.level(95, warn, crit), 'crit');
});

test('labelFor resolves cswap\'s {number, email} refs to the alias', () => {
    const accounts = [{ number: 1, email: 'w@x.com', alias: 'work' }, { number: 2, email: 'p@x.com' }];
    assert.equal(L.labelFor({ number: 1, email: 'w@x.com' }, accounts), 'work');
    assert.equal(L.labelFor({ number: null, email: 'w@x.com' }, accounts), 'work');
    assert.equal(L.labelFor({ number: 2, email: 'p@x.com' }, accounts), 'p@x.com');
    assert.equal(L.labelFor({ number: 9, email: 'new@x.com' }, accounts), 'new@x.com');
    assert.equal(L.labelFor(null, accounts), '?');
});

// ---- per-model limits (scoped) ----
test('scopedWindows lists per-model limits that have a reading', () => {
    const fable = { name: 'Fable', pct: 100, resetsAt: RESET };
    assert.deepEqual(L.scopedWindows({ scoped: [fable] }), [{ name: 'Fable', win: fable }]);
    assert.deepEqual(L.scopedWindows({ scoped: [{ name: 'Opus', pct: null }, { pct: 5 }, null] }), []);
    assert.deepEqual(L.scopedWindows({}), []);
    assert.deepEqual(L.scopedWindows(null), []);
});

test('usageAlerts covers per-model limits with their own state', () => {
    const opts = { levels: true, pace: false };
    const a = { number: 1, usage: { sevenDay: { pct: 10, resetsAt: RESET }, scoped: [{ name: 'Fable', pct: 96, resetsAt: RESET }] } };
    let r = L.usageAlerts(a, {}, opts, NOW);
    assert.deepEqual(r.alerts.map(x => [x.window, x.model, x.level]), [['scoped:Fable', 'Fable', 95]]);
    r = L.usageAlerts(a, r.sent, opts, NOW);
    assert.equal(r.alerts.length, 0, 'fires once per cycle');
    const week = L.usageAlerts({ number: 1, usage: { sevenDay: { pct: 96, resetsAt: RESET } } }, r.sent, opts, NOW);
    assert.deepEqual(week.alerts.map(x => x.window), ['sevenDay'], 'weekly state is separate');
});

test('tightest ignores per-model limits', () => {
    assert.equal(L.tightest({ fiveHour: { pct: 3 }, sevenDay: { pct: 2 }, scoped: [{ name: 'Fable', pct: 100 }] }).pct, 3);
});

test('scopedWindows accepts the array-like lists Qt hands back from shared state', () => {
    // Values stored in PluginService.globalVars come back as QVariantList, for which
    // Array.isArray() is false; they still have indices and a length.
    const fable = { name: 'Fable', pct: 100, resetsAt: RESET };
    assert.deepEqual(L.scopedWindows({ scoped: { 0: fable, length: 1 } }), [{ name: 'Fable', win: fable }]);
    assert.deepEqual(L.scopedWindows({ scoped: 'Fable' }), []);
});
