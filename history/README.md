# Version history (scripts and config only)

`vX.Y/` holds the module scripts, `module.prop`, `system.prop`, `sepolicy.rule` and our own permission XMLs from every released zip, plus `FILES.txt`, the zip's full file list (including the firmware files it shipped, which are not stored here).

To bring back any older behaviour, diff against the current `module/`:

    diff -ru history/v0.23 module

What changed in each version and why: docs/CHANGELOG.md. Every current modification and how to undo it: docs/REVERTING.md.
