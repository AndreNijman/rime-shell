import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// For tests/run-settings-app-test.sh: lists the compositor's toplevels (the
// wlr-foreign-toplevel-management protocol, which labwc serves) over IPC, as
// one "appId|title" line each. The host has no lswt/wlrctl; this is the reader.
ShellRoot {
    IpcHandler {
        target: "toplevels"
        function list(): string {
            const out = []
            for (const t of ToplevelManager.toplevels.values)
                out.push(t.appId + "|" + t.title)
            return out.join("\n")
        }
    }
}
