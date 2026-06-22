# frozen_string_literal: true

require 'i18n'

require_relative 'model_mapper/errors'
require_relative 'model_mapper/param_config'
require_relative 'model_mapper/config'

# ModelMapper provides a declarative DSL for mapping hash/JSON parameters
# to ActiveRecord models with combined validation and opt-in persistence.
#
# Example usage:
#
#   class UpdateService
#     include ModelMapper
#
#     def initialize(mission, params)
#       @mission = mission
#       @params = params
#     end
#
#     map_model do
#       from :@params
#       to :mission
#
#       attribute :zone_id do
#         at :infraction, :zone, :id
#         type :referential
#         allowing Zone.enabled
#         required true
#       end
#
#       attribute :is_electronic_fine do
#         at :infraction, :electronic_fine
#         type :enumerated
#         allowing [true, false]
#       end
#     end
#   end
#
# Call the mapping methods directly — no `call` wrapper needed. They return the
# (assigned) target object:
#
#   # validate (mapper + record) + assign, then persist explicitly in the caller:
#   mission = UpdateService.new(mission, params).map_to_model! # raises on invalid
#   mission.save!
#
#   # non-raising variant — inspect the result:
#   service = UpdateService.new(mission, params)
#   service.map_to_model
#   service.valid?  # => false
#   service.errors  # => { "infraction/zone/id" => #<ModelMapper::InvalidValueError ...> }
#
module ModelMapper

  def self.root
    File.expand_path('..', __dir__)
  end

  def self.included(base)
    base.extend(ClassMethods)
  end

  module ClassMethods

    # DSL method to define mapping configuration
    def map_model(&block)
      # Get parent config if this class inherits from a class that also uses ModelMapper
      parent_config = superclass.respond_to?(:model_mapper_config) ? superclass.model_mapper_config : nil

      # Create or update the mapping config
      @model_mapper_config ||= Config.new(parent_config)
      @model_mapper_config.instance_eval(&block) if block
    end

    # Get the mapping configuration
    def model_mapper_config
      # If the getter is called before the setter, it means we're in a subclass of a parent including
      # ModelMapper.
      # In that case, we use the configuration of the parent directly.
      @model_mapper_config ||= superclass.respond_to?(:model_mapper_config) ? superclass.model_mapper_config : nil
    end

    # One-call shortcuts: build the mapper with the given initializer args and run the matching
    # instance method. Returns the mapper instance, so callers can read their own target accessor
    # plus #errors / #valid?. The `!` variants raise just like their instance counterparts.
    #
    #   JobMapper.map_to_model!(job, params, user)
    #   # == JobMapper.new(job, params, user).tap(&:map_to_model!)
    def map_to_model(*args)   = new(*args).tap(&:map_to_model)
    def map_to_model!(*args)  = new(*args).tap(&:map_to_model!)
    def save_to_model(*args)  = new(*args).tap(&:save_to_model)
    def save_to_model!(*args) = new(*args).tap(&:save_to_model!)

  end

  # --- Public API ----------------------------------------------------------
  #
  # Four entry points. None of the `map_*` variants persist; the `save_*`
  # variants delegate persistence to the target (opt-in — saves stay explicit
  # for those who prefer to call `save` in the caller instead).
  #
  # All four run *combined* validation before returning: the ModelMapper rules
  # first and — only once those pass — the target's own ActiveModel/ActiveRecord
  # validations, merged into a single ModelMapper::ValidationError shape. The
  # mapper rules act as a gate: a malformed payload is reported on its own (the
  # target is not assembled, so its validations cannot run on bad input).
  #
  # The `!` variants raise ModelMapper::ValidationError when invalid. The
  # non-bang variants never raise on validation failure — read #errors / #valid?
  # on the mapper instance afterwards.

  # Validate + assign, without persisting. Non-raising.
  # @return [Object] the (assigned) target object
  def map_to_model
    target, @model_mapper_errors = run_mapping
    target
  end

  # Validate + assign, without persisting. Raises on invalid.
  # @return [Object] the (assigned) target object
  # @raise [ModelMapper::ValidationError] if validation fails (mapper or record)
  def map_to_model!
    target = map_to_model
    raise ModelMapper::ValidationError.new(@model_mapper_errors) if @model_mapper_errors.any?

    target
  end

  # Validate + assign, then persist with #save when valid. Non-raising: the save
  # is skipped (and false-y persistence results surface via the model) when invalid.
  # @return [Object] the (assigned, possibly persisted) target object
  def save_to_model
    target = map_to_model
    persist_with_hooks(target, self.class.model_mapper_config, bang: false) if @model_mapper_errors.empty?
    target
  end

  # Validate + assign, then persist with #save!. Raises on invalid or save failure.
  # @return [Object] the (assigned, persisted) target object
  # @raise [ModelMapper::ValidationError] if validation fails (mapper or record)
  def save_to_model!
    target = map_to_model!
    persist_with_hooks(target, self.class.model_mapper_config, bang: true)
    target
  end

  # Combined validation errors collected by the last map_to_model/save_to_model
  # call. Hash of { field => error }; each error responds to #message. Empty when valid.
  def errors = @model_mapper_errors ||= {}

  # @return [Boolean] true when the last mapping produced no combined errors
  def valid? = errors.empty?

  private

  # Core mapping + combined validation. Never raises on validation failure and
  # never persists. Returns [target, errors_hash].
  def run_mapping
    config = self.class.model_mapper_config
    raise ArgumentError, 'No mapping configuration defined. Use map_model do...end block.' if config.nil?

    config.validate!

    # Extract source params and target object
    source_params = extract_source(config.from_source)
    target_object = extract_target(config.to_target)

    # Execute before_validation hook
    instance_exec(source_params, target_object, &config.before_validation_hook) if config.before_validation_hook

    # Validate all params and collect results
    validated_params = {}
    validation_errors = {}
    config.params.each do |param_name, param_config|
      # Skip param if condition is not met
      next unless param_config.condition_met?(target_object, source_params, self)

      begin
        allow_nil = !param_config.required?(source_params, target_object)
        value = validate_param(param_config, source_params, target_object, allow_nil)
      rescue ModelMapper::InvalidValueError, ModelMapper::InvalidFormatError => e
        validation_errors[e.field] = e
        next
      rescue StandardError => e
        # Errors from user-provided lambdas (e.g. allowing, required) that depend on
        # previously-failed attributes. Only accumulate if there are already validation errors,
        # otherwise re-raise as it's likely a genuine bug.
        raise if validation_errors.empty?

        field = param_config.keys.join('/')
        validation_errors[field] = ModelMapper::InvalidValueError.new(field, details: e.message)
        next
      end

      # Store as instance variable for use in hooks
      if defined?(ActiveRecord::Base) && value.is_a?(ActiveRecord::Base) && param_name.to_s.end_with?('_id')
        instance_variable_set(:"@#{param_name}", value.id)
        instance_variable_set(:"@#{param_name.to_s.gsub(/_id$/, '')}", value)
      else
        instance_variable_set(:"@#{param_name}", value)
      end

      # Skip nil values when not required
      next if value.nil? && allow_nil

      # Only include in the assignment hash when this param is assignable
      next unless param_config.save?

      # For referential types, extract the ID for assignment
      validated_params[param_name] =
        if param_config.type_value == :referential && value.respond_to?(:id)
          value.id
        else
          value
        end
    end

    # Mapper rules are a gate: when the payload itself is malformed we do NOT
    # assemble or validate the target — the model cannot be meaningfully validated
    # from invalid input, and before_assignation must not run on bad data. The
    # target's own validations run only once the mapping is clean.
    return [target_object, validation_errors] if validation_errors.any?

    # Execute before_assignation hook in the instance context
    instance_exec(source_params, validated_params, &config.before_assignation_hook) if config.before_assignation_hook

    # Assign attributes to target
    assign_to_target(target_object, validated_params)

    # Combined validation: harvest the target's own (ActiveModel) errors
    merge_record_errors!(validation_errors, target_object)

    [target_object, validation_errors]
  end

  # Run the target's own ActiveModel/ActiveRecord validations (without saving)
  # and merge them into the combined error hash, one entry per attribute.
  def merge_record_errors!(validation_errors, target)
    return validation_errors unless target.respond_to?(:valid?) && target.respond_to?(:errors)

    target.valid?

    target.errors.group_by_attribute.each do |attribute, errs|
      validation_errors[attribute.to_s] ||=
        ModelMapper::RecordError.new(attribute.to_s, errs.map(&:message).join(', '))
    end

    validation_errors
  end

  # Wrap persistence with the before_save/after_save hooks.
  def persist_with_hooks(target, config, bang:)
    source_params = extract_source(config.from_source)
    instance_exec(source_params, &config.before_save_hook) if config.before_save_hook
    persist_target(target, config, bang:)
    instance_exec(source_params, &config.after_save_hook) if config.after_save_hook
  end

  # Assign validated params to the target object, adapting to its type
  def assign_to_target(target, params)
    if target.is_a?(Hash)
      params.each { |key, value| target[key] = value }
    elsif target.respond_to?(:assign_attributes)
      target.assign_attributes(params)
    else
      params.each { |key, value| target.send(:"#{key}=", value) }
    end
  end

  # Persist the target object using the configured strategy. `bang` selects
  # save!/save when falling back to the target's own persistence.
  def persist_target(target, config, bang: true)
    if config.on_save_hook
      instance_exec(target, &config.on_save_hook)
    elsif bang && target.respond_to?(:save!)
      target.save!
    elsif !bang && target.respond_to?(:save)
      target.save
    else
      raise NotImplementedError,
            "Target #{target.class} does not respond to save!/save. Define an on_save block."
    end
  end

  # Extract the source params based on the from declaration
  def extract_source(from_source)
    if from_source.to_s.start_with?('@')
      instance_variable_get(from_source)
    else
      send(from_source)
    end
  end

  # Extract the target object based on the to declaration
  def extract_target(to_target)
    if to_target.to_s.start_with?('@')
      instance_variable_get(to_target)
    else
      send(to_target)
    end
  end

  # Validate a single param based on its configuration
  #
  # @param param_config [ParamConfig] The parameter configuration
  # @param source_params [Hash] The source parameters
  # @param target_object [Object] The target object being updated
  # @param allow_nil [Boolean] Is nil an allowed value?
  # @return [Object, nil] The validated value
  # @raise [ModelMapper::InvalidValueError] If validation fails
  def validate_param(param_config, source_params, target_object, allow_nil)
    keys = param_config.keys

    value = source_params.dig(*keys)
    default_value =
      (set_default_value(value, source_params, param_config) unless param_config.default_value.nil?)

    value = smart_presence(value)
    value = smart_presence(default_value) if value.nil?
    value_blank = value.nil? || (value.respond_to?(:empty?) && value.empty?)
    raise ModelMapper::InvalidNilValueError.new(keys.join('/')) if value_blank && value != false && !allow_nil

    if value && param_config.type_value && respond_to?("valid_#{param_config.type_value}_value?", true)
      value =
        begin
          send("valid_#{param_config.type_value}_value?", value, param_config, source_params, target_object)
        rescue ModelMapper::InvalidFormatError, ModelMapper::InvalidValueError => e
          raise e unless param_config.default_on_invalid_value?

          default_value
        end
    end

    value
  end

  def valid_float_value?(value, param_config, _source_params, _target_object)
    unless value.to_s.strip.match?(/\d+\.?\d*/)
      raise ModelMapper::InvalidFormatError.new(param_config.keys.join('/'), expected_format: :float)
    end

    value.to_f
  end

  def valid_integer_value?(value, param_config, _source_params, _target_object)
    unless value.to_s.strip.match?(/^\d+$/)
      raise ModelMapper::InvalidFormatError.new(param_config.keys.join('/'),
                                                expected_format: :integer)
    end

    value.to_i
  end

  def valid_date_value?(value, param_config, _source_params, _target_object)
    Time.zone.iso8601(value)
  rescue StandardError
    raise ModelMapper::InvalidFormatError.new(param_config.keys.join('/'))
  end

  def valid_boolean_value?(value, _param_config, _source_params, _target_object)
    value.to_bool
  end

  # Validates an enumerated field (validates against a list of allowed values)
  def valid_enumerated_value?(value, param_config, source_params, _target_object)
    allowed = allowed_values(param_config, source_params)

    if value.respond_to?(:each)
      unless param_config.multiple?
        details = I18n.t('errors.invalid_value_details.single_value_only')
        raise ModelMapper::InvalidValueError.new(param_config.keys.join('/'), details:)
      end

      unless value.all? { |v| allowed.include?(v) }
        details = I18n.t('errors.invalid_value_details.invalid_enum_in_list', allowed: allowed.join(', '))
        raise ModelMapper::InvalidValueError.new(param_config.keys.join('/'), details:)
      end
    else
      unless allowed.include?(value)
        details = I18n.t('errors.invalid_value_details.invalid_enum', allowed: allowed.join(', '))
        raise ModelMapper::InvalidValueError.new(param_config.keys.join('/'), details:)
      end
    end

    value
  end

  # Validate a referential value (validates against database records)
  #
  # Special behavior: If the target object already has this value and it matches the incoming
  # value, we allow it even if it wouldn't pass the `allowing` constraint. This handles the case
  # where a reference has been disabled/soft-deleted after the record was created.
  def valid_referential_value?(value, param_config, source_params, target_object)
    # Try to validate unchanged referential value (allows disabled references)
    unchanged_result = validate_unchanged_referential_value(value, param_config, source_params, target_object)
    return unchanged_result if unchanged_result

    # Value has changed or doesn't exist, validate normally with constraints
    validate_changed_referential_value(value, param_config, source_params)
  end

  # Validates a referential value that hasn't changed on the target object.
  # Returns the record if found (even if disabled), nil if value has changed or target doesn't have it.
  def validate_unchanged_referential_value(value, param_config, source_params, target_object)
    param_name = param_config.name
    field = param_config.field_value

    return nil unless target_object.respond_to?(param_name)

    current_value = target_object.public_send(param_name)

    return nil unless current_value.to_s == value.to_s

    model = allowed_values(param_config, source_params)

    model_class = extract_model_class(model)

    return nil unless model_class

    result = model_class.unscoped.find_by(field => value)

    # If the record exists (even if disabled), return it
    # If it doesn't exist at all, raise an error
    if result
      result
    else
      details = I18n.t('errors.invalid_value_details.invalid_referential')
      raise ModelMapper::InvalidValueError.new(param_config.keys.join('/'), details:)
    end
  end

  # Validates a referential value that has changed using the `allowing` constraint.
  def validate_changed_referential_value(value, param_config, source_params)
    model = allowed_values(param_config, source_params)

    unless (defined?(ActiveRecord::Base) && model.is_a?(ActiveRecord::Base)) ||
           (defined?(ActiveRecord::Relation) && model.is_a?(ActiveRecord::Relation))
      raise ArgumentError, "Invalid model for param config #{param_config.name}"
    end

    field = param_config.field_value
    method = param_config.multiple? ? :where : :find_by

    result = model.public_send(method, field => value)

    result_blank = result.nil? || (result.respond_to?(:empty?) && result.empty?)
    if result_blank
      details = I18n.t("errors.invalid_value_details.invalid_referential#{'_in_list' if param_config.multiple?}")
      raise ModelMapper::InvalidValueError.new(param_config.keys.join('/'), details:)
    end

    result
  end

  # Extracts the base ActiveRecord model class from a model or relation.
  def extract_model_class(model)
    if defined?(ActiveRecord::Relation) && model.is_a?(ActiveRecord::Relation)
      model.klass
    elsif defined?(ActiveRecord::Base) && model.is_a?(Class) && model < ActiveRecord::Base
      model
    end
  end

  def valid_custom_value?(value, param_config, source_params, _target_object)
    instance_exec(value, source_params, &param_config.allowing_value)
  end

  def set_default_value(_value, source_params, param_config)
    if param_config.default_value.is_a?(Proc)
      case param_config.default_value.arity
      when 1
        instance_exec(source_params, &param_config.default_value)
      else
        instance_exec(&param_config.default_value)
      end
    else
      param_config.default_value
    end
  end

  def allowed_values(param_config, source_params)
    if param_config.allowing_value.is_a?(Proc)
      case param_config.allowing_value.arity
      when 1
        instance_exec(source_params, &param_config.allowing_value)
      else
        instance_exec(&param_config.allowing_value)
      end
    else
      param_config.allowing_value
    end
  end

  def smart_presence(value)
    return value if value == false
    return nil if value.nil?
    return nil if value.respond_to?(:empty?) && value.empty?

    value
  end

end

require_relative 'model_mapper/railtie' if defined?(Rails::Railtie)
