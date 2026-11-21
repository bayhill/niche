The Convert to WebP dashboard card: drop images on the notch, watch each one finish, read the saving.

An intentional addition: a composition of kit parts for `ConvertModule`, which is still a placeholder in the source.

## Built from

- GlassCard in the `trailing` dashboard slot (210 × 184).
- SectionHeader "Convert"; trailing is the output format at rest and a count ("2/5") while working.
- EmptyState when there is no history.
- ResultRow per file: thumbnail, file name, "1.2 MB → 264 KB" from `Format.bytes`, and the saving from `Format.saving`.
- ProgressRing in the row's leading slot while a file converts.

## Rules

- A saving is `success` and uses a real minus sign ("−78%"). A file that grew reads "+6%" in `text-secondary`: it is information, not an error.
- While dragging near the notch, the drop target (see NotchSurface) names the action: "Convert to WebP", the item count, and the ⌥ modifier that sends files to the Shelf instead.
- The live activity is `progress`: a ProgressRing leading, "3/12" trailing. Finish with `Haptics.success()`.
- Wrap finished rows in a RowButton that reveals the file; rows drag out of the notch as files.
