# Rime brand masters (copies)

`rime-origin-symbol.svg` and `rime-origin-symbol-small.svg` are byte-for-byte copies of the masters in
rime-os `files/branding/ridge/src/` (the Origin mark: five circles tangent at one point, filled even-odd
into coat, ring and core; rime-os `docs/branding.md` has the rationale). The shell does not load them:
`src/components/RimeMark.qml` draws the same five circles as vectors, and `tests/run-rime-mark-test.sh`
fails if its origin and radii and these files disagree. Change the mark in rime-os first, copy both files
here, then update RimeMark.qml.
