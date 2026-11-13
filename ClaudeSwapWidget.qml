// Claude Code accounts via claude-swap (cswap): per-account usage, one-click
// switching, and an optional `cswap auto` loop owned by the shell.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.DCommon.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root
    pluginId: "claudeSwap"

    ClaudeSwapLogic { id: logic }

    // Colors follow the alert levels (80/95): yellow from the first alert, red from the urgent one.
    readonly property int warnPct: logic.alertLevels[0]
    readonly property int critPct: logic.alertLevels[logic.alertLevels.length - 1]

    readonly property bool autoOn: pluginData.autoSwap === true
    // cswap accepts 50–99.9 and rejects 100, so 99.9 stands in for "when exhausted".
    readonly property real threshold: logic.clampThreshold(pluginData.threshold)
    // 100 is the "at limit" preset; clampThreshold hands cswap 99.9 for it.
    readonly property var thresholdOptions: [80, 90, 95, 100]
    function thresholdLabel(t) { return t >= 99.9 ? "100%" : t + "%" }
    function setThreshold(t) {
        if (pluginService) pluginService.savePluginData(pluginId, "threshold", String(t))
    }
    property bool editingThreshold: false
    // One editor open at a time.
    onEditingThresholdChanged: if (editingThreshold) editingNumber = -1
    onEditingNumberChanged: if (editingNumber >= 0) editingThreshold = false

    // One widget instance exists per bar/screen. They elect a single owner through
    // PluginService.globalVars: only the owner polls cswap and runs the auto loop,
    // and every instance renders the state it publishes.
    readonly property string instanceToken: Math.random().toString(36).slice(2) + Date.now().toString(36)
    readonly property var shared: PluginService.globalVars[pluginId] || ({})
    readonly property bool isOwner: shared.owner === instanceToken
    // Taken over when the owner stops publishing (e.g. it died without onDestruction).
    readonly property int ownerStaleSeconds: 150

    readonly property var accounts: shared.accounts || []
    readonly property int activeNumber: shared.activeNumber === undefined ? -1 : shared.activeNumber
    readonly property bool installed: shared.installed !== false
    readonly property bool loaded: shared.loaded === true
    readonly property string lastError: shared.lastError || ""
    property bool busy: false
    property int now: Math.floor(Date.now() / 1000)

    // The flock still guards the short overlap when a reload replaces the owner.
    readonly property string lockPath: logic.lockFile(Quickshell.env("XDG_RUNTIME_DIR"), Quickshell.env("HOME"))
    readonly property int maxLockRetries: 5
    property int lockRetries: 0

    readonly property var active: accounts.find(a => a.number === activeNumber) || null

    // Always through the account list, so refs from cswap events show the alias too.
    function label(a) { return logic.labelFor(a, accounts) }
    function usageOf(a) { return logic.usageOf(a) }
    function pct(w) { return logic.pct(w) }
    function color(p) {
        const l = logic.level(p, warnPct, critPct)
        return l === "crit" ? Theme.error : l === "warn" ? Theme.warning : Theme.primary
    }
    // Pace display can be turned off in the settings (pace alerts have their own toggle).
    readonly property bool showPace: pluginData.showPace !== false
    function paceText(pace) {
        // Kept short: the tooltip is one line, and the marker already shows the expected usage.
        return pace.ahead
            ? I18n.trFor("claudeSwap", "+%1 pts vs pace").arg(pace.delta)
            : I18n.trFor("claudeSwap", "On pace")
    }
    function nowSec() { return Math.floor(Date.now() / 1000) }
    // "" when unknown or already past: cswap still shows the old reading for a minute
    // or so after a reset, and "resets in now" reads wrong.
    function countdown(iso, at) {
        return logic.countdown(iso, at === undefined ? now : at) || ""
    }
    function summary(a) {
        const u = usageOf(a)
        if (!u) return a.usageStatus && a.usageStatus !== "ok" ? I18n.trFor("claudeSwap", "no reading (%1)").arg(a.usageStatus) : I18n.trFor("claudeSwap", "no reading")
        const parts = []
        const f = pct(u.fiveHour), w = pct(u.sevenDay)
        const c = f >= 0 ? countdown(u.fiveHour.resetsAt) : ""
        if (f >= 0) parts.push(c ? I18n.trFor("claudeSwap", "5h %1% · resets in %2").arg(f).arg(c) : I18n.trFor("claudeSwap", "5h %1%").arg(f))
        if (w >= 0) parts.push(I18n.trFor("claudeSwap", "week %1%").arg(w))
        return parts.join(" · ")
    }

    // ---- shared state ----
    function publish(state) {
        for (const k in state)
            PluginService.setGlobalVar(pluginId, k, state[k])
    }

    function claimOwnership() {
        const seen = shared.ownerSeen || 0
        if (!shared.owner || now - seen > ownerStaleSeconds)
            publish({ owner: instanceToken, ownerSeen: now })
    }

    onIsOwnerChanged: {
        lockRetries = 0
        syncAuto()
        if (isOwner) refresh()
    }

    // ---- cswap ----
    function run(id, args, cb) {
        Proc.runCommand(id, logic.runCommand(args), cb, 0, 60000)
    }

    function refresh() {
        run("claudeSwap.list", ["list", "--json"], function (out, code) {
            if (code === logic.exitMissing) {
                root.publish({ loaded: true, installed: false })
                return
            }
            const r = logic.parseList(out)
            if (r.error === "cswap")
                root.publish({ loaded: true, installed: true, lastError: r.message || I18n.trFor("claudeSwap", "cswap error") })
            else if (r.error)
                root.publish({ loaded: true, installed: true, lastError: I18n.trFor("claudeSwap", "unexpected output from cswap list") })
            else {
                root.publish({ loaded: true, installed: true, lastError: "", accounts: r.accounts, activeNumber: r.activeNumber })
                root.checkAlerts(r.accounts.find(a => a.number === r.activeNumber) || null, r.accounts)
                root.checkRecovery(r.accounts, r.activeNumber)
            }
        })
    }

    // The Refresh button: make cswap read every account now (force-refresh.py), so a
    // reset granted on claude.ai shows up without waiting for cswap's poll plan. When
    // the helper fails (e.g. cswap's internals changed) the list still runs, with
    // cswap's stored reading.
    readonly property string forceHelper: Qt.resolvedUrl("force-refresh.py").toString().replace(/^file:\/\//, "")
    property bool forcing: false
    function forceRefresh() {
        if (forcing) return
        forcing = true
        Proc.runCommand("claudeSwap.force", logic.forceRefreshCommand(forceHelper), function (out, code) {
            root.forcing = false
            if (code !== 0 && code !== logic.exitMissing)
                console.warn("claudeSwap: forced refresh failed (exit " + code + "), showing cswap's stored reading")
            root.refresh()
        }, 0, 30000)
    }

    // ---- usage alerts (owner only, so several bars do not notify twice) ----
    readonly property bool levelAlertsOn: pluginData.alerts !== false
    readonly property bool paceAlertsOn: pluginData.paceAlerts !== false

    // Name of an alert's window inside a sentence ("... of the weekly limit used").
    function windowName(a) {
        if (a.model) return I18n.trFor("claudeSwap", "%1 weekly").arg(a.model)
        return a.window === "fiveHour" ? I18n.trFor("claudeSwap", "5-hour") : I18n.trFor("claudeSwap", "weekly")
    }
    // The same window as a line heading, for notifications that list several.
    function windowTitle(a) {
        if (a.model) return I18n.trFor("claudeSwap", "%1 weekly limit").arg(a.model)
        return a.window === "fiveHour" ? I18n.trFor("claudeSwap", "5-hour limit") : I18n.trFor("claudeSwap", "Weekly limit")
    }

    // Alerts only matter when nothing will take over: with auto switch on and another
    // account under the switch line, reaching the limit just means a switch.
    function checkAlerts(acct, accounts) {
        if (!isOwner || !(levelAlertsOn || paceAlertsOn)) return
        let sent = {}
        try { sent = JSON.parse(pluginData.alertsSent || "{}") || {} } catch (e) {}
        const at = nowSec()
        const quiet = autoOn && installed && !!acct && logic.hasFallback(accounts, acct.number, threshold, at)
        const r = logic.usageAlerts(acct, sent, { levels: levelAlertsOn, pace: paceAlertsOn, quiet: quiet }, at)
        // Windows that cross a level together (weekly and Fable often do) share one
        // notification, and its tag replaces the account's previous level alert.
        const levels = r.alerts.filter(a => a.kind === "level")
        if (levels.length === 1) {
            const a = levels[0]
            Quickshell.execDetached(logic.notifyCommand(
                I18n.trFor("claudeSwap", "Claude: %1% of the %2 limit used").arg(a.pct).arg(windowName(a)),
                I18n.trFor("claudeSwap", "%1 · resets in %2").arg(label(acct)).arg(countdown(a.resetsAt, at)),
                a.level >= critPct ? "critical" : "normal",
                "claudeSwap-" + acct.number + "-levels"))
        } else if (levels.length > 1) {
            Quickshell.execDetached(logic.notifyCommand(
                I18n.trFor("claudeSwap", "Claude: %1 is close to its limits").arg(label(acct)),
                levels.map(a => I18n.trFor("claudeSwap", "%1: %2% · resets in %3")
                    .arg(windowTitle(a)).arg(a.pct).arg(countdown(a.resetsAt, at))).join("\n"),
                levels.some(a => a.level >= critPct) ? "critical" : "normal",
                "claudeSwap-" + acct.number + "-levels"))
        }
        for (const a of r.alerts.filter(a => a.kind === "pace"))
            Quickshell.execDetached(logic.notifyCommand(
                I18n.trFor("claudeSwap", "Claude: weekly usage ahead of pace"),
                I18n.trFor("claudeSwap", "%1 · %2% used, %3% expected by now. At this rate the quota runs out before the reset (%4 from now).")
                    .arg(label(acct)).arg(a.pct).arg(a.expected).arg(countdown(a.resetsAt, at)),
                "normal",
                "claudeSwap-" + acct.number + "-" + a.window + "-pace"))
        if (JSON.stringify(r.sent) !== JSON.stringify(sent) && pluginService)
            pluginService.savePluginData(pluginId, "alertsSent", JSON.stringify(r.sent))
    }

    function switchTo(target) {
        if (busy) return
        busy = true
        // cswap auto only leaves an account once it reaches the switch line, so a
        // picked account with room keeps auto switch on. One already past the line
        // would be switched away from on the next tick: then the pick wins.
        const picked = accounts.find(a => a.number === target) || null
        const keepAuto = logic.hasRoom(picked, threshold, nowSec())
        run("claudeSwap.switch", logic.switchArgs(target), function (out, code) {
            root.busy = false
            const r = logic.parseSwitch(out)
            if (!r.ok)
                ToastService.showError(I18n.trFor("claudeSwap", "Claude: failed to switch account"))
            else if (r.switched && root.autoOn && !keepAuto) {
                root.setAuto(false)
                ToastService.showInfo(I18n.trFor("claudeSwap", "Claude: now using %1. Auto switch turned off, or it would switch away from this account right away.").arg(root.label(r.to)))
            } else if (r.switched) {
                root.endExhausted()
                ToastService.showInfo(I18n.trFor("claudeSwap", "Claude: now using %1").arg(root.label(r.to)))
            }
            else
                ToastService.showWarning(I18n.trFor("claudeSwap", "Claude: did not switch — %1").arg(r.reason || I18n.trFor("claudeSwap", "no account available")))
            root.refresh()
        })
    }

    // ---- alias editing ----
    property int editingNumber: -1

    // "" when the alias can be saved, else the reason it cannot.
    function aliasProblem(n, raw) {
        const r = logic.normalizeAlias(raw)
        if (r.error === "numeric") return I18n.trFor("claudeSwap", "Cannot be only numbers")
        if (r.error === "dash") return I18n.trFor("claudeSwap", "Cannot start with '-'")
        if (r.error === "chars") return I18n.trFor("claudeSwap", "Use only letters, digits, '-', '_' and '.'")
        if (r.value && accounts.some(a => a.number !== n && a.alias === r.value))
            return I18n.trFor("claudeSwap", "Another account already uses this name")
        return ""
    }

    // Returns false when the input is invalid, so the field can stay open.
    function saveAlias(acct, raw) {
        if (aliasProblem(acct.number, raw)) return false
        editingNumber = -1
        const value = logic.normalizeAlias(raw).value
        if (value === (acct.alias || "")) return true
        run("claudeSwap.alias", logic.aliasArgs(acct.number, value), function (out, code) {
            if (code !== 0)
                ToastService.showError(I18n.trFor("claudeSwap", "Claude: could not rename the account"))
            root.refresh()
        })
        return true
    }

    // The plugin setting overrides the terminal DMS resolves (its setting, then $TERMINAL).
    function terminalPrefix() {
        const custom = String(pluginData.terminal || "").trim()
        if (custom) return custom.split(/\s+/)
        return [MuxService.terminal].concat(MuxService.getTerminalFlag(MuxService.terminal))
    }

    // `claude auth login` does not log out, so saved accounts keep valid tokens.
    function addAccount() {
        Quickshell.execDetached(logic.addAccountCommand(terminalPrefix(), [
            I18n.trFor("claudeSwap", "Sign in with the NEW account in your browser."),
            I18n.trFor("claudeSwap", "Account added."),
            I18n.trFor("claudeSwap", "Failed."),
            I18n.trFor("claudeSwap", "Press Enter to close")]))
        addRefresh.restart()
    }
    // Poll for a while so the new account shows up once the terminal flow finishes.
    Timer {
        id: addRefresh
        property int left: 0
        interval: 10000; repeat: true
        onRunningChanged: if (running) left = 12
        onTriggered: { root.refresh(); if (--left <= 0) stop() }
    }

    function setAuto(on) {
        if (pluginService) pluginService.savePluginData(pluginId, "autoSwap", on)
    }

    // ---- auto switch (owner only) ----

    // All accounts exhausted. cswap repeats the event on every tick (about every
    // 10 minutes), so it is shown once per episode.
    property bool exhausted: false
    // Set once the loop was restarted for an account that came back (see checkRecovery).
    property bool nudged: false
    function endExhausted() { exhausted = false; nudged = false }

    function onAutoEvent(line) {
        lockRetries = 0
        const ev = logic.parseAutoEvent(line)
        if (ev.kind === "switch") {
            endExhausted()
            ToastService.showInfo(I18n.trFor("claudeSwap", "Claude: limit reached, switched to %1").arg(label(ev.to)))
            refresh()
        } else if (ev.kind === "exhausted" && !exhausted) {
            exhausted = true
            const back = countdown(ev.resetsAt, nowSec())
            ToastService.showWarning(back
                ? I18n.trFor("claudeSwap", "Claude: all accounts exhausted. The first one is back in %1.").arg(back)
                : I18n.trFor("claudeSwap", "Claude: all accounts exhausted"))
        }
    }

    // While everything is exhausted, cswap auto sleeps up to 10 minutes between
    // ticks, and its rechecks of the exhausted accounts run on their own schedule,
    // so a quota that comes back early (a reset granted on claude.ai) could wait
    // for two of those. Each `cswap list` here shows cswap's latest reading: once
    // another account has room, restart the loop, whose first tick is immediate.
    function checkRecovery(list, activeNumber) {
        if (!isOwner || !exhausted) return
        const at = nowSec()
        if (logic.hasRoom(list.find(a => a.number === activeNumber) || null, threshold, at)) {
            endExhausted()   // the active account itself came back
        } else if (!nudged && autoProc.running && logic.hasFallback(list, activeNumber, threshold, at)) {
            nudged = true
            restartAuto()
        }
    }

    property bool restarting: false
    function restartAuto() {
        restarting = true
        autoProc.running = false   // onExited starts it again
    }

    function syncAuto() {
        const want = isOwner && autoOn && installed && lockRetries < maxLockRetries
        if (want && !autoProc.running)
            autoProc.running = true
        else if (!(isOwner && autoOn) && autoProc.running)
            autoProc.running = false
    }

    onAutoOnChanged: { lockRetries = 0; endExhausted(); syncAuto() }
    onInstalledChanged: syncAuto()
    onThresholdChanged: if (autoProc.running) autoProc.running = false   // the watchdog restarts it with the new threshold

    Process {
        id: autoProc
        command: logic.autoCommand(root.lockPath, root.threshold)
        stdout: SplitParser { onRead: data => root.onAutoEvent(data) }
        // Lock busy right after a reload: the previous owner's process is still exiting.
        onExited: (code, status) => {
            if (root.restarting) {
                root.restarting = false
                Qt.callLater(root.syncAuto)
            } else if (code === logic.exitLocked && root.isOwner && root.autoOn && ++root.lockRetries < root.maxLockRetries)
                lockRetry.restart()
        }
    }
    Timer { id: lockRetry; interval: 3000; onTriggered: root.syncAuto() }

    Component.onCompleted: claimOwnership()
    Component.onDestruction: {
        if (isOwner) publish({ owner: "" })
    }
    // Deferred: claiming writes globalVars, which `shared` is bound to, and doing that
    // inside its own change handler is a binding loop.
    onSharedChanged: if (!shared.owner) Qt.callLater(claimOwnership)

    Timer {
        interval: 60000; running: true; repeat: true
        onTriggered: {
            if (root.isOwner) {
                root.publish({ ownerSeen: root.now })
                root.refresh()
            } else {
                root.claimOwnership()
            }
        }
    }
    // Restart the loop if it dies; stays quiet once the lock retries are used up.
    Timer { interval: 30000; running: root.isOwner && root.autoOn; repeat: true; onTriggered: root.syncAuto() }
    Timer { interval: 30000; running: true; repeat: true; onTriggered: root.now = Math.floor(Date.now() / 1000) }

    // ---- bar ----
    // Compact: only the limit closest to running out. The logo is lit while auto switch is on.
    readonly property bool compact: (pluginData.barStyle || "compact") === "compact"
    readonly property var barWindows: {
        const u = usageOf(active)
        if (!u) return []
        if (compact) {
            const t = logic.tightest(u)
            return t ? [t] : []
        }
        return [u.fiveHour, u.sevenDay].filter(w => pct(w) >= 0)
    }

    component AutoIcon: SwapLogo {
        size: root.iconSize
        lit: root.autoOn
    }

    // DMS draws the pill background and padding; the bar content only brings icon and
    // text, sized like the other bar widgets (iconSize / textSize from PluginComponent).
    readonly property color barTextColor: Theme.widgetTextColor || Theme.surfaceText
    // Plain text color while usage is fine, warning/error colors past warnPct/critPct.
    function barColor(p) {
        return p >= 0 && logic.level(p, warnPct, critPct) !== "ok" ? color(p) : barTextColor
    }

    horizontalBarPill: Row {
        spacing: Theme.spacingXS

        AutoIcon { anchors.verticalCenter: parent.verticalCenter }

        StyledText {
            visible: !root.active
            anchors.verticalCenter: parent.verticalCenter
            text: root.installed ? "--" : I18n.trFor("claudeSwap", "install cswap")
            color: root.barTextColor
            font.pixelSize: root.textSize
        }

        Repeater {
            model: root.barWindows
            delegate: Row {
                spacing: Theme.spacingXXS
                anchors.verticalCenter: parent.verticalCenter
                UsageRing {
                    visible: !root.compact
                    percentage: root.pct(modelData)
                    ringColor: root.color(root.pct(modelData))
                    diameter: root.iconSize - Theme.spacingXS
                    anchors.verticalCenter: parent.verticalCenter
                }
                StyledText {
                    text: root.pct(modelData) + "%"
                    color: root.compact ? root.barColor(root.pct(modelData)) : root.barTextColor
                    font.pixelSize: root.textSize
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }
    }

    verticalBarPill: Column {
        spacing: Theme.spacingXS
        AutoIcon { anchors.horizontalCenter: parent.horizontalCenter }
        StyledText {
            anchors.horizontalCenter: parent.horizontalCenter
            readonly property int p: root.pct(root.compact ? logic.tightest(root.usageOf(root.active)) : root.usageOf(root.active)?.fiveHour)
            text: p >= 0 ? p + "%" : "--"
            color: root.barColor(p)
            font.pixelSize: root.textSize
        }
    }

    // ---- popout ----
    popoutWidth: 400

    component UsageBar: Item {
        id: bar
        property string name: ""
        property var win: null
        readonly property int p: root.pct(win)
        readonly property var pace: root.showPace ? logic.pace(win) : null
        width: parent ? parent.width : 0
        height: barValue.implicitHeight

        // Hovering a row with pace explains the marker.
        HoverHandler {
            id: barHover
            onHoveredChanged: if (hovered && bar.pace) paceTip.present(400); else paceTip.dismiss()
        }
        DTooltipHost {
            id: paceTip
            target: bar
            side: "top"
            text: bar.pace ? root.paceText(bar.pace) : ""
        }

        StyledText {
            id: barName
            width: Theme.fontSizeSmall * 5
            anchors.verticalCenter: parent.verticalCenter
            text: bar.name
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
        }
        Rectangle {
            id: track
            anchors.left: barName.right
            anchors.leftMargin: Theme.spacingS
            anchors.right: barValue.left
            anchors.rightMargin: Theme.spacingM
            anchors.verticalCenter: parent.verticalCenter
            height: Theme.spacingXS + Theme.spacingXXS
            radius: height / 2
            color: Theme.surfaceVariant
            Rectangle {
                width: parent.width * Math.max(0, Math.min(100, bar.p)) / 100
                height: parent.height
                radius: height / 2
                color: root.color(bar.p)
                Behavior on width { NumberAnimation { duration: Theme.shortDuration } }
            }
            // Where usage would be at an even pace (weekly windows only).
            Rectangle {
                readonly property var pace: bar.pace
                visible: pace !== null
                x: pace ? Math.max(0, Math.min(parent.width - width, parent.width * pace.expected / 100 - width / 2)) : 0
                anchors.verticalCenter: parent.verticalCenter
                width: Theme.outlineWidth * 2
                height: parent.height + Theme.spacingXS * 2
                radius: width / 2
                color: Theme.surfaceText
            }
        }
        StyledText {
            id: barValue
            width: Theme.fontSizeSmall * 9
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignRight
            wrapMode: Text.NoWrap
            readonly property string reset: bar.p < 0 ? "" : root.countdown(bar.win.resetsAt)
            text: bar.p < 0 ? "—" : reset ? bar.p + "% · " + reset : bar.p + "%"
            font.pixelSize: Theme.fontSizeSmall
            font.features: { "tnum": 1 }
            color: bar.p >= root.critPct ? Theme.error : Theme.surfaceText
        }
    }

    // One option of the threshold picker.
    component Segment: StyledRect {
        id: seg
        property string label: ""
        property bool sel: false
        signal clicked
        height: Theme.buttonHeightXXS
        radius: Theme.cornerRadius
        color: sel ? Theme.primary : segArea.containsMouse ? Theme.surfaceHover : "transparent"
        StyledText {
            anchors.centerIn: parent
            text: seg.label
            font.pixelSize: Theme.fontSizeSmall
            font.weight: seg.sel ? Font.Medium : Font.Normal
            color: seg.sel ? Theme.surface : Theme.surfaceVariantText
        }
        MouseArea {
            id: segArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: seg.clicked()
        }
    }

    popoutContent: Component {
        PopoutComponent {
            id: popout
            headerText: I18n.trFor("claudeSwap", "Claude Accounts")
            showCloseButton: true
            closePopout: function () { root.closePopout() }

            readonly property bool shown: parentPopout?.shouldBeVisible ?? false
            onShownChanged: {
                root.editingNumber = -1
                root.editingThreshold = false
                if (shown) root.refresh()
            }

            headerActions: Component {
                Row {
                    spacing: Theme.spacingXS
                    DActionButton {
                        iconName: "person_add"
                        iconColor: Theme.surfaceVariantText
                        buttonSize: Theme.buttonHeightXXS
                        tooltipText: I18n.trFor("claudeSwap", "Add account")
                        tooltipSide: "bottom"
                        enabled: root.installed
                        onClicked: { root.closePopout(); root.addAccount() }
                    }
                    DActionButton {
                        iconName: "settings"
                        iconColor: Theme.surfaceVariantText
                        buttonSize: Theme.buttonHeightXXS
                        tooltipText: I18n.trFor("claudeSwap", "Settings")
                        tooltipSide: "bottom"
                        onClicked: { root.closePopout(); PopoutService.openSettingsWithTab("plugin:claudeSwap") }
                    }
                    DActionButton {
                        iconName: "refresh"
                        iconColor: Theme.surfaceVariantText
                        buttonSize: Theme.buttonHeightXXS
                        tooltipText: I18n.trFor("claudeSwap", "Refresh")
                        tooltipSide: "bottom"
                        enabled: root.installed && !root.forcing
                        onClicked: root.forceRefresh()
                    }
                }
            }

            Column {
                width: parent.width
                spacing: Theme.spacingS

                // Switching first: it is what this plugin is for.
                StyledRect {
                    width: parent.width
                    height: autoCol.implicitHeight + Theme.spacingM * 2
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainerHigh

                    Column {
                        id: autoCol
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: Theme.spacingM
                        spacing: Theme.spacingM

                        Item {
                            width: parent.width
                            height: Math.max(autoTitle.implicitHeight, autoToggle.height)
                            SwapLogo {
                                id: autoIcon
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                size: Theme.iconSizeMedium
                                lit: root.autoOn
                            }
                            StyledText {
                                id: autoTitle
                                anchors.left: autoIcon.right
                                anchors.leftMargin: Theme.spacingM
                                anchors.right: autoToggle.left
                                anchors.rightMargin: Theme.spacingS
                                anchors.verticalCenter: parent.verticalCenter
                                text: I18n.trFor("claudeSwap", "Auto switch")
                                font.weight: Font.Medium
                            }
                            DToggle {
                                id: autoToggle
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                hideText: true
                                checked: root.autoOn
                                enabled: root.installed
                                onToggled: checked => root.setAuto(checked)
                            }
                        }

                        // The threshold stays out of the way: one line, a pencil to change it.
                        Item {
                            visible: root.autoOn
                            width: parent.width
                            height: Math.max(thresholdText.implicitHeight, thresholdEdit.height)
                            StyledText {
                                id: thresholdText
                                anchors.left: parent.left
                                anchors.right: thresholdEdit.left
                                anchors.rightMargin: Theme.spacingS
                                anchors.verticalCenter: parent.verticalCenter
                                wrapMode: Text.WordWrap
                                text: root.threshold >= 99.9
                                    ? I18n.trFor("claudeSwap", "Switches when the active account runs out")
                                    : I18n.trFor("claudeSwap", "Switches when the active account reaches %1").arg(root.thresholdLabel(root.threshold))
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                            }
                            DActionButton {
                                id: thresholdEdit
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                iconName: root.editingThreshold ? "close" : "edit"
                                iconColor: Theme.surfaceVariantText
                                buttonSize: Theme.buttonHeightXXS
                                tooltipText: root.editingThreshold ? I18n.trFor("claudeSwap", "Cancel") : I18n.trFor("claudeSwap", "Change when to switch")
                                tooltipSide: "bottom"
                                onClicked: root.editingThreshold = !root.editingThreshold
                            }
                        }

                        Column {
                            visible: root.autoOn && root.editingThreshold
                            width: parent.width
                            spacing: Theme.spacingS

                            // Suggestions; any other value goes in the field below.
                            Row {
                                id: thresholdRow
                                width: parent.width
                                spacing: 0
                                readonly property real segWidth: width / root.thresholdOptions.length
                                Repeater {
                                    model: root.thresholdOptions
                                    delegate: Segment {
                                        required property var modelData
                                        width: thresholdRow.segWidth
                                        label: modelData >= 100 ? I18n.trFor("claudeSwap", "At limit") : modelData + "%"
                                        sel: Math.abs(root.threshold - logic.clampThreshold(modelData)) < 0.01
                                        onClicked: { root.setThreshold(modelData); root.editingThreshold = false }
                                    }
                                }
                            }

                            DTextField {
                                id: thresholdField
                                width: parent.width
                                placeholderText: I18n.trFor("claudeSwap", "Other value: 50 to 100 (%)")
                                maximumLength: 5
                                showAcceptButton: true
                                acceptButtonName: I18n.trFor("claudeSwap", "Save")
                                isError: text !== "" && logic.parseThreshold(text) === null
                                onVisibleChanged: if (visible) {
                                    text = logic.isPresetThreshold(root.threshold, root.thresholdOptions) ? "" : String(root.threshold)
                                    forceActiveFocus()
                                    selectAll()
                                }
                                onAccepted: {
                                    const n = logic.parseThreshold(text)
                                    if (n === null) { shake(); return }
                                    root.setThreshold(n)
                                    root.editingThreshold = false
                                }
                                Keys.onEscapePressed: event => { root.editingThreshold = false; event.accepted = true }
                            }
                            StyledText {
                                width: parent.width
                                wrapMode: Text.WordWrap
                                text: thresholdField.isError ? I18n.trFor("claudeSwap", "Enter a number from 50 to 100.")
                                    : I18n.trFor("claudeSwap", "100 means only when the quota runs out. Enter saves, Esc cancels.")
                                font.pixelSize: Theme.fontSizeSmall
                                color: thresholdField.isError ? Theme.error : Theme.surfaceVariantText
                            }
                        }
                    }
                }

                Repeater {
                    model: root.accounts
                    delegate: StyledRect {
                        id: acct
                        required property var modelData
                        readonly property bool isActive: modelData.number === root.activeNumber
                        readonly property var u: root.usageOf(modelData)
                        readonly property bool editing: root.editingNumber === modelData.number

                        width: parent.width
                        height: cardCol.implicitHeight + Theme.spacingM * 2
                        radius: Theme.cornerRadius
                        color: isActive ? Theme.surfaceContainerHighest
                             : area.containsMouse ? Theme.surfaceHover : Theme.surfaceContainerHigh
                        border.width: isActive ? Theme.outlineWidth : 0
                        border.color: Theme.primary
                        opacity: modelData.disabled ? 0.5 : 1

                        MouseArea {
                            id: area
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: acct.isActive || root.editingNumber >= 0 ? Qt.ArrowCursor : Qt.PointingHandCursor
                            onClicked: if (!acct.isActive && root.editingNumber < 0) root.switchTo(acct.modelData.number)
                        }

                        Column {
                            id: cardCol
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingS

                            Item {
                                width: parent.width
                                height: Math.max(radio.height, accountName.implicitHeight, planChip.height, acct.editing ? aliasField.height : 0)
                                DIcon {
                                    id: radio
                                    anchors.left: parent.left
                                    anchors.verticalCenter: parent.verticalCenter
                                    name: acct.isActive ? "radio_button_checked" : "radio_button_unchecked"
                                    size: Theme.iconSizeMedium
                                    color: acct.isActive ? Theme.primary : Theme.surfaceVariantText
                                }
                                StyledText {
                                    id: accountName
                                    anchors.left: radio.right
                                    anchors.leftMargin: Theme.spacingS
                                    anchors.verticalCenter: parent.verticalCenter
                                    // Only as wide as the name, leaving room for the pace status after it.
                                    width: Math.max(0, Math.min(implicitWidth,
                                        editButton.x - Theme.spacingXS - x - (paceTag.visible ? paceTag.implicitWidth + Theme.spacingXS : 0)))
                                    visible: !acct.editing
                                    wrapMode: Text.NoWrap
                                    textFormat: Text.PlainText
                                    elide: Text.ElideMiddle
                                    text: acct.modelData.alias || acct.modelData.email || ("#" + acct.modelData.number)
                                    font.weight: acct.isActive ? Font.Medium : Font.Normal
                                }
                                // Short status in the style of claude.ai's usage page, only when ahead.
                                Row {
                                    id: paceTag
                                    readonly property var pace: root.showPace && acct.u ? logic.pace(acct.u.sevenDay) : null
                                    visible: !acct.editing && !!pace && pace.ahead
                                    anchors.left: accountName.right
                                    anchors.leftMargin: Theme.spacingS
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: Theme.spacingXXS
                                    DIcon {
                                        anchors.verticalCenter: parent.verticalCenter
                                        name: "directions_run"
                                        size: Theme.iconSizeSmall
                                        color: Theme.warning
                                    }
                                    StyledText {
                                        anchors.verticalCenter: parent.verticalCenter
                                        wrapMode: Text.NoWrap
                                        text: I18n.trFor("claudeSwap", "Ahead of pace")
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.warning
                                    }
                                }
                                DTextField {
                                    id: aliasField
                                    visible: acct.editing
                                    anchors.left: radio.right
                                    anchors.leftMargin: Theme.spacingS
                                    anchors.right: editButton.left
                                    anchors.rightMargin: Theme.spacingXS
                                    anchors.verticalCenter: parent.verticalCenter
                                    placeholderText: acct.modelData.email || ""
                                    maximumLength: 40
                                    showAcceptButton: true
                                    acceptButtonName: I18n.trFor("claudeSwap", "Save")
                                    isError: root.aliasProblem(acct.modelData.number, text) !== ""
                                    onVisibleChanged: if (visible) {
                                        text = acct.modelData.alias || ""
                                        forceActiveFocus()
                                        selectAll()
                                    }
                                    onAccepted: if (!root.saveAlias(acct.modelData, text)) shake()
                                    Keys.onEscapePressed: event => { root.editingNumber = -1; event.accepted = true }
                                }
                                DActionButton {
                                    id: editButton
                                    anchors.right: planChip.visible ? planChip.left : parent.right
                                    anchors.rightMargin: planChip.visible ? Theme.spacingS : 0
                                    anchors.verticalCenter: parent.verticalCenter
                                    // Same pattern everywhere: pencil opens, ✕ cancels, Enter or ↵ saves.
                                    iconName: acct.editing ? "close" : "edit"
                                    iconColor: Theme.surfaceVariantText
                                    buttonSize: Theme.buttonHeightXXS
                                    tooltipText: acct.editing ? I18n.trFor("claudeSwap", "Cancel") : I18n.trFor("claudeSwap", "Rename")
                                    tooltipSide: "bottom"
                                    enabled: root.installed
                                    onClicked: root.editingNumber = acct.editing ? -1 : acct.modelData.number
                                }
                                StyledRect {
                                    id: planChip
                                    visible: !!acct.modelData.plan
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: planText.implicitWidth + Theme.spacingS * 2
                                    height: planText.implicitHeight + Theme.spacingXS
                                    radius: height / 2
                                    color: Theme.surfaceVariant
                                    StyledText {
                                        id: planText
                                        anchors.centerIn: parent
                                        textFormat: Text.PlainText
                                        text: acct.modelData.plan ? acct.modelData.plan.label : ""
                                        font.pixelSize: Theme.fontSizeXSmall
                                        color: Theme.surfaceVariantText
                                    }
                                }
                            }

                            StyledText {
                                readonly property string problem: acct.editing ? root.aliasProblem(acct.modelData.number, aliasField.text) : ""
                                visible: acct.editing
                                width: parent.width
                                wrapMode: Text.WordWrap
                                text: problem || I18n.trFor("claudeSwap", "Enter saves, Esc cancels. Leave empty to show the email.")
                                font.pixelSize: Theme.fontSizeSmall
                                color: problem ? Theme.error : Theme.surfaceVariantText
                            }

                            Column {
                                width: parent.width
                                spacing: Theme.spacingXS
                                visible: !!acct.u
                                UsageBar { name: I18n.trFor("claudeSwap", "5h"); win: acct.u ? acct.u.fiveHour : null }
                                UsageBar { name: I18n.trFor("claudeSwap", "Week"); win: acct.u ? acct.u.sevenDay : null }
                                // Per-model weekly limits (e.g. Fable), only when the account reports them.
                                Repeater {
                                    model: logic.scopedWindows(acct.u)
                                    delegate: UsageBar {
                                        required property var modelData
                                        name: modelData.name
                                        win: modelData.win
                                    }
                                }
                            }
                            StyledText {
                                visible: !acct.u
                                text: root.summary(acct.modelData)
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                            }
                            // cswap rechecks an exhausted account about every 10 minutes
                            // (poll_policy.EXHAUSTED_INTERVAL_S); Refresh reads it now.
                            StyledText {
                                readonly property int age: logic.ageMinutes(acct.modelData.usageFetchedAt || acct.modelData.lastGoodFetchedAt, root.now)
                                visible: age >= 0 && logic.atLimit(acct.modelData, root.now)
                                width: parent.width
                                wrapMode: Text.WordWrap
                                text: I18n.trFor("claudeSwap", "Checked %1 min ago. Refresh to check now.").arg(Math.max(1, age))
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                            }
                        }
                    }
                }

                StyledText {
                    width: parent.width
                    visible: !root.installed || root.lastError !== "" || (root.loaded && root.accounts.length === 0)
                    wrapMode: Text.WordWrap
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                    text: !root.installed ? I18n.trFor("claudeSwap", "claude-swap is not installed. Install it with: uv tool install claude-swap (or pipx install claude-swap)")
                        : root.lastError !== "" ? root.lastError
                        : I18n.trFor("claudeSwap", "No accounts yet. Run `cswap add`, /login with the other account, then run `cswap add` again.")
                }
            }
        }
    }
}
