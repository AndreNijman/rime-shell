pragma Singleton
import QtQuick

// Which Rime identity the Shell draws. The bootc (Fedora) image keeps the
// chartreuse spark: the bar's button is src/assets/rime-logo.png and About shows
// the nerd-font glyph. Rime on NixOS draws the Origin mark
// (src/components/RimeMark.qml) instead: rime-os's nix/pkgs/rime-shell.nix
// rewrites the line below to `true` at build time and fails if it is not there.
// The property keeps the name of the mark it first switched on (the ridge):
// renaming it would break that rewrite.
// Writable only so tests can draw both.
QtObject {
    property bool ridge: false
}
