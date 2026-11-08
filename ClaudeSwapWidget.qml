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

    readonly property int warnPct: 70
    readonly property int critPct: 90

    readonly property bool autoOn: pluginData.autoSwap === true
    // cswap accepts 50–99.9 and rejects 100, so 99.9 stands in for "when exhausted".
    readonly property real threshold: logic.clampThreshold(pluginData.threshold)
    readonly property var thresholdOptions: [80, 90, 95, 99.9]
    function thresholdLabel(t) { return t >= 99.9 ? "100%" : t + "%" }
    function setThreshold(t) {
        if (pluginService) pluginService.savePluginData(pluginId, "threshold", String(t))
    }

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

    function label(a) { return logic.label(a) }
    function usageOf(a) { return logic.usageOf(a) }
    function pct(w) { return logic.pct(w) }
    function color(p) {
        const l = logic.level(p, warnPct, critPct)
        return l === "crit" ? Theme.error : l === "warn" ? Theme.warning : Theme.primary
    }
    function countdown(iso) {
        const c = logic.countdown(iso, now)
        return c === null ? I18n.trFor("claudeSwap", "now") : c
    }
    function summary(a) {
        const u = usageOf(a)
        if (!u) return a.usageStatus && a.usageStatus !== "ok" ? I18n.trFor("claudeSwap", "no reading (%1)").arg(a.usageStatus) : I18n.trFor("claudeSwap", "no reading")
        const parts = []
        const f = pct(u.fiveHour), w = pct(u.sevenDay)
        if (f >= 0) parts.push(I18n.trFor("claudeSwap", "5h %1% · resets in %2").arg(f).arg(countdown(u.fiveHour.resetsAt)))
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
            else
                root.publish({ loaded: true, installed: true, lastError: "", accounts: r.accounts, activeNumber: r.activeNumber })
        })
    }

    function switchTo(target) {
        if (busy) return
        busy = true
        run("claudeSwap.switch", logic.switchArgs(target), function (out, code) {
            root.busy = false
            const r = logic.parseSwitch(out)
            if (!r.ok)
                ToastService.showError(I18n.trFor("claudeSwap", "Claude: failed to switch account"))
            else if (r.switched)
                ToastService.showInfo(I18n.trFor("claudeSwap", "Claude: now on %1").arg(root.label(r.to)))
            else
                ToastService.showWarning(I18n.trFor("claudeSwap", "Claude: did not switch — %1").arg(r.reason || I18n.trFor("claudeSwap", "no account available")))
            root.refresh()
        })
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
    function onAutoEvent(line) {
        lockRetries = 0
        const ev = logic.parseAutoEvent(line)
        if (ev.kind === "switch") {
            ToastService.showInfo(I18n.trFor("claudeSwap", "Claude: quota limit reached, switched to %1").arg(label(ev.to)))
            refresh()
        } else if (ev.kind === "exhausted") {
            ToastService.showWarning(I18n.trFor("claudeSwap", "Claude: all accounts exhausted"))
        }
    }

    function syncAuto() {
        const want = isOwner && autoOn && installed && lockRetries < maxLockRetries
        if (want && !autoProc.running)
            autoProc.running = true
        else if (!(isOwner && autoOn) && autoProc.running)
            autoProc.running = false
    }

    onAutoOnChanged: { lockRetries = 0; syncAuto() }
    onInstalledChanged: syncAuto()
    onThresholdChanged: if (autoProc.running) autoProc.running = false   // the watchdog restarts it with the new threshold

    Process {
        id: autoProc
        command: logic.autoCommand(root.lockPath, root.threshold)
        stdout: SplitParser { onRead: data => root.onAutoEvent(data) }
        // Lock busy right after a reload: the previous owner's process is still exiting.
        onExited: (code, status) => {
            if (code === logic.exitLocked && root.isOwner && root.autoOn && ++root.lockRetries < root.maxLockRetries)
                lockRetry.restart()
        }
    }
    Timer { id: lockRetry; interval: 3000; onTriggered: root.syncAuto() }

    Component.onCompleted: claimOwnership()
    Component.onDestruction: {
        if (isOwner) publish({ owner: "" })
    }
    onSharedChanged: if (!shared.owner) claimOwnership()

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
    component AutoIcon: DIcon {
        name: root.autoOn ? "sync" : "sync_disabled"
        size: root.iconSize
        color: root.autoOn ? Theme.primary : Theme.surfaceVariantText
    }

    horizontalBarPill: Component {
        StyledRect {
            id: pill
            implicitWidth: row.implicitWidth + Theme.spacingM * 2
            height: parent.widgetThickness
            radius: Theme.cornerRadius
            color: Theme.surfaceContainerHigh

            RowLayout {
                id: row
                anchors.centerIn: parent
                spacing: Theme.spacingS

                AutoIcon { Layout.alignment: Qt.AlignVCenter }

                StyledText {
                    visible: !root.active
                    text: root.installed ? "✳ --" : "✳ " + I18n.trFor("claudeSwap", "install cswap")
                    color: Theme.surfaceTextMedium
                    font.pixelSize: Theme.fontSizeMedium
                }

                Repeater {
                    model: {
                        const u = root.usageOf(root.active)
                        if (!u) return []
                        return [u.fiveHour, u.sevenDay].filter(w => root.pct(w) >= 0)
                    }
                    delegate: Row {
                        spacing: Theme.spacingXS
                        Layout.alignment: Qt.AlignVCenter
                        UsageRing {
                            percentage: root.pct(modelData)
                            ringColor: root.color(root.pct(modelData))
                            diameter: Math.max(Theme.iconSizeSmall - Theme.spacingXS, Math.min(Theme.iconSizeSmall + Theme.spacingXXS, pill.height - Theme.spacingS))
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        StyledText {
                            text: root.pct(modelData) + "%"
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeMedium
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                }
            }
        }
    }

    verticalBarPill: Component {
        StyledRect {
            width: parent.widgetThickness
            implicitHeight: col.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Theme.surfaceContainerHigh

            Column {
                id: col
                anchors.centerIn: parent
                spacing: Theme.spacingS
                AutoIcon { anchors.horizontalCenter: parent.horizontalCenter }
                StyledText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    readonly property int p: root.pct(root.usageOf(root.active)?.fiveHour)
                    text: p >= 0 ? p + "%" : "--"
                    color: p >= 0 ? root.color(p) : Theme.surfaceTextMedium
                    font.pixelSize: Theme.fontSizeSmall
                }
            }
        }
    }

    // ---- popout ----
    popoutWidth: 400

    component UsageBar: Item {
        id: bar
        property string name: ""
        property var win: null
        readonly property int p: root.pct(win)
        width: parent ? parent.width : 0
        height: barValue.implicitHeight

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

    popoutContent: Component {
        PopoutComponent {
            id: popout
            headerText: I18n.trFor("claudeSwap", "Claude Accounts")
            showCloseButton: true
            closePopout: function () { root.closePopout() }

            readonly property bool shown: parentPopout?.shouldBeVisible ?? false
            onShownChanged: if (shown) root.refresh()

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
                        iconName: "bolt"
                        iconColor: Theme.surfaceVariantText
                        buttonSize: Theme.buttonHeightXXS
                        tooltipText: I18n.trFor("claudeSwap", "Switch to the account with the most quota left")
                        tooltipSide: "bottom"
                        enabled: root.installed && !root.busy && root.accounts.length > 1
                        onClicked: root.switchTo("best")
                    }
                    DActionButton {
                        iconName: "refresh"
                        iconColor: Theme.surfaceVariantText
                        buttonSize: Theme.buttonHeightXXS
                        tooltipText: I18n.trFor("claudeSwap", "Refresh")
                        tooltipSide: "bottom"
                        onClicked: root.refresh()
                    }
                }
            }

            Column {
                width: parent.width
                spacing: Theme.spacingS

                Repeater {
                    model: root.accounts
                    delegate: StyledRect {
                        id: acct
                        required property var modelData
                        readonly property bool isActive: modelData.number === root.activeNumber
                        readonly property var u: root.usageOf(modelData)

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
                            cursorShape: acct.isActive ? Qt.ArrowCursor : Qt.PointingHandCursor
                            onClicked: if (!acct.isActive) root.switchTo(acct.modelData.number)
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
                                height: Math.max(radio.height, accountName.implicitHeight, planChip.height)
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
                                    anchors.right: planChip.left
                                    anchors.rightMargin: Theme.spacingS
                                    anchors.verticalCenter: parent.verticalCenter
                                    wrapMode: Text.NoWrap
                                    textFormat: Text.PlainText
                                    elide: Text.ElideMiddle
                                    text: acct.modelData.alias || acct.modelData.email || ("#" + acct.modelData.number)
                                    font.weight: acct.isActive ? Font.Medium : Font.Normal
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

                            Column {
                                width: parent.width
                                spacing: Theme.spacingXS
                                visible: !!acct.u
                                UsageBar { name: I18n.trFor("claudeSwap", "5h"); win: acct.u ? acct.u.fiveHour : null }
                                UsageBar { name: I18n.trFor("claudeSwap", "Week"); win: acct.u ? acct.u.sevenDay : null }
                            }
                            StyledText {
                                visible: !acct.u
                                text: root.summary(acct.modelData)
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
                    text: !root.installed ? I18n.trFor("claudeSwap", "claude-swap is not installed. Run: uv tool install claude-swap")
                        : root.lastError !== "" ? root.lastError
                        : I18n.trFor("claudeSwap", "No accounts yet. Run `cswap add`, /login with the other account, then run `cswap add` again.")
                }

                StyledRect {
                    width: parent.width
                    height: autoCol.implicitHeight + Theme.spacingM * 2
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainerHigh

                    Column {
                        id: autoCol
                        anchors.fill: parent
                        anchors.margins: Theme.spacingM
                        spacing: Theme.spacingM

                        Item {
                            width: parent.width
                            height: Math.max(autoTitle.implicitHeight, autoToggle.height)
                            DIcon {
                                id: autoIcon
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                name: root.autoOn ? "sync" : "sync_disabled"
                                size: Theme.iconSizeMedium
                                color: root.autoOn ? Theme.primary : Theme.surfaceVariantText
                            }
                            StyledText {
                                id: autoTitle
                                anchors.left: autoIcon.right
                                anchors.leftMargin: Theme.spacingM
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

                        Row {
                            visible: root.autoOn
                            width: parent.width
                            spacing: 0
                            Repeater {
                                model: root.thresholdOptions
                                delegate: StyledRect {
                                    required property var modelData
                                    required property int index
                                    readonly property bool sel: Math.abs(root.threshold - modelData) < 0.01
                                    width: parent.width / root.thresholdOptions.length
                                    height: Theme.buttonHeightXXS
                                    radius: Theme.cornerRadius
                                    color: sel ? Theme.primary : segArea.containsMouse ? Theme.surfaceHover : "transparent"
                                    StyledText {
                                        anchors.centerIn: parent
                                        text: modelData >= 99.9 ? I18n.trFor("claudeSwap", "At limit") : root.thresholdLabel(modelData)
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.weight: parent.sel ? Font.Medium : Font.Normal
                                        color: parent.sel ? Theme.surface : Theme.surfaceVariantText
                                    }
                                    MouseArea {
                                        id: segArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.setThreshold(modelData)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
