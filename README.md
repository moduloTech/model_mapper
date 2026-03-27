# ModelMapper

A declarative DSL for mapping Hash/JSON parameters to Ruby objects with type validation, referential integrity checks, and optional persistence. Designed for service objects that receive external input and need to validate, transform, and assign it to a model.

## Installation

```ruby
# Gemfile
gem 'model_mapper', git: 'https://github.com/moduloTech/model_mapper.git'
```

When used in a Rails application, the Railtie is auto-loaded and registers the gem's I18n locale files automatically.

## Quick Start

```ruby
class UpdateWidgetService
  include ModelMapper

  attr_reader :widget, :params

  def initialize(widget, params)
    @widget = widget
    @params = params
  end

  map_model do
    from :@params          # source hash (instance variable)
    to   :widget           # target object (method or ivar)

    attribute :name do
      required true
    end

    attribute :status do
      at :info, :status    # dig into nested hash
      type :enumerated
      allowing %w[active inactive archived]
    end
  end

  def call
    map_to_model(save: true)
  end
end

widget = Widget.find(1)
UpdateWidgetService.new(widget, params).call
```

## DSL: `map_model`

The `map_model` block configures the mapping. It is evaluated at the class level.

### `from` / `to`

Declare where to read input and where to write output.

```ruby
map_model do
  from :@params   # instance variable
  from :params    # method call

  to :widget      # method call
  to :@widget     # instance variable
end
```

Both accept a Symbol. Symbols starting with `@` are resolved as instance variables; others are sent as method calls on the service instance.

### `attribute`

Declares a parameter to validate and map. Without a block, it reads `source[name]` and assigns it directly to the target.

```ruby
attribute :name                       # simple pass-through
attribute :zone_id do                 # with options
  at :infraction, :zone, :id
  type :referential
  allowing Zone.enabled
  required true
end
```

## Attribute Options

| Option | Type | Default | Description |
|---|---|---|---|
| `at` | `*keys` | `[name]` | Key path for `Hash#dig` into the source params |
| `type` | Symbol | `nil` | Validation type (see below) |
| `allowing` | various | `nil` | Allowed values — Array, AR scope, or lambda |
| `required` | Bool / Proc | `false` | Whether `nil`/blank raises an error |
| `field` | Symbol | `:id` | Lookup field for `:referential` type |
| `multiple` | Bool | `false` | Accept an array of values |
| `save` | Bool | `true` | Include in `assign_attributes`; `false` = validate-only |
| `default` | value / Proc | `nil` | Fallback when the source value is `nil`/missing |
| `default_on_invalid` | Bool | `false` | Use `default` when validation fails instead of raising |
| `condition` | Proc | `nil` | Lambda controlling whether the attribute is processed |

### `required`

Accepts `true`, `false`, or a lambda:

```ruby
required true
required ->(params) { params[:code].nil? }
required ->(params, target) { target.new_record? }
```

### `default`

Accepts a static value or a lambda:

```ruby
default 'active'
default -> { Time.current }
default ->(params) { params[:fallback_name] }
```

### `condition`

Controls whether the attribute is processed at all. The lambda is executed via `instance_exec` on the service instance, so it can access instance variables.

```ruby
attribute :status do
  condition -> { @include_status }
end

# With arguments:
condition ->(target) { target.new_record? }
condition ->(target, source_params) { source_params.key?(:status) }
```

## Validation Types

### `:enumerated`

Validates the value against a list of allowed values.

```ruby
attribute :status do
  type :enumerated
  allowing %w[active inactive archived]
end

# With multiple values:
attribute :tags do
  type :enumerated
  allowing %w[urgent normal low]
  multiple true
end
```

### `:referential`

Looks up an ActiveRecord record by the given value. The `allowing` scope constrains which records are valid.

```ruby
attribute :zone_id do
  at :zone, :id
  type :referential
  allowing Zone.enabled
end

# Lookup by a custom field:
attribute :category_id do
  at :category, :name
  type :referential
  field :name
  allowing Category.enabled
end
```

**Unchanged-value tolerance**: If the target already has the same value (e.g. `widget.category_id == params[:category][:id]`), the record is allowed even if it no longer matches the `allowing` scope (e.g. soft-deleted). This prevents errors when re-saving unchanged associations.

### `:custom`

Passes the value through a lambda for arbitrary validation/transformation. The lambda receives `(value, source_params)` and is executed via `instance_exec`.

```ruby
attribute :code do
  type :custom
  allowing ->(value, _params) { value.upcase }
end
```

