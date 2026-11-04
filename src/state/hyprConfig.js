// The decisions behind ShellState.hyprConfig and HyprlandBackend's config probe.
// Kept out of the QML so tests/hypr-config-test.js exercises the file the shell
// loads, not a copy of it.
//
// A probe answer is "ok", a problem ("no-config", "not-lua",
// "modules-missing"), or "unknown": hyprctl could not reach the instance or the
// probe produced nothing (a reload in flight, a socket hiccup). "unknown" is not
// a verdict about the config, so it changes nothing: not the state the Settings
// page shows, and not the guard that keeps a problem's critical notice to one
// per problem. Treating it as "ok" cleared that guard, so the next answer
// re-posted the same critical notice, and logged "loaded again" when nothing had
// been fixed.

// step(current, notified, reported) -> what ShellState does with an answer.
//   current   ShellState.hyprConfig before this answer
//   notified  the problem whose notice was already posted ("" for none)
// Returns { verdict, state, notified, loadedAgain, problem, notify }:
//   verdict      false for "unknown" (or anything unrecognised): record nothing
//   loadedAgain  log "loaded again": only a problem -> ok transition
//   problem      log the problem (every time it is reported)
//   notify       post the notice: only the first report of that problem
function step(current, notified, reported) {
    if (reported !== "ok" && reported !== "no-config" && reported !== "not-lua"
            && reported !== "modules-missing")
        return { verdict: false, state: current, notified: notified, loadedAgain: false,
                 problem: false, notify: false }
    if (reported === "ok")
        return { verdict: true, state: "ok", notified: "",
                 loadedAgain: current !== "ok" && current !== "unknown",
                 problem: false, notify: false }
    return { verdict: true, state: reported, notified: reported, loadedAgain: false,
             problem: true, notify: notified !== reported }
}

// The probe is one process. A request while it runs is not a restart (that
// killed the running probe, whose empty output then read as "unknown"): it is
// remembered, and one more probe runs when the current one has finished, so an
// answer always describes the config as it is after the latest request.
//   request(running, pending) -> { start, pending }
//   finished(pending)         -> { start, pending }
function request(running, pending) {
    if (running)
        return { start: false, pending: true }
    return { start: true, pending: false }
}

function finished(pending) {
    return { start: pending, pending: false }
}

// Node (tests) sees `module`; the QML engine does not, and ignores this.
if (typeof module !== "undefined" && module.exports)
    module.exports = { step: step, request: request, finished: finished }
