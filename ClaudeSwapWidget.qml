// Claude Code accounts via claude-swap (cswap): per-account usage, one-click
// switching, and an optional `cswap auto` loop owned by the shell.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root
    pluginId: "claudeSwap"

    ClaudeSwapLogic { id: logic }

    readonly property int warnPct: 70
    readonly property int critPct: 90

    readonly property bool autoOn: pluginData.autoSwap === true
    // cswap accepts 50–99.9 and rejects 100, so 99.9 stands in for "when exhausted".
    readonly property real threshold: parseFloat(pluginData.threshold) || 99.9
    readonly property var thresholdOptions: [80, 90, 95, 99.9]
    function thresholdLabel(t) { return t >= 99.9 ? "100%" : t + "%" }
    function setThreshold(t) {
        if (pluginService) pluginService.savePluginData(pluginId, "threshold", String(t))
    }

    // One widget instance exists per bar/screen; this lock keeps a single `cswap auto` running.
    readonly property string lockPath: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/dms-claude-swap-auto.lock"

    property var accounts: []
    property int activeNumber: -1
    property bool installed: true
    property bool loaded: false
    property bool busy: false
    property string lastError: ""
    property int now: Math.floor(Date.now() / 1000)

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

    // ---- cswap ----
    function run(id, args, cb) {
        Proc.runCommand(id, logic.runCommand(args), cb, 0, 60000)
    }

    function refresh() {
        run("claudeSwap.list", ["list", "--json"], function (out, code) {
            root.loaded = true
            root.installed = code !== logic.exitMissing
            if (!root.installed) return
            const r = logic.parseList(out)
            if (r.error === "cswap") { root.lastError = r.message || I18n.trFor("claudeSwap", "cswap error"); return }
            if (r.error) { root.lastError = I18n.trFor("claudeSwap", "unexpected output from cswap list"); return }
            root.accounts = r.accounts
            root.activeNumber = r.activeNumber
            root.lastError = ""
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

    // `claude auth login` does not log out, so saved accounts keep valid tokens.
    function addAccount() {
        Quickshell.execDetached(logic.addAccountCommand(pluginData.terminal, [
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

    // ---- auto switch ----
    function onAutoEvent(line) {
        const ev = logic.parseAutoEvent(line)
        if (ev.kind === "switch") {
            ToastService.showInfo(I18n.trFor("claudeSwap", "Claude: quota limit reached, switched to %1").arg(label(ev.to)))
            refresh()
        } else if (ev.kind === "exhausted") {
            ToastService.showWarning(I18n.trFor("claudeSwap", "Claude: all accounts exhausted"))
        }
    }

    function syncAuto() {
        if (autoOn && installed && !autoProc.running)
            autoProc.running = true
        else if (!autoOn && autoProc.running)
            autoProc.running = false
    }

    onAutoOnChanged: syncAuto()
    onThresholdChanged: if (autoProc.running) autoProc.running = false   // the retry timer restarts it with the new threshold

    Process {
        id: autoProc
        command: logic.autoCommand(root.lockPath, root.threshold)
        stdout: SplitParser { onRead: data => root.onAutoEvent(data) }
        // Lock busy: another instance, or the previous one still exiting after a reload.
        onExited: (code, status) => { if (code === logic.exitLocked && root.autoOn) lockRetry.restart() }
    }
    Timer { id: lockRetry; interval: 3000; onTriggered: root.syncAuto() }

    Component.onCompleted: { refresh(); syncAuto() }
    Timer { interval: 60000; running: true; repeat: true; onTriggered: root.refresh() }
    // Restart the loop if the instance holding the lock goes away or the process dies.
    Timer { interval: 30000; running: root.autoOn; repeat: true; triggeredOnStart: true; onTriggered: root.syncAuto() }
    Timer { interval: 30000; running: true; repeat: true; onTriggered: root.now = Math.floor(Date.now() / 1000) }

    // ---- bar ----
    component AutoIcon: DankIcon {
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
                        spacing: 5
                        Layout.alignment: Qt.AlignVCenter
                        UsageRing {
                            percentage: root.pct(modelData)
                            ringColor: root.color(root.pct(modelData))
                            diameter: Math.max(12, Math.min(pill.height - 9, 18))
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
    readonly property int cardHeight: 92
    popoutWidth: 400
    popoutHeight: 150 + (autoOn ? 104 : 64) + Math.max(1, accounts.length) * (cardHeight + Theme.spacingS)

    component UsageBar: Item {
        id: bar
        property string name: ""
        property var win: null
        readonly property int p: root.pct(win)
        width: parent ? parent.width : 0
        height: 18

        StyledText {
            id: barName
            width: 64
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
            height: 6
            radius: 3
            color: Theme.surfaceVariant
            Rectangle {
                width: parent.width * Math.max(0, Math.min(100, bar.p)) / 100
                height: parent.height
                radius: 3
                color: root.color(bar.p)
                Behavior on width { NumberAnimation { duration: Theme.shortDuration } }
            }
        }
        StyledText {
            id: barValue
            width: 112
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignRight
            wrapMode: Text.NoWrap
            text: bar.p < 0 ? "—" : bar.p + "% · " + root.countdown(bar.win.resetsAt)
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
                    DankActionButton {
                        iconName: "person_add"
                        iconColor: Theme.surfaceVariantText
                        buttonSize: 28
                        tooltipText: I18n.trFor("claudeSwap", "Add account")
                        tooltipSide: "bottom"
                        enabled: root.installed
                        onClicked: { root.closePopout(); root.addAccount() }
                    }
                    DankActionButton {
                        iconName: "bolt"
                        iconColor: Theme.surfaceVariantText
                        buttonSize: 28
                        tooltipText: I18n.trFor("claudeSwap", "Switch to the account with the most quota left")
                        tooltipSide: "bottom"
                        enabled: root.installed && !root.busy && root.accounts.length > 1
                        onClicked: root.switchTo("best")
                    }
                    DankActionButton {
                        iconName: "refresh"
                        iconColor: Theme.surfaceVariantText
                        buttonSize: 28
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
                        height: root.cardHeight
                        radius: Theme.cornerRadius
                        color: isActive ? Theme.surfaceContainerHighest
                             : area.containsMouse ? Theme.surfaceHover : Theme.surfaceContainerHigh
                        border.width: isActive ? 1 : 0
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
                            anchors.fill: parent
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingS

                            Item {
                                width: parent.width
                                height: 22
                                DankIcon {
                                    id: radio
                                    anchors.left: parent.left
                                    anchors.verticalCenter: parent.verticalCenter
                                    name: acct.isActive ? "radio_button_checked" : "radio_button_unchecked"
                                    size: Theme.iconSize - 6
                                    color: acct.isActive ? Theme.primary : Theme.surfaceVariantText
                                }
                                StyledText {
                                    anchors.left: radio.right
                                    anchors.leftMargin: Theme.spacingS
                                    anchors.right: planChip.left
                                    anchors.rightMargin: Theme.spacingS
                                    anchors.verticalCenter: parent.verticalCenter
                                    wrapMode: Text.NoWrap
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
                                    height: 20
                                    radius: 10
                                    color: Theme.surfaceVariant
                                    StyledText {
                                        id: planText
                                        anchors.centerIn: parent
                                        text: acct.modelData.plan ? acct.modelData.plan.label : ""
                                        font.pixelSize: Theme.fontSizeSmall - 1
                                        color: Theme.surfaceVariantText
                                    }
                                }
                            }

                            Column {
                                width: parent.width
                                spacing: 4
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
                            DankIcon {
                                id: autoIcon
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                name: root.autoOn ? "sync" : "sync_disabled"
                                size: Theme.iconSize - 4
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
                            DankToggle {
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
                                    height: 30
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
