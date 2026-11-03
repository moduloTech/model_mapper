# Plan — an undeclared `immediate_write` refuses

Spec: `docs/superpowers/specs/2026-11-03-immediate-write-refused-by-default-design.md`.

1. `lib/model_mapper.rb`:
   - `guard_immediate_write!`: refuse whenever the value is not `immediate_write true` and
     `immediate_write?` holds; the warning branch goes.
   - the withholding in `map_to_model`'s loop: `immediate_write_value != true` instead of `== false`.
   - remove `warn_immediate_write_once`.
2. `lib/model_mapper/param_config.rb`: the `immediate_write` doc.
3. Tests, `test/model_mapper/test_immediate_write.rb`:
   - every undeclared "writes and warns" case (has_many replace, has_one replace, has_one attach on a
     parent with no child, ids writer replace, nullable clear of a many reference) becomes "refused,
     nothing written, no warning";
   - the warning-machinery tests (once per mapper/param, two mappers, naming the path, resets,
     independence from the explicit-null warning) go with the warning; one test pins that the
     explicit-null warning still fires and is still reset by both resets;
   - `test_undeclared_and_true_writes_stay_readable_by_a_later_map_if` splits: `true` stays readable,
     undeclared is withheld (a later `map_if` reads nil);
   - `test_strict_loading_parent_is_read_without_violation`: keep its intent (no violation from the
     check) under the new default.
   - `test/model_mapper/test_explicit_null.rb`: the `nullable true` empty-list clear of a many
     reference declares `immediate_write true`, and a case pins that undeclared refuses it.
4. README: the `immediate_write` table, the "A future release refuses by default" sentence, the
   `nullable` section's ⚠️ note, the option table row, and the "A reference written during the map"
   deprecation section.
5. CHANGELOG `## Unreleased`: a `### Changed` breaking entry with the upgrade note.