Return the transformed value. Raise `ModelMapper::InvalidValueError` to reject.

### `:float`

Validates and converts to `Float`.

```ruby
attribute :price do
  type :float
end
```

### `:integer`

Validates and converts to `Integer`. Rejects non-integer strings (e.g. `"12.5"`).

```ruby
attribute :quantity do
  type :integer
end
```

### `:date`

Parses via `Time.zone.iso8601`. Raises `InvalidFormatError` on failure.

```ruby
attribute :scheduled_at do
  type :date
end
```

### `:boolean`

Converts via `.to_bool` (truthy/falsy string conversion).

```ruby
attribute :active do
  type :boolean
end
```

## Hooks

Hooks are declared inside the `map_model` block and executed via `instance_exec` on the service instance.

### Execution Order

```
1. before_validation(source_params, target_object)
2. -- attribute validation loop --
3. before_assignation(source_params, validated_params)
4. -- assign_attributes --
5. before_save(source_params)           # only with save: true
6. -- persist (save!/on_save) --        # only with save: true
7. after_save(source_params)            # only with save: true
```

### Signatures

```ruby
map_model do
  before_validation do |source_params, target_object|
    # Runs before the validation loop. Modify source or target in-place.
  end

  before_assignation do |source_params, validated_params|
    # Runs after validation, before assign_attributes.
    # validated_params is a Hash you can mutate.
  end

  before_save do |source_params|
    # Runs before persistence.
  end

  after_save do |source_params|
    # Runs after persistence.
  end

  on_save do |target|
    # Replaces the default target.save! call.
    target.update_columns(...)
  end
end
```

## Persistence

By default, `map_to_model` only validates and assigns attributes without saving:

```ruby
map_to_model              # validate + assign only
map_to_model(save: true)  # validate + assign + persist
```

Persistence strategy (in order of priority):

1. `on_save` hook if defined — replaces the default save
2. `target.save!` if the target responds to it
3. `target.save` if the target responds to it
4. Raises `NotImplementedError` otherwise

### Supported Targets

| Target type | Assignment | Default persistence |
|---|---|---|
| ActiveRecord model | `assign_attributes` | `save!` |
| Hash | `target[key] = value` | Requires `on_save` |
| PORO / Struct | `target.name = value` | Requires `on_save` |

## Instance Variables

After validation, each attribute value is stored as an instance variable on the service:

```ruby
attribute :name    # -> @name = validated_value
```

For `:referential` attributes ending in `_id`, both the ID and the record are stored:

```ruby
attribute :category_id do
  type :referential
  allowing Category.enabled
end
# -> @category_id = record.id
# -> @category    = record
```

Attributes with `save: false` are still stored as instance variables — they are only excluded from `assign_attributes`.

## Inheritance

Subclasses inherit and can selectively override parent attributes:

```ruby
class ParentService
  include ModelMapper

  map_model do
    from :@params
    to :widget

    attribute :name
    attribute :status do
      type :enumerated
      allowing %w[active inactive]
    end
  end
end

class ChildService < ParentService
  map_model do
    attribute :status do
      required true        # adds required; type + allowing are inherited
    end
    attribute :code         # new attribute
  end
end
```

The child config is a deep copy — changes do not affect the parent.

## Multi-Error Validation

When multiple attributes fail validation, all errors are collected and raised together in a single `ValidationError`:

```ruby
begin
  map_to_model(save: true)
rescue ModelMapper::ValidationError => e
  e.errors      # => { "name" => #<InvalidNilValueError>, "quantity" => #<InvalidFormatError> }
  e.fields      # => ["name", "quantity"]
  e.first_error # => #<InvalidNilValueError>
  e.message     # => "name: ...; quantity: ..."
end
```

Attributes that validated successfully still have their instance variables set, even when the overall validation fails.

## Errors

```
RuntimeError
  |-- ModelMapper::InvalidValueError        # value not in allowed set
  |     |-- ModelMapper::InvalidNilValueError  # required value is nil/blank
  |-- ModelMapper::InvalidFormatError       # wrong format (float, integer, date)
  |-- ModelMapper::ValidationError          # wraps multiple errors from a single map_to_model call
```

All errors expose a `field` attribute (String, slash-separated key path like `"infraction/zone/id"`).

`ValidationError` exposes:
- `errors` — `Hash<String, Error>` of field => error
- `fields` — `Array<String>` of failed field names
- `first_error` — the first collected error

## Tests

```bash
cd vendor/model_mapper
bundle install
bundle exec rake test
```
