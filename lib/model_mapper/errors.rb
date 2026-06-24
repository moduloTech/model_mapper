# frozen_string_literal: true

module ModelMapper

  # Raised when a caller still uses the removed `map_to_model(save: true)` option. Persistence is now
  # an explicit choice: use save_to_model! (validate + save!) or save_to_model (validate + save).
  class SaveOptionRemovedError < RuntimeError

    def initialize(msg = nil)
      super(msg || 'map_to_model no longer persists: the `save:` option was removed. ' \
                   'Use `save_to_model!` (validate + save!) or `save_to_model` (validate + save) instead.')
    end

  end

  class InvalidValueError < RuntimeError

    attr_reader :field, :details

    def initialize(field, details: nil, message_key: 'errors.invalid_value_error')
      message =
        if !details.nil? && !(details.respond_to?(:empty?) && details.empty?)
          I18n.t('errors.invalid_value_error_detailed', field:, details:)
        else
          I18n.t(message_key, field:)
        end
      super(message)

      @field   = field
      @details = details
    end

  end

  class InvalidNilValueError < InvalidValueError

    def initialize(field)
      super(field, message_key: 'errors.invalid_nil_value_error')
    end

  end

  class InvalidFormatError < RuntimeError

    attr_reader :field

    def initialize(field, expected_format: nil)
      message =
        if expected_format
          I18n.t('errors.invalid_format_error_detailed', field:, expected_format:)
        else
          I18n.t('errors.invalid_format_error', field:)
        end
      super(message)

      @field = field
    end

  end

  # Wraps a target's own (ActiveModel/ActiveRecord) validation error(s) for a
  # single attribute, so combined results share one shape with the mapper errors
  # (it responds to #message and #field like the mapper's error objects).
  class RecordError < RuntimeError

    attr_reader :field

    def initialize(field, message)
      @field = field
      super(message)
    end

  end

  class ValidationError < RuntimeError

    attr_reader :errors

    def initialize(errors)
      @errors = errors
      messages = errors.map { |field, error| "#{field}: #{error.message}" }
      super(messages.join('; '))
    end

    def fields
      @errors.keys
    end

    def first_error
      @errors.values.first
    end

  end

end
