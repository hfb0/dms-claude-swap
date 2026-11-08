import QtQuick
import qs.Common
import qs.Modules.Plugins

PluginSettings {
    pluginId: "claudeSwap"

    SelectionSetting {
        settingKey: "threshold"
        label: I18n.trFor("claudeSwap", "Auto switch threshold")
        description: I18n.trFor("claudeSwap", "Switch accounts when the active account's quota reaches this point")
        options: [
            {label: "80%", value: "80"},
            {label: "90%", value: "90"},
            {label: "95%", value: "95"},
            {label: I18n.trFor("claudeSwap", "100% (when exhausted)"), value: "99.9"}
        ]
        defaultValue: "99.9"
    }

    ToggleSetting {
        settingKey: "autoSwap"
        label: I18n.trFor("claudeSwap", "Auto switch")
        description: I18n.trFor("claudeSwap", "Runs `cswap auto` while the shell is running")
        defaultValue: false
    }

    StringSetting {
        settingKey: "terminal"
        label: I18n.trFor("claudeSwap", "Terminal")
        description: I18n.trFor("claudeSwap", "Leave empty to use the DMS terminal. Otherwise the command that runs a program in your terminal, e.g. `kitty -e`.")
        placeholder: "kitty -e"
        defaultValue: ""
    }
}
