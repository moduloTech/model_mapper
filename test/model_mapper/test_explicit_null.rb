# frozen_string_literal: true

require 'test_helper'

# Sub-mappers local to this file, so it runs on its own (named to avoid clashing with other files).
class NullPartMapper

  include ModelMapper

  map_model { attribute :name }

end

class NullManualMapper

  include ModelMapper

  map_model { attribute :title }

end

# A clearing request — an explicit null (key present, raw value nil), or an empty list on a
# multi-valued param — clears the value, as `nullable true` says, which is the default; `nullable
# false` refuses it. An absent key leaves the value alone.
class TestExplicitNull < Minitest::Test

  def setup
    Widget.delete_all
    Category.delete_all
    Part.delete_all
  end

  def mapper(&block)
    Class.new do
      include ModelMapper

      map_model(&block)
    end
  end

  # --- undeclared: cleared, like `nullable true` ---

  def test_undeclared_null_clears_the_value
    klass = mapper { attribute :name }
    widget = Widget.create!(name: 'old')

    assert_output(nil, '') { klass.map_to_model!(widget, { name: nil }) }
    assert_nil widget.name
  end

  def test_undeclared_absent_key_keeps_the_value
    klass = mapper do
      attribute :name
      attribute :status
    end
    widget = Widget.new(name: 'kept')

    klass.map_to_model!(widget, { status: 'active' })
    assert_equal 'kept', widget.name
  end

  def test_undeclared_null_clears_a_nested_attribute
    klass = mapper do
      attribute :status do
        from :info, :status
      end
    end
    widget = Widget.new(status: 'active')

    klass.map_to_model!(widget, { info: { status: nil } })
    assert_nil widget.status
  end

  # Erasing a value and falling back to a default are opposite intentions: the null wins.
  def test_undeclared_null_does_not_apply_the_default
    klass = mapper do
      attribute :status do
        default 'dflt'
      end
    end
    widget = Widget.new(status: 'active')

    klass.map_to_model!(widget, { status: nil })
    assert_nil widget.status
  end

  def test_undeclared_null_clears_when_a_lambda_required_answers_false
    klass = mapper do
      attribute :code
      attribute :name do
        required ->(params) { params[:code].nil? }
      end
    end
    widget = Widget.new(name: 'old')

    klass.map_to_model!(widget, { code: 'X', name: nil })
    assert_nil widget.name
  end

  # An `allowing` frames the clearing like any other value (see test_allowing.rb): a list that does not
  # name nil refuses the null instead of clearing, and one that names it accepts the clear.
  def test_undeclared_null_is_framed_by_allowing
    refusing = mapper { attribute :status do allowing %w[active inactive] end }
    accepting = mapper { attribute :status do allowing ['active', 'inactive', nil] end }

    widget = Widget.new(status: 'active')
    result = refusing.map_to_model(widget, { status: nil })
    assert_equal ['status'], result.errors.keys
    assert_kind_of ModelMapper::InvalidValueError, result.errors['status']
    assert_equal 'active', widget.status

    accepting.map_to_model!(widget, { status: nil })
    assert_nil widget.status
  end

  # The flip makes a null on any reference a clear. On a persisted parent, clearing a has_one is a write
  # ActiveRecord makes at once: refused (immediate_write undeclared), so a failing map detaches nothing.
  def test_undeclared_null_on_a_one_reference_beside_an_invalid_param_detaches_nothing
    klass = mapper do
      association :manual do allowing -> { Manual.all } end
      attribute :price do type :float end
    end
    widget = Widget.create!
    manual = Manual.create!(title: 'm', widget:)

    result = klass.map_to_model(widget, { manual: nil, price: 'abc' })
    assert_equal %w[manual price], result.errors.keys.sort
    assert_equal widget.id, manual.reload.widget_id
  end

  # 0.5.0 shipped them; nothing is left for them to forget, but they still answer.
  def test_reset_methods_still_exist
    assert_nil ModelMapper.reset_deprecation_warnings!
    assert_nil ModelMapper.reset_explicit_null_warnings!
  end

  # --- not a clearing request: no change ---

  def test_absent_blank_and_empty_values_change_nothing
    klass = mapper do
      attribute :name
      attribute :numbers do
        type :array
        of :integer
      end
      association :category do
        allowing -> { Category.all }
      end
    end

    category = Category.create!(name: 'c')
    [{}, { name: '' }, { name: [] }, { numbers: [''] }, { category: {} }].each do |payload|
      widget = Widget.new(name: 'kept', numbers: [1], category:)
      klass.map_to_model(widget, payload)
      assert_equal 'kept', widget.name, payload.inspect
      assert_equal [1], widget.numbers, payload.inspect
      assert_equal category, widget.category, payload.inspect
    end
  end

  def test_false_is_not_an_explicit_null
    undeclared = mapper do
      attribute :active do
        type :boolean
      end
    end
    nullable = mapper do
      attribute :active do
        type :boolean
        nullable true
      end
    end

    widget = Widget.new(active: true)
    assert_output(nil, '') { undeclared.map_to_model(widget, { active: false }) }
    assert_equal false, widget.active

    widget = Widget.new(active: true)
    nullable.map_to_model(widget, { active: false })
    assert_equal false, widget.active
  end

  def test_string_key_null_on_a_symbol_declaration_is_an_explicit_null
    undeclared = mapper { attribute :name }
    nullable = mapper { attribute :name, nullable: true }
    refusing = mapper { attribute :name, nullable: false }

    widget = Widget.new(name: 'old')
    assert_output(nil, '') { undeclared.map_to_model!(widget, { 'name' => nil }) }
    assert_nil widget.name

    widget = Widget.new(name: 'old')
    nullable.map_to_model!(widget, { 'name' => nil })
    assert_nil widget.name

    assert_includes refusing.map_to_model(Widget.new, { 'name' => nil }).errors.keys, 'name'
  end

  def test_null_or_empty_parent_of_a_nested_path_is_not_an_explicit_null
    undeclared = mapper do
      attribute :status do
        from :info, :status
      end
    end
    nullable = mapper do
      attribute :status do
        from :info, :status
        nullable true
      end
    end

    [{ info: nil }, { info: {} }].each do |payload|
      widget = Widget.new(status: 'active')
      assert_output(nil, '') { undeclared.map_to_model(widget, payload) }
      nullable.map_to_model(widget, payload)
      assert_equal 'active', widget.status
    end
  end

  def test_required_null_raises_even_when_nullable_true
    klass = mapper do
      attribute :name do
        required true
        nullable true
      end
    end
    widget = Widget.new(name: 'kept')

    error = nil
    assert_output(nil, '') do
      error = assert_raises(ModelMapper::ValidationError) { klass.map_to_model!(widget, { name: nil }) }
    end
    assert_kind_of ModelMapper::InvalidNilValueError, error.errors['name']
    assert_equal 'kept', widget.name
  end

  # A validation-only param is cleared too: its reader returns nil — not its `default` — and the record
  # is left alone.
  def test_validation_only_param_clears_its_reader_only
    klass = mapper do
      attribute :name do
        assign false
        default 'dflt'
      end
    end
    widget = Widget.new(name: 'kept')

    result = klass.map_to_model!(widget, { name: nil })
    assert_nil result.name
    assert_equal 'kept', widget.name
  end

  def test_map_if_false_skips_the_null
    klass = mapper do
      attribute :name do
        map_if -> { false }
      end
    end
    widget = Widget.new(name: 'kept')

    klass.map_to_model!(widget, { name: nil })
    assert_equal 'kept', widget.name
  end

  # A sub-mapper association stages its records in memory and has no value to clear: a null or an empty
  # list leaves the children as they are.
  def test_sub_mapper_association_null_or_empty_list_is_skipped
    klass = mapper do
      association :parts_attributes, many: true do
        from :parts
        with NullPartMapper
      end
    end

    [{ parts: nil }, { parts: [] }].each do |payload|
      widget = Widget.create!
      part = Part.create!(name: 'p', widget:)

      result = nil
      assert_output(nil, '') { result = klass.map_to_model(widget, payload) }
      assert_predicate result, :valid?
      assert_equal [part], widget.parts.to_a
      assert_equal widget.id, part.reload.widget_id
    end
  end

  # --- nullable true: clears, like undeclared ---

  def test_nullable_true_clears_a_scalar
    klass = mapper do
      attribute :name, nullable: true
    end
    widget = Widget.create!(name: 'old')

    assert_output(nil, '') { klass.map_to_model!(widget, { name: nil }) }
    assert_nil widget.name
  end

  def test_nullable_true_clears_a_nested_attribute
    klass = mapper do
      attribute :status do
        from :info, :status
        nullable true
      end
    end
    widget = Widget.new(status: 'active')

    klass.map_to_model!(widget, { info: { status: nil } })
    assert_nil widget.status
  end

  def test_nullable_true_does_not_apply_the_default
    klass = mapper do
      attribute :status do
        default 'dflt'
        nullable true
      end
    end
    widget = Widget.new(status: 'active')

    klass.map_to_model!(widget, { status: nil })
    assert_nil widget.status
  end

  def test_nullable_true_unlinks_a_singular_reference
    category = Category.create!(name: 'c')
    klass = mapper do
      association :category do
        allowing -> { Category.all }
        nullable true
      end
    end
    widget = Widget.create!(category:)

    klass.map_to_model!(widget, { category: nil })
    assert_nil widget.category
  end

  def test_nullable_true_empties_an_array_of_scalars
    klass = mapper do
      attribute :numbers do
        type :array
        of :integer
        nullable true
      end
    end
    widget = Widget.new
    widget.numbers = [1, 2]

    klass.map_to_model!(widget, { numbers: nil })
    assert_equal [], widget.numbers
  end

  # On a persisted parent ActiveRecord nullifies the previous children at once: `immediate_write true`
  # accepts that write (see test_immediate_write.rb for the undeclared and refused cases).
  def test_nullable_true_empties_a_many_reference
    klass = mapper do
      association :parts, many: true do
        allowing -> { Part.all }
        nullable true
        immediate_write true
      end
    end
    widget = Widget.create!
    part = Part.create!(name: 'p', widget:)

    result = nil
    assert_output(nil, '') { result = klass.map_to_model(widget, { parts: nil }) }
    assert result.valid?
    assert_equal [], widget.parts.to_a
    assert_nil part.reload.widget_id
  end

  def test_nullable_true_with_assign_false_sets_the_reader_only
    klass = mapper do
      attribute :numbers do
        type :array
        of :integer
        assign false
        nullable true
      end
    end
    widget = Widget.new
    widget.numbers = [1]

    result = klass.map_to_model!(widget, { numbers: nil })
    assert_equal [], result.numbers
    assert_equal [1], widget.numbers
  end

  def test_nullable_true_clears_when_a_lambda_required_answers_false
    klass = mapper do
      attribute :code
      attribute :name do
        required ->(params) { params[:code].nil? }
        nullable true
      end
    end
    widget = Widget.new(name: 'old')

    klass.map_to_model!(widget, { code: 'X', name: nil })
    assert_nil widget.name
  end

  # --- nullable false: refuses the null ---

  def test_nullable_false_keyword_refuses_a_null
    klass = mapper do
      attribute :name, nullable: false
    end
    widget = Widget.new(name: 'kept')

    error = nil
    assert_output(nil, '') do
      error = assert_raises(ModelMapper::ValidationError) { klass.map_to_model!(widget, { name: nil }) }
    end
    assert_kind_of ModelMapper::InvalidNilValueError, error.errors['name']
    assert_equal 'kept', widget.name
  end

  def test_nullable_false_keeps_the_key_optional
    klass = mapper do
      attribute :name, nullable: false
    end
    widget = Widget.new(name: 'kept')

    klass.map_to_model!(widget, {})
    assert_equal 'kept', widget.name
  end

  def test_nullable_false_error_is_keyed_on_the_params_path
    klass = mapper do
      attribute :status do
        from :info, :status
        nullable false
      end
    end

    error = assert_raises(ModelMapper::ValidationError) do
      klass.map_to_model!(Widget.new, { info: { status: nil } })
    end
    assert_equal ['info.status'], error.fields
    assert_kind_of ModelMapper::InvalidNilValueError, error.errors['info.status']
  end

  # --- an empty list on a multi-valued param: a clearing request, governed like a null ---
  # It is what a client sends once it has removed every element (`JSON.stringify({ parts: [] })`).

  def numbers_mapper(**options, &extra)
    mapper do
      attribute :numbers, **options do
        type :array
        of :integer
        instance_exec(&extra) if extra
      end
    end
  end

  def test_undeclared_empty_list_empties_the_value
    widget = Widget.new(numbers: [1, 2])

    assert_output(nil, '') { numbers_mapper.map_to_model!(widget, { numbers: [] }) }
    assert_equal [], widget.numbers
  end

  def test_undeclared_empty_list_does_not_apply_the_default
    widget = Widget.new(numbers: [1, 2])

    numbers_mapper { default [9] }.map_to_model!(widget, { numbers: [] })
    assert_equal [], widget.numbers
  end

  # Emptying a persisted parent's has_many is a write ActiveRecord makes at once: refused unless the
  # reference declares `immediate_write true` (see test_immediate_write.rb).
  def test_undeclared_empty_list_on_a_many_reference_is_refused_and_keeps_the_children
    klass = mapper do
      association :parts, many: true do
        allowing -> { Part.all }
      end
    end
    widget = Widget.create!
    part = Part.create!(name: 'p', widget:)

    assert_equal ['parts'], klass.map_to_model(widget, { parts: [] }).errors.keys
    assert_equal widget.id, part.reload.widget_id
  end

  def test_nullable_true_empties_an_array_of_scalars_on_an_empty_list
    widget = Widget.new(numbers: [1, 2])

    assert_output(nil, '') { numbers_mapper(nullable: true).map_to_model!(widget, { numbers: [] }) }
    assert_equal [], widget.numbers
  end

  def test_nullable_true_empty_list_does_not_apply_the_default
    widget = Widget.new(numbers: [1, 2])

    numbers_mapper(nullable: true) { default [9] }.map_to_model!(widget, { numbers: [] })
    assert_equal [], widget.numbers
  end

  # Same known limitation as the null (issue #13): the previous children are detached at once.
  def test_nullable_true_empties_a_many_reference_on_an_empty_list
    klass = mapper do
      association :parts, many: true do
        allowing -> { Part.all }
        nullable true
        immediate_write true
      end
    end
    widget = Widget.create!
    part = Part.create!(name: 'p', widget:)

    assert_predicate klass.map_to_model(widget, { parts: [] }), :valid?
    assert_equal [], widget.parts.to_a
    assert_nil part.reload.widget_id
  end

  def test_nullable_false_refuses_an_empty_list
    widget = Widget.new(numbers: [1, 2])

    error = nil
    assert_output(nil, '') do
      error = assert_raises(ModelMapper::ValidationError) do
        numbers_mapper(nullable: false).map_to_model!(widget, { numbers: [] })
      end
    end
    assert_equal ['numbers'], error.fields
    assert_kind_of ModelMapper::InvalidNilValueError, error.errors['numbers']
    assert_equal [1, 2], widget.numbers
  end

  def test_required_empty_list_raises
    error = nil
    assert_output(nil, '') do
      error = assert_raises(ModelMapper::ValidationError) do
        numbers_mapper(nullable: true) { required true }.map_to_model!(Widget.new, { numbers: [] })
      end
    end
    assert_kind_of ModelMapper::InvalidNilValueError, error.errors['numbers']
  end

  # On a scalar, an empty list names no value to clear: it says nothing, whatever `nullable` says.
  def test_empty_list_on_a_scalar_param_is_not_a_clearing_request
    [nil, true, false].each do |nullable|
      klass = mapper { attribute :name, nullable: }
      widget = Widget.new(name: 'kept')

      assert_output(nil, '') { klass.map_to_model!(widget, { name: [] }) }
      assert_equal 'kept', widget.name
    end
  end

  # --- inheritance ---

  def test_child_mapper_keeps_the_parents_nullable_when_silent
    parent = mapper do
      attribute :name, nullable: true
    end
    # The child re-declares `name` without `nullable`, so `merge!` runs on it and must keep the parent's.
    child = Class.new(parent) do
      map_model do
        attribute :name do
          required false
        end
      end
    end
    widget = Widget.new(name: 'old')

    child.map_to_model!(widget, { name: nil })
    assert_nil widget.name
  end

  def test_child_mapper_can_tighten_the_parents_nullable
    parent = mapper do
      attribute :name, nullable: true
    end
    child = Class.new(parent) do
      map_model do
        attribute :name do
          nullable false
        end
      end
    end

    error = assert_raises(ModelMapper::ValidationError) { child.map_to_model!(Widget.new, { name: nil }) }
    assert_kind_of ModelMapper::InvalidNilValueError, error.errors['name']
  end

  # --- configuration ---

  def test_nullable_on_a_sub_mapper_association_is_a_configuration_error
    [true, false].each do |value|
      assert_raises(ModelMapper::ConfigurationError) do
        mapper do
          association :manual_attributes, nullable: value do
            with NullManualMapper
          end
        end.map_to_model(Widget.new, {})
      end
      assert_raises(ModelMapper::ConfigurationError) do
        mapper do
          association :manual_attributes do
            with NullManualMapper
            nullable value
          end
        end.map_to_model(Widget.new, {})
      end
    end
  end

  def test_nullable_other_than_true_or_false_is_a_configuration_error
    ['false', :true, 1, -> { true }].each do |value|
      error = assert_raises(ModelMapper::ConfigurationError) do
        mapper { attribute :name, nullable: value }.map_to_model(Widget.new, {})
      end
      assert_match(/`nullable` takes true or false/, error.message)
    end
  end

  def test_nullable_on_a_deprecated_sub_mapper_attribute_is_a_configuration_error
    capture_io do
      assert_raises(ModelMapper::ConfigurationError) do
        mapper do
          attribute :parts_attributes do
            type :array
            with NullPartMapper
            nullable true
          end
        end.map_to_model(Widget.new, {})
      end
    end
  end

end
