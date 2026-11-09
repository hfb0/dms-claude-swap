import QtQuick
import qs.Common
import qs.Modules.Plugins

PluginSettings {
    pluginId: "claudeSwap"

    // Switching first: it is what this plugin is for.
    ToggleSetting {
        settingKey: "autoSwap"
        label: I18n.trFor("claudeSwap", "Auto switch")
        description: I18n.trFor("claudeSwap", "Runs `cswap auto` while the shell is running")
        defaultValue: false
    }

    SliderSetting {
        settingKey: "threshold"
        label: I18n.trFor("claudeSwap", "Auto switch threshold")
        description: I18n.trFor("claudeSwap", "Switch accounts when the active account's quota reaches this point. 100% means only when it runs out.")
        minimum: 50
        maximum: 100
        unit: "%"
        defaultValue: 100
    }

    ToggleSetting {
        settingKey: "alerts"
        label: I18n.trFor("claudeSwap", "Usage alerts")
        description: I18n.trFor("claudeSwap", "Notify when the active account reaches 75%, 85% and 95% of its 5-hour or weekly limit")
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "paceAlerts"
        label: I18n.trFor("claudeSwap", "Pace alerts")
        description: I18n.trFor("claudeSwap", "Notify when weekly usage is well ahead of pace and would run out before the reset")
        defaultValue: true
    }

    SelectionSetting {
        settingKey: "barStyle"
        label: I18n.trFor("claudeSwap", "Bar style")
        description: I18n.trFor("claudeSwap", "Compact shows only the limit closest to running out. The icon is lit while auto switch is on.")
        options: [
            {label: I18n.trFor("claudeSwap", "Compact"), value: "compact"},
            {label: I18n.trFor("claudeSwap", "Full (5-hour and weekly)"), value: "full"}
        ]
        defaultValue: "compact"
    }

    StringSetting {
        settingKey: "terminal"
        label: I18n.trFor("claudeSwap", "Terminal")
        description: I18n.trFor("claudeSwap", "Leave empty to use the DMS terminal. Otherwise the command that runs a program in your terminal, e.g. `kitty -e`.")
        placeholder: "kitty -e"
        defaultValue: ""
    }
}
