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

    // A threshold typed by the user: 50–100 (100 = at limit), comma or dot decimals.
    // Returns the number, or null when it is not a plain number in range.
    function parseThreshold(s) {
        var v = String(s || "").replace("%", "").trim().replace(",", ".")
        if (!/^[0-9]+(\.[0-9]+)?$/.test(v)) return null
        var n = parseFloat(v)
        return n >= 50 && n <= 100 ? n : null
    }

    // Compared after clamping, so a stored 99.9 and the "at limit" preset (100) match.
    function isPresetThreshold(t, presets) {
        for (var i = 0; i < presets.length; i++)
            if (Math.abs(clampThreshold(t) - clampThreshold(presets[i])) < 0.01) return true
        return false
    }

    // exec keeps the lock fd on cswap itself, so stopping the process releases the lock.
    // `>>` opens without truncating, so a pre-existing file at the path is left intact.
    function autoCommand(lockPath, threshold) {
        return ["sh", "-c", pathPrefix + 'exec 9>>"$1"; flock -n 9 || exit 75; exec cswap auto --json --threshold "$2"',
                "sh", lockPath, String(threshold)]
    }

    // terminalPrefix: argv that runs a command in a terminal, e.g. ["kitty", "-e"].
    // messages: [intro, added, failed, pressEnter]
    // The first `cswap add` saves the account signed in now, so the new login does not
    // replace credentials cswap never stored. Re-adding a saved account only refreshes
    // it, and a failure there (nobody signed in yet) is ignored.
    function addAccountCommand(terminalPrefix, messages) {
        var script = 'echo "$1"; echo; cswap add </dev/null >/dev/null 2>&1; '
            + 'claude auth login && cswap add && echo && echo "$2" || echo "$3"; '
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

    // cswap's switch and auto events carry only {number, email}; the alias lives in
    // the account list, so look the account up there first.
    function labelFor(ref, accounts) {
        if (ref && typeof ref === "object" && accounts) {
            for (var i = 0; i < accounts.length; i++) {
                var a = accounts[i]
                if ((ref.number !== null && ref.number !== undefined && a.number === ref.number)
                        || (ref.email && a.email === ref.email))
                    return label(a)
            }
        }
        return label(ref)
    }

    function usageOf(a) {
        return a ? (a.usage || a.lastGoodUsage || null) : null
    }

    // Rounded percentage of a usage window, or -1 when unknown.
    function pct(w) {
        return w && w.pct !== null && w.pct !== undefined ? Math.round(w.pct) : -1
    }

    // The window closest to its limit (highest known usage), or null.
    function tightest(u) {
        if (!u) return null
        var best = null
        var wins = [u.fiveHour, u.sevenDay]
        for (var i = 0; i < wins.length; i++)
            if (pct(wins[i]) >= 0 && (!best || wins[i].pct > best.pct)) best = wins[i]
        return best
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

    // ---- alias editing ----

    // Same rules as cswap's normalize_alias, checked here for instant feedback
    // (cswap validates again). "" means remove the alias.
    // error: "" | "numeric" | "dash" | "chars"
    function normalizeAlias(s) {
        var v = String(s || "").trim().toLowerCase()
        if (!v) return { value: "", error: "" }
        if (/^[0-9]+$/.test(v)) return { value: v, error: "numeric" }
        if (v.charAt(0) === "-") return { value: v, error: "dash" }
        if (!/^[a-z0-9_.-]+$/.test(v)) return { value: v, error: "chars" }
        return { value: v, error: "" }
    }

    function aliasArgs(n, alias) {
        return alias ? ["alias", String(n), alias] : ["alias", String(n), "--unset"]
    }

    // ---- pace and alerts ----

    // Usage levels that raise a notification, lowest first. Two on purpose: near
    // the end of a session usage climbs fast, and a third level arrived minutes
    // after the previous one.
    readonly property var alertLevels: [80, 95]
    readonly property var alertWindows: ["fiveHour", "sevenDay"]

    // cswap only computes pace for weekly windows, and only once a cycle is under way.
    // `ahead` is cswap's noise-gated marker (15 points over the linear pace).
    function pace(w) {
        if (!w || typeof w.expectedPct !== "number" || typeof w.pct !== "number") return null
        return { expected: w.expectedPct, ahead: w.aheadOfPace === true, delta: Math.round(w.pct) - Math.round(w.expectedPct) }
    }

    // resetsAt drifts by fractions of a second between readings, so it is bucketed to 10 minutes.
    function resetBucket(w) {
        var t = w && w.resetsAt ? Date.parse(w.resetsAt) : NaN
        return isNaN(t) ? -1 : Math.round(t / 600000)
    }

    function windowKey(n, name, w) {
        return n + "|" + name + "|" + resetBucket(w)
    }

    // True once the window's reset time is behind us. cswap keeps serving the
    // previous reading for a minute or so after a reset (100%, reset in the past).
    function resetPassed(w, nowSec) {
        var t = w && w.resetsAt ? Date.parse(w.resetsAt) : NaN
        return !isNaN(t) && t / 1000 <= nowSec
    }

    // Whether the auto switch could use this account: enabled, with a reading, and
    // every known 5h/weekly window under the switch line. A window whose reset has
    // passed counts as renewed. Per-model limits are left out, as in cswap auto's
    // default decision (it only watches them when autoswitch.model names them).
    function hasRoom(a, threshold, nowSec) {
        if (!a || a.disabled) return false
        var u = usageOf(a)
        if (!u) return false
        var known = 0
        var wins = [u.fiveHour, u.sevenDay]
        for (var i = 0; i < wins.length; i++) {
            var w = wins[i]
            if (!w || typeof w.pct !== "number") continue
            known++
            if (!resetPassed(w, nowSec) && w.pct >= threshold) return false
        }
        return known > 0
    }

    // Another account the auto switch could move to. `accounts` may be a QVariantList.
    function hasFallback(accounts, activeNumber, threshold, nowSec) {
        var n = accounts && typeof accounts.length === "number" ? accounts.length : 0
        for (var i = 0; i < n; i++)
            if (accounts[i] && accounts[i].number !== activeNumber && hasRoom(accounts[i], threshold, nowSec))
                return true
        return false
    }

    // Some 5h/weekly window is at 100% and has not reset yet.
    function atLimit(a, nowSec) {
        var u = usageOf(a)
        if (!u) return false
        var wins = [u.fiveHour, u.sevenDay]
        for (var i = 0; i < wins.length; i++)
            if (wins[i] && typeof wins[i].pct === "number" && wins[i].pct >= 100 && !resetPassed(wins[i], nowSec))
                return true
        return false
    }

    // Whole minutes since an ISO time (cswap's usageFetchedAt), or -1.
    function ageMinutes(iso, nowSec) {
        var t = iso ? Date.parse(iso) : NaN
        return isNaN(t) ? -1 : Math.max(0, Math.floor((nowSec - t / 1000) / 60))
    }

    // Per-model weekly limits (cswap's `scoped`, e.g. Fable) that have a reading.
    // Model names never contain "|", which windowKey uses as a separator.
    // Lists read back from PluginService.globalVars are QVariantLists, not JS arrays
    // (Array.isArray is false), so anything with a numeric length is accepted.
    function scopedWindows(u) {
        var out = []
        var list = u && u.scoped && typeof u.scoped === "object" && typeof u.scoped.length === "number" ? u.scoped : []
        for (var i = 0; i < list.length; i++) {
            var w = list[i]
            if (w && typeof w.name === "string" && w.name && w.name.indexOf("|") < 0 && typeof w.pct === "number")
                out.push({ name: w.name, win: w })
        }
        return out
    }

    // Alerts for the active account. `sent` maps windowKey -> highest level already
    // notified (and windowKey + "|pace" -> 1); it is returned updated, with the
    // cycles that have already reset dropped. Only fresh readings count: an alert
    // from lastGoodUsage would report old numbers as news, and neither does a
    // window whose reset already passed.
    // opts: {levels: bool, pace: bool, quiet: bool}. `quiet` (another account can
    // take over) skips every alert without recording it, so the current level
    // still fires once that reserve is gone.
    function usageAlerts(acct, sent, opts, nowSec) {
        if (!acct) return { alerts: [], sent: sent }
        var next = {}
        for (var k in sent) {
            // The bucket rounds resetsAt to 10 minutes, up to 5 minutes early:
            // keep the entry a full bucket longer so a live window is never forgotten.
            var bucket = parseInt(k.split("|")[2], 10)
            if (bucket * 600 + 600 > nowSec) next[k] = sent[k]
        }
        var alerts = []
        if (opts.quiet) return { alerts: alerts, sent: next }
        var top = alertLevels[alertLevels.length - 1]
        var u = acct.usage || {}
        // Account-wide windows, then per-model ones ("scoped:Fable"), each with its own state.
        var entries = []
        for (var i = 0; i < alertWindows.length; i++)
            entries.push({ name: alertWindows[i], w: u[alertWindows[i]], model: "" })
        var sc = scopedWindows(u)
        for (var s = 0; s < sc.length; s++)
            entries.push({ name: "scoped:" + sc[s].name, w: sc[s].win, model: sc[s].name })
        for (var e = 0; e < entries.length; e++) {
            var name = entries[e].name, w = entries[e].w, model = entries[e].model
            if (!w || typeof w.pct !== "number" || resetBucket(w) < 0 || resetPassed(w, nowSec)) continue
            var key = windowKey(acct.number, name, w)
            if (opts.levels) {
                var hit = 0
                for (var j = 0; j < alertLevels.length; j++)
                    if (w.pct >= alertLevels[j]) hit = alertLevels[j]
                if (hit > (next[key] || 0)) {
                    alerts.push({ kind: "level", window: name, model: model, level: hit, pct: Math.round(w.pct), resetsAt: w.resetsAt })
                    next[key] = hit
                }
            }
            // Pace alerts stay account-wide: their text speaks of the weekly limit.
            var p = model ? null : pace(w)
            if (opts.pace && p && p.ahead && w.willLastToReset === false && w.pct < top && !next[key + "|pace"]) {
                alerts.push({ kind: "pace", window: name, pct: Math.round(w.pct), expected: Math.round(p.expected), resetsAt: w.resetsAt })
                next[key + "|pace"] = 1
            }
        }
        return { alerts: alerts, sent: next }
    }

    function escapeMarkup(s) {
        return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    }

    // The tag makes a newer alert for the same window replace the previous one.
    function notifyCommand(title, body, urgency, tag) {
        return ["dms", "notify", "-a", "Claude Swap", "-u", urgency, "-h", "string:x-dms-tag:" + tag,
                escapeMarkup(title), escapeMarkup(body)]
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

    // One line of `cswap auto --json` -> "switch" | "exhausted" | null, plus the target
    // or the earliest time an account comes back ("" when cswap does not know).
    function parseAutoEvent(line) {
        var ev
        try { ev = JSON.parse(line) } catch (e) { return { kind: null } }
        if (!ev || typeof ev !== "object") return { kind: null }
        if (ev.event === "switch") return { kind: "switch", to: ev.to }
        if (ev.event === "all-exhausted") return { kind: "exhausted", resetsAt: ev.earliestResetAt || "" }
        return { kind: null }
    }
}
