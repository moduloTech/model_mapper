# An undeclared `immediate_write` refuses a write made during the map

Second step of #13. 0.5.0 shipped the deprecation step: a reference `association`, or an attribute
assigned through a collection's ids writer (`part_ids`), whose assignment ActiveRecord writes to the
database at once (a has_one/has_many/HABTM of a persisted record, given a value that differs from the
current one) is still assigned when it declares no `immediate_write`, and warns that a future release
refuses it. This is that release.

The first attempt (#16, stacked on the pre-0.5.0 #15) was closed unmerged. Since then `master` extended
`immediate_write` to ids writers, made it decide at assignment on what the writer receives, and
withholds a value `immediate_write false` will refuse from the params declared after it
(`2026-10-16-immediate-write-refusal-in-loop-design.md`). This redoes #16 on that code.

## Why now

PR #7 flips `nullable` to default true. Measured on `master` b09ac99 with `nullable true` standing in
for the flipped default, an undeclared has_one `manual` and the payload `{ manual: nil, price: 'abc' }`:
the map answers 422 for `price`, and `manual.widget_id` went from 2 to nil in the database — detached,
with nothing to roll it back. Without this change, #7 makes that the default for every undeclared
reference receiving a null or `[]`.

## Decision

- Undeclared now behaves as `immediate_write false`: such a value is refused with an
  `InvalidValueError` on the param's path, nothing is assigned and nothing written.
  `immediate_write true` is unchanged and is the only way to write during the map.
- The withholding in the loop applies to every value that will be refused, undeclared included: a
  value that is about to be refused must not feed the rules of later params, whatever made it refused.
  The previous spec's "runs only for `false`" was the consequence of undeclared never refusing; it no
  longer holds.
- `immediate_write false` stays a distinct, explicit state (`explicitly_set?`), so a child mapper can
  override its parent either way. It now says what undeclared says.
- The deprecation warning (`warn_immediate_write_once`) is removed. `first_deprecation?` and
  `reset_deprecation_warnings!` stay: the explicit-null warning still uses them until #7.

## Cost

The forecast in the loop, which ran only for `immediate_write false` params, now runs for every
assigned param that is not `immediate_write true`. `immediate_write?` answers false at once for a new
record, a model without associations, a belongs_to, and a param that is neither a reference nor a
collection's ids writer; for a reference or an ids writer of a persisted record it reads the current
records once more (the cost the previous spec accepted for `false`, now paid by undeclared references
too).

## Upgrading

A reference or `*_ids` attribute that relied on writing during the map declares `immediate_write true`.
One that 0.5.0 warned about and that still declares nothing now answers 422 on the change instead of
writing it.

## Not changed

- What counts as a write (`immediate_write?`) and where the refusal is decided (at assignment, after
  `before_assignation`).
- A sub-mapper association (`association … with`) stages its records in memory and is never governed.
