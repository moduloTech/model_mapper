# frozen_string_literal: true

require 'test_helper'

# A singular association (`belongs_to` / `has_one`) mapped through a sub-mapper resolves its record in
# order: the identifier sent in the payload (upsert), else the record already attached, else a new one.

# The owner of a belongs_to: the widget holds the category's foreign key.
class AttachedBtWidget < ActiveRecord::Base

  self.table_name = 'widgets'
  belongs_to :category, optional: true
  accepts_nested_attributes_for :category

end

class AttachedManualMapper

  include ModelMapper

  map_model do
    attribute(:title) { required true }
  end

end

class AttachedPartMapper

  include ModelMapper

  map_model { attribute :name }

end

class AttachedPartsMapper

  include ModelMapper

  map_model do
    association :parts_attributes, many: true do
      from :parts
      with AttachedPartMapper
    end
  end

end

# belongs_to through a sub-mapper alone (no `allowing`): the payload can never name a record.
class AttachedBtCategoryMapper

  include ModelMapper

  map_model do
    attribute(:name) { required true }
  end

end

class AttachedBtMapper

  include ModelMapper

  map_model do
    association :category_attributes do
      from :category
      with AttachedBtCategoryMapper
    end
  end

end

# Same association under an upsert: an identifier, when sent, is looked up in `allowing`.
class AttachedBtUpsertMapper

  include ModelMapper

  map_model do
    association :category_attributes do
      from :category
      with AttachedBtCategoryMapper
      allowing -> { Category.all }
    end
  end

end

# has_one through a sub-mapper, with and without `allowing`.
class AttachedHasOneMapper

  include ModelMapper

  map_model do
    association :manual_attributes do
      from :manual
      with AttachedManualMapper
    end
  end

end

class AttachedHasOneUpsertMapper

  include ModelMapper

  map_model do
    association :manual_attributes do
      from :manual
      with AttachedManualMapper
      allowing -> { Manual.all }
    end
  end

end

# Parents that do not autosave the association: their save would drop an edit of a persisted record.
class AttachedPlainBtWidget < ActiveRecord::Base

  self.table_name = 'widgets'
  belongs_to :category, optional: true

end

class AttachedPlainHasOneWidget < ActiveRecord::Base

  self.table_name = 'widgets'
  has_one :manual, foreign_key: :widget_id

end

# A parent that can destroy its category through nested attributes.
class AttachedDestroyBtWidget < ActiveRecord::Base

  self.table_name = 'widgets'
  belongs_to :category, optional: true
  accepts_nested_attributes_for :category, allow_destroy: true

end

class AttachedPlainBtMapper

  include ModelMapper

  map_model do
    association :category_attributes do
      from :category
      with AttachedBtCategoryMapper
    end
  end

end

class AttachedPlainHasOneMapper

  include ModelMapper

  map_model do
    association :manual_attributes do
      from :manual
      with AttachedManualMapper
    end
  end

end

# An upsert narrowed to enabled categories.
class AttachedBtScopedUpsertMapper

  include ModelMapper

  map_model do
    association :category_attributes do
      from :category
      with AttachedBtCategoryMapper
      allowing -> { Category.where(enabled: true) }
    end
  end

end

# The owner's foreign key is mapped from the payload before the association.
class AttachedBtWithForeignKeyMapper

  include ModelMapper

  map_model do
    attribute(:category_id) { type :integer }
    association :category_attributes do
      from :category
      with AttachedBtCategoryMapper
    end
  end

end

ActiveRecord::Migration.suppress_messages do
  ActiveRecord::Schema.define do
    create_table :attached_notes, force: true do |t|
      t.integer :owner_id
      t.string :owner_type
    end
  end
end

# A polymorphic owner: the attached record may be of any class, whatever `allowing` scopes.
class AttachedNote < ActiveRecord::Base

  belongs_to :owner, polymorphic: true, optional: true
  accepts_nested_attributes_for :owner

end

class AttachedOwnerMapper

  include ModelMapper

  map_model { attribute :name }

end

