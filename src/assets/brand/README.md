# Rime brand masters (copies)

`rime-ridge-symbol.svg` and `rime-ridge-symbol-small.svg` are byte-for-byte copies of the masters in
rime-os `files/branding/ridge/src/` (the layered ridge, reconstructed from the brand pack; rime-os
`docs/branding.md` has the provenance). The shell does not load them: `src/components/RimeMark.qml` draws
the same four polygons as vectors, and `tests/run-rime-mark-test.sh` fails if its point lists and these
files disagree. Change the mark in rime-os first, copy both files here, then update RimeMark.qml.
