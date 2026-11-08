// Manifest and translation checks.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const manifest = JSON.parse(fs.readFileSync(path.join(ROOT, 'plugin.json'), 'utf8'));
const qmlFiles = fs.readdirSync(ROOT).filter(f => f.endsWith('.qml'));

test('plugin.json has the fields the registry checks', () => {
    for (const k of ['id', 'name', 'description', 'version', 'author', 'type', 'capabilities', 'component'])
        assert.ok(k in manifest, 'missing ' + k);
    assert.match(manifest.id, /^[a-z][a-zA-Z0-9]*$/);
    assert.match(manifest.version, /^\d+\.\d+\.\d+$/);
    for (const k of ['component', 'settings'])
        assert.ok(fs.existsSync(path.join(ROOT, manifest[k])), manifest[k] + ' not found');
});

test('every I18n.trFor call uses this plugin id and has a pt_BR entry', () => {
    const pt = JSON.parse(fs.readFileSync(path.join(ROOT, 'translations', 'pt_BR.json'), 'utf8'));
    const used = new Set();
    for (const f of qmlFiles) {
        const src = fs.readFileSync(path.join(ROOT, f), 'utf8');
        for (const m of src.matchAll(/I18n\.trFor\(\s*("(?:[^"\\]|\\.)*")\s*,\s*("(?:[^"\\]|\\.)*")/g)) {
            assert.equal(JSON.parse(m[1]), manifest.id, f + ': wrong plugin id');
            used.add(JSON.parse(m[2]));
        }
        assert.doesNotMatch(src, /I18n\.trFor\(\s*[^"\s]/, f + ': trFor needs literal arguments');
    }
    for (const s of used) {
        assert.ok(pt[s] && typeof pt[s][s] === 'string' && pt[s][s], 'missing pt_BR for: ' + s);
    }
    for (const s of Object.keys(pt)) assert.ok(used.has(s), 'unused pt_BR entry: ' + s);
});