class AttachedPolyUpsertMapper

  include ModelMapper

  map_model do
    association :owner_attributes do
      from :owner
      with AttachedOwnerMapper
      allowing -> { Part.all }
    end
  end

end

# A sub-mapper reading the section's `id` as data: a partner's own reference.
class AttachedExternalPartMapper

  include ModelMapper

  map_model do
    attribute(:name) { from :id }
  end

end

class AttachedExternalPartsMapper

  include ModelMapper

  map_model do
    association :parts_attributes, many: true do
      from :parts
      with AttachedExternalPartMapper
    end
  end

end

# A primary key not named `id`.
ActiveRecord::Migration.suppress_messages do
  ActiveRecord::Schema.define do
    create_table :attached_legacy_owners, primary_key: :legacy_id, force: true do |t|
      t.string :name
    end
    create_table :attached_legacy_widgets, force: true do |t|
      t.integer :legacy_owner_id
    end
  end
end

class AttachedLegacyOwner < ActiveRecord::Base

  self.primary_key = 'legacy_id'

end

class AttachedLegacyWidget < ActiveRecord::Base

  belongs_to :legacy_owner, class_name: 'AttachedLegacyOwner', optional: true
  accepts_nested_attributes_for :legacy_owner

end

class AttachedLegacyMapper

  include ModelMapper

  map_model do
    association :legacy_owner_attributes do
      from :legacy_owner
      with AttachedOwnerMapper
    end
  end

end

