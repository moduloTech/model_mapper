# frozen_string_literal: true

require 'test_helper'

class TestInvalidValueError < Minitest::Test

  def test_stores_field
    error = ModelMapper::InvalidValueError.new('name')
    assert_equal 'name', error.field
  end

  def test_stores_details
    error = ModelMapper::InvalidValueError.new('name', details: 'too long')
    assert_equal 'too long', error.details
  end

  def test_message_without_details
    error = ModelMapper::InvalidValueError.new('name')
    assert_includes error.message, 'name'
  end

  def test_message_with_details
    error = ModelMapper::InvalidValueError.new('name', details: 'too long')
    assert_includes error.message, 'name'
    assert_includes error.message, 'too long'
  end

  def test_inherits_from_runtime_error
    assert_kind_of RuntimeError, ModelMapper::InvalidValueError.new('x')
  end

end

class TestInvalidNilValueError < Minitest::Test

  def test_inherits_from_invalid_value_error
    assert_kind_of ModelMapper::InvalidValueError, ModelMapper::InvalidNilValueError.new('x')
  end

  def test_stores_field
    error = ModelMapper::InvalidNilValueError.new('email')
    assert_equal 'email', error.field
  end

end

class TestInvalidFormatError < Minitest::Test

  def test_stores_field
    error = ModelMapper::InvalidFormatError.new('price')
    assert_equal 'price', error.field
  end

  def test_message_without_expected_format
    error = ModelMapper::InvalidFormatError.new('price')
    assert_includes error.message, 'price'
  end

  def test_message_with_expected_format
    error = ModelMapper::InvalidFormatError.new('price', expected_format: :float)
    assert_includes error.message, 'price'
    assert_includes error.message, 'float'
  end

  def test_inherits_from_runtime_error
    assert_kind_of RuntimeError, ModelMapper::InvalidFormatError.new('x')
  end

end

class TestValidationError < Minitest::Test

  def test_inherits_from_runtime_error
    error = ModelMapper::ValidationError.new({})
    assert_kind_of RuntimeError, error
  end

  def test_stores_errors_hash
    errors = { 'name' => ModelMapper::InvalidNilValueError.new('name') }
    error = ModelMapper::ValidationError.new(errors)
    assert_equal errors, error.errors
  end

  def test_fields_returns_keys
    errors = {
      'name' => ModelMapper::InvalidNilValueError.new('name'),
      'price' => ModelMapper::InvalidFormatError.new('price')
    }
    error = ModelMapper::ValidationError.new(errors)
    assert_equal %w[name price], error.fields
  end

  def test_first_error_returns_first_value
    nil_err = ModelMapper::InvalidNilValueError.new('name')
    errors = { 'name' => nil_err, 'price' => ModelMapper::InvalidFormatError.new('price') }
    error = ModelMapper::ValidationError.new(errors)
    assert_equal nil_err, error.first_error
  end

  def test_message_contains_all_fields
    errors = {
      'name' => ModelMapper::InvalidNilValueError.new('name'),
      'price' => ModelMapper::InvalidFormatError.new('price')
    }
    error = ModelMapper::ValidationError.new(errors)
    assert_includes error.message, 'name'
    assert_includes error.message, 'price'
  end

end
