# frozen_string_literal: true

module ModelMapper

  # Configuration for the mapping DSL
  class Config

    attr_accessor :from_source, :to_target, :before_assignation_hook, :before_validation_hook,
                  :before_save_hook, :after_save_hook, :on_save_hook
    attr_reader :params

    def initialize(parent_config = nil)
      if parent_config
        @params = parent_config.params.transform_values(&:dup)
        @from_source = parent_config.from_source
        @to_target = parent_config.to_target
        @before_assignation_hook = parent_config.before_assignation_hook
        @before_validation_hook = parent_config.before_validation_hook
        @before_save_hook = parent_config.before_save_hook
        @after_save_hook = parent_config.after_save_hook
        @on_save_hook = parent_config.on_save_hook
        @record_alias = parent_config.record_alias
      else
        @params = {}
        @from_source = nil
        @to_target = nil
        @before_assignation_hook = nil
        @before_validation_hook = nil
        @before_save_hook = nil
        @after_save_hook = nil
        @on_save_hook = nil
        @record_alias = nil
      end
    end

    # DSL methods callable within map_model block

    def from(value)
      @from_source = value
    end

    def to(value)
      @to_target = value
    end

    def before_assignation(&block)
      @before_assignation_hook = block
    end

    def before_validation(&block)
      @before_validation_hook = block
    end

    def before_save(&block)
      @before_save_hook = block
    end

    def after_save(&block)
      @after_save_hook = block
    end

    def on_save(&block)
      @on_save_hook = block
    end

    def attribute(name, &block)
      # Get existing attribute config (from parent) or create new one
      @params[name] ||= ParamConfig.new(name)

      # If a block is provided, create a new config and merge it
      if block
        new_config = ParamConfig.new(name)
        new_config.instance_eval(&block)
        @params[name].merge!(new_config)
      end

      @params[name]
    end

    # Alias for the mapped-record accessor (e.g. `record_alias :mission` ⇒ #mission == #record).
    # Dual-purpose: with an argument it sets the alias (DSL); without it, it reads it.
    def record_alias(name = nil)
      name ? (@record_alias = name) : @record_alias
    end

    # from/to are optional: they default to the standard initializer's @params / @record.
    def validate!
      @from_source ||= :@params
      @to_target   ||= :@record
    end

  end

end
