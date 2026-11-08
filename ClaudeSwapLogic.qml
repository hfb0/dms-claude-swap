// Pure helpers used by ClaudeSwapWidget.qml. Kept free of QML bindings so
// tests/load-logic.js can run them under node. Only plain `function`s and
// `readonly property var NAME: value` lines belong here.
import QtQuick

QtObject {
    // uv and pipx install into ~/.local/bin, which is often missing from the session PATH.
    readonly property var pathPrefix: 'export PATH="$HOME/.local/bin:$PATH"; '

    // Exit code used by the shell wrappers when cswap is not installed.
    readonly property var exitMissing: 127
    // Exit code of the auto loop when another instance holds the lock.
    readonly property var exitLocked: 75

    function runCommand(args) {
        return ["sh", "-c", pathPrefix + 'command -v cswap >/dev/null || exit 127; exec cswap "$@"', "sh"].concat(args)
    }

    // Lock lives in the private runtime dir; ~/.cache is the fallback, never a shared /tmp.
    function lockFile(runtimeDir, home) {
        return (runtimeDir ? runtimeDir : home + "/.cache") + "/dms-claude-swap-auto.lock"
    }

    // cswap accepts 50–99.9; anything else (or garbage) falls back to 99.9.
    function clampThreshold(t) {
        var n = parseFloat(t)
        if (isNaN(n)) return 99.9
        return Math.min(99.9, Math.max(50, n))
    }

    // exec keeps the lock fd on cswap itself, so stopping the process releases the lock.
    // `>>` opens without truncating, so a pre-existing file at the path is left intact.
    function autoCommand(lockPath, threshold) {
        return ["sh", "-c", pathPrefix + 'exec 9>>"$1"; flock -n 9 || exit 75; exec cswap auto --json --threshold "$2"',
                "sh", lockPath, String(threshold)]
    }

    // terminalPrefix: argv that runs a command in a terminal, e.g. ["kitty", "-e"].
    // messages: [intro, added, failed, pressEnter]
    function addAccountCommand(terminalPrefix, messages) {
        var script = 'echo "$1"; echo; claude auth login && cswap add && echo && echo "$2" || echo "$3"; '
            + 'echo; printf "%s" "$4"; read x'
        return terminalPrefix.concat(["sh", "-c", pathPrefix + script, "sh"]).concat(messages)
    }

    function switchArgs(target) {
        return target === "best" ? ["switch", "--strategy", "best", "--json"] : ["switch", String(target), "--json"]
    }

    function label(a) {
        if (!a) return "?"
        if (typeof a !== "object") return String(a)
        return a.alias || a.email || ("#" + a.number)
    }

    function usageOf(a) {
        return a ? (a.usage || a.lastGoodUsage || null) : null
    }

    // Rounded percentage of a usage window, or -1 when unknown.
    function pct(w) {
        return w && w.pct !== null && w.pct !== undefined ? Math.round(w.pct) : -1
    }

    function level(p, warnPct, critPct) {
        return p >= critPct ? "crit" : p >= warnPct ? "warn" : "ok"
    }

    // "" when there is no reset time, null when it already passed, else "5d 3h" / "2h 10m" / "8m".
    function countdown(iso, nowSec) {
        if (!iso) return ""
        var reset = Date.parse(iso)
        if (isNaN(reset)) return ""
        var s = Math.floor(reset / 1000) - nowSec
        if (s <= 0) return null
        var d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60)
        if (d > 0) return d + "d " + h + "h"
        if (h > 0) return h + "h " + m + "m"
        return Math.max(1, m) + "m"
    }

    // `cswap list --json` -> {accounts, activeNumber} or {error: "cswap" | "parse", message}
    function parseList(out) {
        var o
        try { o = JSON.parse(out) } catch (e) { return { error: "parse", message: "" } }
        if (!o || typeof o !== "object") return { error: "parse", message: "" }
        if (o.error) return { error: "cswap", message: o.error.message || "" }
        var n = o.activeAccountNumber
        return {
            accounts: Array.isArray(o.accounts) ? o.accounts : [],
            activeNumber: n === undefined || n === null ? -1 : n
        }
    }

    // `cswap switch --json` -> {ok, switched, to, reason}
    function parseSwitch(out) {
        var o
        try { o = JSON.parse(out) } catch (e) { return { ok: false } }
        if (!o || typeof o !== "object") return { ok: false }
        return {
            ok: true,
            switched: o.switched === true,
            to: o.to,
            reason: o.reason || (o.error && o.error.message) || ""
        }
    }

    // One line of `cswap auto --json` -> "switch" | "exhausted" | null, plus the target.
    function parseAutoEvent(line) {
        var ev
        try { ev = JSON.parse(line) } catch (e) { return { kind: null } }
        if (!ev || typeof ev !== "object") return { kind: null }
        if (ev.event === "switch") return { kind: "switch", to: ev.to }
        if (ev.event === "all-exhausted") return { kind: "exhausted" }
        return { kind: null }
    }
}
