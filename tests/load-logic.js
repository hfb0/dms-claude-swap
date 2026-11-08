// Loads ClaudeSwapLogic.qml as plain JS: strips the QtObject wrapper and turns
// `readonly property var NAME: value` into `var NAME = value`.
const fs = require('fs');
const path = require('path');

const qml = fs.readFileSync(path.join(__dirname, '..', 'ClaudeSwapLogic.qml'), 'utf8');
const start = qml.indexOf('QtObject {');
const end = qml.lastIndexOf('}');
if (start < 0 || end < start) throw new Error('ClaudeSwapLogic.qml: QtObject block not found');

const body = qml.slice(start + 'QtObject {'.length, end)
    .replace(/^(\s*)readonly property var (\w+):\s*(.*)$/gm, '$1var $2 = $3');

// Top-level members sit at exactly four spaces of indentation.
const names = [...body.matchAll(/^ {4}(?:var|function) (\w+)/gm)].map(m => m[1]);
module.exports = new Function(body + '\nreturn {' + names.join(',') + '};')();
