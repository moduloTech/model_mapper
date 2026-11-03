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