class TestSingularAttached < Minitest::Test

  # --- belongs_to -------------------------------------------------------------------------------------

  def test_belongs_to_updates_the_attached_record
    [AttachedBtMapper, AttachedBtUpsertMapper].each do |mapper_klass|
      category = Category.create!(name: 'orig')
      widget   = AttachedBtWidget.create!(name: 'w', category:)

      assert_no_new_row(Category) do
        mapper = mapper_klass.map_to_model(widget, { category: { name: 'renamed' } })

        assert_predicate mapper, :valid?, mapper.errors.inspect
        widget.save!
      end
      assert_equal category.id, widget.reload.category_id, mapper_klass.name
      assert_equal 'renamed', category.reload.name, mapper_klass.name
    end
  end

  def test_belongs_to_update_writes_nothing_during_the_map
    category = Category.create!(name: 'orig')
    widget   = AttachedBtWidget.create!(name: 'w', category:)
    AttachedBtMapper.map_to_model(widget, { category: { name: 'renamed' } })

    assert_equal 'orig', category.reload.name
  end

  def test_belongs_to_builds_a_record_when_none_is_attached
    [AttachedBtMapper, AttachedBtUpsertMapper].each do |mapper_klass|
      widget = AttachedBtWidget.create!(name: 'w')

      mapper = mapper_klass.map_to_model(widget, { category: { name: 'fresh' } })

      assert_predicate mapper, :valid?, mapper.errors.inspect
      assert_difference_of_one(Category) { widget.save! }
      assert_equal 'fresh', widget.reload.category.name, mapper_klass.name
    end
  end

  def test_belongs_to_with_an_identifier_keeps_the_upsert
    old_category = Category.create!(name: 'old')
    category     = Category.create!(name: 'orig')
    widget       = AttachedBtWidget.create!(name: 'w', category: old_category)

    mapper = AttachedBtUpsertMapper.map_to_model(widget, { category: { id: category.id, name: 'renamed' } })

    assert_predicate mapper, :valid?, mapper.errors.inspect
    widget.save!
    assert_equal category.id, widget.reload.category_id
    assert_equal 'renamed', category.reload.name
    assert_equal 'old', old_category.reload.name
  end

  def test_belongs_to_attached_record_errors_keep_their_path
    widget = AttachedBtWidget.create!(name: 'w', category: Category.create!(name: 'orig'))

    mapper = AttachedBtMapper.map_to_model(widget, { category: {} })

    refute_predicate mapper, :valid?
    assert_includes mapper.errors.keys, 'category.name'
  end

  # A record attached earlier and never saved is the one the payload completes: no second one is built.
  def test_belongs_to_updates_an_unsaved_attached_record
    widget = AttachedBtWidget.new(name: 'w')
    draft  = widget.build_category(name: 'draft')

    mapper = AttachedBtMapper.map_to_model(widget, { category: { name: 'final' } })

    assert_predicate mapper, :valid?, mapper.errors.inspect
    assert_same draft, widget.category
    assert_difference_of_one(Category) { widget.save! }
    assert_equal 'final', widget.reload.category.name
  end

  # --- has_one ----------------------------------------------------------------------------------------

  def test_has_one_updates_the_attached_record
    [AttachedHasOneMapper, AttachedHasOneUpsertMapper].each do |mapper_klass|
      manual = Manual.create!(title: 'orig')
      widget = Widget.create!(name: 'w', manual:)

      assert_no_new_row(Manual) do
        mapper = mapper_klass.map_to_model(widget, { manual: { title: 'renamed' } })

        assert_predicate mapper, :valid?, mapper.errors.inspect
        widget.save!
      end
      assert_equal manual.id, widget.reload.manual.id, mapper_klass.name
      assert_equal 'renamed', manual.reload.title, mapper_klass.name
      assert_equal widget.id, manual.widget_id, mapper_klass.name
    end
  end

  # Building a has_one replaces the current child at once (its foreign key is nullified): the map must
  # leave the child as stored until the parent's save.
  def test_has_one_update_writes_nothing_during_the_map
    manual = Manual.create!(title: 'orig')
    widget = Widget.create!(name: 'w', manual:)
    AttachedHasOneMapper.map_to_model(widget, { manual: { title: 'renamed' } })

    manual.reload
    assert_equal 'orig', manual.title
    assert_equal widget.id, manual.widget_id
  end

  def test_has_one_builds_a_record_when_none_is_attached
    [AttachedHasOneMapper, AttachedHasOneUpsertMapper].each do |mapper_klass|
      widget = Widget.create!(name: 'w')

      mapper = mapper_klass.map_to_model(widget, { manual: { title: 'fresh' } })

      assert_predicate mapper, :valid?, mapper.errors.inspect
      assert_difference_of_one(Manual) { widget.save! }
      assert_equal 'fresh', widget.reload.manual.title, mapper_klass.name
    end
  end

  def test_has_one_with_the_current_identifier_keeps_the_upsert
    manual = Manual.create!(title: 'orig')
    widget = Widget.create!(name: 'w', manual:)

    mapper = AttachedHasOneUpsertMapper.map_to_model(widget, { manual: { id: manual.id, title: 'renamed' } })

    assert_predicate mapper, :valid?, mapper.errors.inspect
    widget.save!
    assert_equal 'renamed', manual.reload.title
  end

  def test_has_one_with_a_different_identifier_is_still_refused
    old_manual = Manual.create!(title: 'old')
    widget     = Widget.create!(name: 'w', manual: old_manual)
    new_manual = Manual.create!(title: 'new')

    mapper = AttachedHasOneUpsertMapper.map_to_model(widget, { manual: { id: new_manual.id, title: 'x' } })

    refute_predicate mapper, :valid?
    assert_includes mapper.errors.keys, 'manual.id'
    assert_equal widget.id, old_manual.reload.widget_id
  end

  def test_has_one_attached_record_errors_keep_their_path
    widget = Widget.create!(name: 'w', manual: Manual.create!(title: 'orig'))

    mapper = AttachedHasOneMapper.map_to_model(widget, { manual: {} })

    refute_predicate mapper, :valid?
    assert_includes mapper.errors.keys, 'manual.title'
  end

  def test_has_one_updates_an_unsaved_attached_record
    widget = Widget.new(name: 'w')
    draft  = widget.build_manual(title: 'draft')

    mapper = AttachedHasOneMapper.map_to_model(widget, { manual: { title: 'final' } })

    assert_predicate mapper, :valid?, mapper.errors.inspect
    assert_same draft, widget.manual
    assert_difference_of_one(Manual) { widget.save! }
    assert_equal 'final', widget.reload.manual.title
  end

  # --- when the attached record is not the one to edit -----------------------------------------------

  # Leaving the id out must not reach a record that sending its id would be refused for.
  def test_upsert_refuses_an_attached_record_outside_allowing
    category = Category.create!(name: 'orig', enabled: false)
    widget   = AttachedBtWidget.create!(name: 'w', category:)

    mapper = AttachedBtScopedUpsertMapper.map_to_model(widget, { category: { name: 'renamed' } })

    refute_predicate mapper, :valid?
    assert_includes mapper.errors.keys, 'category.id'
    widget.save!
    assert_equal 'orig', category.reload.name
  end

  def test_upsert_edits_an_attached_record_inside_allowing
    category = Category.create!(name: 'orig', enabled: true)
    widget   = AttachedBtWidget.create!(name: 'w', category:)

    mapper = AttachedBtScopedUpsertMapper.map_to_model(widget, { category: { name: 'renamed' } })

    assert_predicate mapper, :valid?, mapper.errors.inspect
    widget.save!
    assert_equal 'renamed', category.reload.name
  end

  # A polymorphic owner of another class than the scope's is refused, even when the scope holds a
  # record with the same id.
  def test_upsert_refuses_a_polymorphic_attached_record_of_another_class
    category = Category.create!(name: 'orig')
    Part.find_by(id: category.id) || Part.create!(id: category.id, name: 'decoy')
    note = AttachedNote.create!(owner: category)

    mapper = AttachedPolyUpsertMapper.map_to_model(note, { owner: { name: 'renamed' } })

    refute_predicate mapper, :valid?
    assert_includes mapper.errors.keys, 'owner.id'
    note.save!
    assert_equal 'orig', category.reload.name
  end

  def test_upsert_edits_a_polymorphic_attached_record_of_the_scope_class
    part = Part.create!(name: 'orig')
    note = AttachedNote.create!(owner: part)

    mapper = AttachedPolyUpsertMapper.map_to_model(note, { owner: { name: 'renamed' } })

    assert_predicate mapper, :valid?, mapper.errors.inspect
    note.save!
    assert_equal 'renamed', part.reload.name
  end

  # A foreign key the payload just set picks a record by id outside any scope: a new one is built.
  def test_belongs_to_builds_when_the_foreign_key_changed_in_the_map
    victim = Category.create!(name: 'victim')
    widget = AttachedBtWidget.create!(name: 'w', category: Category.create!(name: 'own'))

    mapper = AttachedBtWithForeignKeyMapper.map_to_model(widget, { category_id: victim.id, category: { name: 'pwned' } })

    assert_predicate mapper, :valid?, mapper.errors.inspect
    widget.save!
    assert_equal 'victim', victim.reload.name
    assert_equal 'pwned', widget.reload.category.name
    refute_equal victim.id, widget.category_id
  end

  # Without autosave, the parent's save would drop the edit: a new record is built, as it always was.
  def test_belongs_to_without_autosave_builds_a_record
    category = Category.create!(name: 'orig')
    widget   = AttachedPlainBtWidget.create!(name: 'w', category:)

    mapper = AttachedPlainBtMapper.map_to_model(widget, { category: { name: 'fresh' } })

    assert_predicate mapper, :valid?, mapper.errors.inspect
    assert_difference_of_one(Category) { widget.save! }
    assert_equal 'fresh', widget.reload.category.name
    assert_equal 'orig', category.reload.name
  end

  def test_has_one_without_autosave_builds_a_record
    manual = Manual.create!(title: 'orig')
    widget = AttachedPlainHasOneWidget.create!(name: 'w', manual:)

    mapper = AttachedPlainHasOneMapper.map_to_model(widget, { manual: { title: 'fresh' } })

    assert_predicate mapper, :valid?, mapper.errors.inspect
    widget.save!
    assert_equal 'fresh', widget.reload.manual.title
    assert_equal 'orig', manual.reload.title
  end

  # A strict_loading owner is only read, as for a collection: the map does not raise.
  def test_belongs_to_on_a_strict_loading_parent
    category = Category.create!(name: 'orig')
    widget   = AttachedBtWidget.strict_loading.find(AttachedBtWidget.create!(name: 'w', category:).id)

    mapper = AttachedBtMapper.map_to_model(widget, { category: { name: 'renamed' } })

    assert_predicate mapper, :valid?, mapper.errors.inspect
    widget.save!
    assert_equal 'renamed', category.reload.name
  end

  # A record marked for destruction would be deleted by the parent's save: a new one is built instead.
  def test_belongs_to_marked_for_destruction_builds_a_record
    category = Category.create!(name: 'orig')
    widget   = AttachedDestroyBtWidget.create!(name: 'w', category:)
    widget.category.mark_for_destruction

    mapper = AttachedBtMapper.map_to_model(widget, { category: { name: 'fresh' } })

    assert_predicate mapper, :valid?, mapper.errors.inspect
    widget.save!
    assert_equal 'fresh', widget.reload.category.name
  end

  # --- an identifier without `allowing` ---------------------------------------------------------------

  # Without `allowing` nothing is selected by id: an id other than the attached record's is refused
  # rather than ignored, and nothing is edited.
  def test_belongs_to_without_allowing_refuses_another_identifier
    category = Category.create!(name: 'orig')
    other    = Category.create!(name: 'other')
    widget   = AttachedBtWidget.create!(name: 'w', category:)

    mapper = AttachedBtMapper.map_to_model(widget, { category: { id: other.id, name: 'renamed' } })

    refute_predicate mapper, :valid?
    assert_includes mapper.errors.keys, 'category.id'
    widget.save!
    assert_equal %w[orig other], [category.reload.name, other.reload.name]
  end

  # A client sending back the shape it read names the attached record: accepted, as an integer or a
  # string of digits.
  def test_belongs_to_without_allowing_accepts_the_attached_identifier
    [->(c) { c.id }, ->(c) { c.id.to_s }].each do |id_of|
      category = Category.create!(name: 'orig')
      widget   = AttachedBtWidget.create!(name: 'w', category:)

      mapper = AttachedBtMapper.map_to_model(widget, { category: { id: id_of.(category), name: 'renamed' } })

      assert_predicate mapper, :valid?, mapper.errors.inspect
      widget.save!
      assert_equal 'renamed', category.reload.name
    end
  end

  def test_has_one_without_allowing_refuses_an_identifier_when_none_is_attached
    stray  = Manual.create!(title: 'stray')
    widget = Widget.create!(name: 'w')

    mapper = AttachedHasOneMapper.map_to_model(widget, { manual: { id: stray.id, title: 'x' } })

    refute_predicate mapper, :valid?
    assert_includes mapper.errors.keys, 'manual.id'
    assert_nil widget.manual
  end

  def test_has_one_without_allowing_accepts_the_attached_identifier
    manual = Manual.create!(title: 'orig')
    widget = Widget.create!(name: 'w', manual:)

    mapper = AttachedHasOneMapper.map_to_model(widget, { manual: { id: manual.id, title: 'renamed' } })

    assert_predicate mapper, :valid?, mapper.errors.inspect
    widget.save!
    assert_equal 'renamed', manual.reload.title
  end

  # An id taken as sent: "1abc" would cast to the attached record's id, it names nothing.
  def test_without_allowing_an_inexact_identifier_is_refused
    category = Category.create!(name: 'orig')
    widget   = AttachedBtWidget.create!(name: 'w', category:)

    mapper = AttachedBtMapper.map_to_model(widget, { category: { id: "#{category.id}abc", name: 'x' } })

    refute_predicate mapper, :valid?
    assert_includes mapper.errors.keys, 'category.id'
  end

  # A blank identifier names nothing: the attached record is edited.
  def test_without_allowing_a_blank_identifier_is_not_weighed
    category = Category.create!(name: 'orig')
    widget   = AttachedBtWidget.create!(name: 'w', category:)

    mapper = AttachedBtMapper.map_to_model(widget, { category: { id: '', name: 'renamed' } })

    assert_predicate mapper, :valid?, mapper.errors.inspect
    widget.save!
    assert_equal 'renamed', category.reload.name
  end

  # A key the sub-mapper reads itself is data, not an identifier.
  def test_without_allowing_an_id_the_sub_mapper_reads_is_data
    widget = Widget.create!(name: 'w')

    mapper = AttachedExternalPartsMapper.map_to_model(widget, { parts: [{ id: 'EXT-1' }] })

    assert_predicate mapper, :valid?, mapper.errors.inspect
    assert_equal 'EXT-1', widget.parts.first.name
  end

  # A section that is not an object has no key to read: the identifier check leaves its shape alone,
  # whatever the value (a scalar equal to the attached id or not, a list).
  def test_without_allowing_a_non_object_section_is_not_taken_for_an_identifier
    category = Category.create!(name: 'orig')
    widget   = AttachedBtWidget.create!(name: 'w', category:)

    [{ category: 999 }, { category: category.id }, { category: [{ name: 'x' }] }].each do |payload|
      assert_raises(TypeError, payload.inspect) { AttachedBtMapper.map_to_model(widget, payload) }
    end
    assert_raises(TypeError) { AttachedPartsMapper.map_to_model(Widget.new, { parts: { name: 'x' } }) }
  end

  # The attached record's id is refused when the payload would not edit that record.
  def test_without_allowing_the_attached_identifier_is_refused_when_it_is_not_edited
    category = Category.create!(name: 'orig')
    widget   = AttachedPlainBtWidget.create!(name: 'w', category:)

    mapper = AttachedPlainBtMapper.map_to_model(widget, { category: { id: category.id, name: 'x' } })

    refute_predicate mapper, :valid?
    assert_includes mapper.errors.keys, 'category.id'
  end

  # `:id` is the primary key, whatever its column is named: a string of digits names it.
  def test_without_allowing_the_attached_identifier_is_cast_by_the_primary_key
    owner  = AttachedLegacyOwner.create!(name: 'orig')
    widget = AttachedLegacyWidget.create!(legacy_owner: owner)

    mapper = AttachedLegacyMapper.map_to_model(widget, { legacy_owner: { id: owner.id.to_s, name: 'renamed' } })

    assert_predicate mapper, :valid?, mapper.errors.inspect
    widget.save!
    assert_equal 'renamed', owner.reload.name
  end

  def test_many_without_allowing_refuses_an_element_identifier
    part   = Part.create!(name: 'kept')
    widget = Widget.create!(name: 'w', parts: [part])

    mapper = AttachedPartsMapper.map_to_model(widget, { parts: [{ id: part.id, name: 'renamed' }] })

    refute_predicate mapper, :valid?
    assert_includes mapper.errors.keys, 'parts.0.id'
    assert_no_new_row(Part) { widget.save! }
    assert_equal 'kept', part.reload.name
  end

  # --- many: true -------------------------------------------------------------------------------------

  # A collection element without an identifier stays a creation, whatever the parent already holds.
  def test_many_element_without_identifier_is_still_created
    widget = Widget.create!(name: 'w', parts: [Part.new(name: 'kept')])

    mapper = AttachedPartsMapper.map_to_model(widget, { parts: [{ name: 'added' }] })

    assert_predicate mapper, :valid?, mapper.errors.inspect
    assert_difference_of_one(Part) { widget.save! }
    assert_equal %w[added kept], widget.parts.reload.map(&:name).sort
  end

  private

  # Runs the block and asserts it inserted no row in the model's table.
  def assert_no_new_row(model, &)
    before = model.count
    yield
    assert_equal before, model.count, "a #{model.name} row was created"
  end

  # Runs the block and asserts it inserted exactly one row in the model's table.
  def assert_difference_of_one(model, &)
    before = model.count
    yield
    assert_equal before + 1, model.count, "expected exactly one new #{model.name} row"
  end

end
