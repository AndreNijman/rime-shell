import QtQuick
import Quickshell
import Quickshell.Io
import "./src/components"
import "./src/services"
import "./src/nexus"
import "./src/popups"
import "./src"
import "./src/services/system"

// Harness for tests/run-power-profile-service-test.sh: holds one reference on
// PowerProfileService (as the dashboard's power panel does while it is shown)
// and answers the runner over IPC (or none: PPS_TEST_NO_REF=1). Staged into the repository root by the
// runner so the relative imports resolve.
ShellRoot {
    // PPS_TEST_NO_REF=1: nothing holds the service (the Settings page off
    // screen), and a set arrives only over IPC, as through the IPC hook.
    ServiceRef { service: PowerProfileService; active: Quickshell.env("PPS_TEST_NO_REF") !== "1" }

    IpcHandler {
        target: "pps"
        function backend(): string { return PowerProfileService.backend }
        function current(): string { return PowerProfileService.current }
        function holds(): string { return JSON.stringify(PowerProfileService.holds) }
        function set(id: string): string { PowerProfileService.setProfile(id); return "ok" }
    }
}
