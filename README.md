# ModelMapper

A declarative DSL for mapping Hash/JSON parameters to Ruby objects with type validation, referential integrity checks, combined record validation, and opt-in persistence. Designed for service objects that receive external input and need to validate, transform, and assign it to a model.

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

  # No initialize, no from/to needed: ModelMapper provides a standard initializer and `from`/`to`
  # default to the mapped `record` / `params`.
  map_model do
    record_alias :widget     # optional: expose #widget as an alias of #record

    attribute :name do
      required true
    end

    attribute :status do
      at :info, :status      # dig into nested hash
      type :enumerated
      allowing %w[active inactive archived]
    end
  end
end

widget  = Widget.find(1)
service = UpdateWidgetService.new(widget, params, user: current_user) # extra kwargs → readers
service.map_to_model!      # validate (mapper + record) + assign; raises on invalid, never persists
service.widget.save!       # persistence stays in the caller's hands (or use save_to_model!)
```

## Initialization

`include ModelMapper` provides a standard initializer — `Mapper.new(record, params, **context)`:
- `record` → the mapped object (`#record`), default target of `to`.
- `params` → the source hash (`#params`), default source of `from`.
- every extra keyword becomes an ivar + reader (e.g. `user:` ⇒ `#user`), so mappers can carry
  context (scoping, the current user, …) without a custom initializer.

A class may still define its own `initialize` (and call `super`). `record_alias :name` exposes an
alias of `#record` (e.g. `#widget`, `#mission`) for readability.

## DSL: `map_model`

The `map_model` block configures the mapping. It is evaluated at the class level.

### `from` / `to`

**Optional** — they default to `:@params` and `:@record` (the standard initializer's `params` /
`record`). Declare them only to read/write elsewhere.

```ruby
map_model do
  from :@params   # instance variable (default)
  from :params    # method call

  to :widget      # method call
  to :@widget     # instance variable
end
```

Both accept a Symbol. Symbols starting with `@` are resolved as instance variables; others are sent as method calls on the service instance.

### Associations: `type :association` (1‑1) and `type :array` (1‑N)

Map nested objects through their own sub-mappers, à la Blueprinter. The attribute name is the
association's nested-attributes name (`vehicle_attributes` ⇒ association `vehicle`); the sub-record
is built on the target association and validated by its sub-mapper.

```ruby
map_model do
  attribute :vehicle_attributes do      # 1‑1 (belongs_to / has_one)
    at :vehicle
    type :association
    mapper VehicleMapper
  end

  attribute :missions_attributes do     # 1‑N (has_many)
    at :missions
    type :array
    mapper MissionMapper, with: -> { { company: @company, user: user } }
  end
end
```

- **`mapper`** — the sub-mapper class (itself an `include ModelMapper`).
- **`with:`** — a lambda evaluated in the parent mapper to build the sub-mapper's keyword context
  (so derived values like a scoped company flow down). Optional.
- Sub-mapper errors are merged into the parent under dotted, path-prefixed keys: `vehicle.immat`,
  `missions.0.driver`. Each association's records are validated by its sub-mapper, so the parent does
  not double-report them. An absent payload section is not built; a present-but-empty `{}` is built
  and validated (its required sub-fields then surface).

### Arrays of scalars: `type :array` + `of`

`type :array` always needs an **explicit, mandatory** element strategy — `mapper` (array of records,
above) or `of` (array of scalars). Declaring `type :array` with neither, with both, or `of` outside
an array raises `ModelMapper::ConfigurationError` on the first map.

`of` names the element type, validated/coerced per element through the same machinery as the scalar
types: `:referential`, `:string`, `:integer`, `:float`, `:date`, `:boolean`, `:enumerated`,
`:custom`, or `:any` (accept elements unchanged). Validation fails fast on the first bad element, with
an indexed field path (e.g. `numbers.2`).

```ruby
attribute :numbers do
  type :array
  of :integer                 # ["1","2"] => [1, 2]; a non-integer element => "numbers.<i>" error
end

attribute :statuses do
  type :array
  of :enumerated
  allowing %w[open closed]    # the attribute's `allowing` is applied to each element
end

attribute :category_ids do
  at :categories
  type :array
  of :referential
  allowing Category.all       # each element looked up; assigned as an array of ids
end
```

- The attribute's `allowing` / `field` apply to every element (so `:referential` / `:enumerated`
  elements share one scope).
- `of :referential` assigns the array of resolved **ids** (mirroring the scalar referential).
- An empty array is treated as blank (like any empty value): dropped when optional, an error when
  `required`.

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
2. -- attribute validation loop (mapper rules) --
   -- if any mapper error: STOP here (target not assembled) --
3. before_assignation(source_params, validated_params)
4. -- assign_attributes --
5. -- record validation (target.valid?), merged into the combined errors --
6. before_save(source_params)           # only with save_to_model / save_to_model!
7. -- persist (save/save!/on_save) --   # only with save_to_model / save_to_model!
8. after_save(source_params)            # only with save_to_model / save_to_model!
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

## Entry points

Four methods. They all run **combined validation** first (mapper rules, then the
target's own `valid?` — see below). The `map_*` variants never persist; the
`save_*` variants persist explicitly (opt-in). The `!` variants raise; the
non-bang variants collect errors instead.

```ruby
map_to_model    # validate + assign;        non-raising → read #errors / #valid?
map_to_model!   # validate + assign;        raises ModelMapper::ValidationError if invalid
save_to_model   # validate + assign + save  (skipped when invalid); non-raising
save_to_model!  # validate + assign + save! ; raises if invalid or on save failure
```

After a non-bang call, inspect the result on the mapper instance:

```ruby
service = UpdateWidgetService.new(widget, params)
service.map_to_model
service.valid?   # => false
service.errors   # => { "name" => #<ModelMapper::RecordError ...> }
```

### Class-method shortcuts

Each entry point has a class-method shortcut that builds the mapper (forwarding the initializer
arguments) and runs it in one call, returning the mapper instance:

```ruby
service = UpdateWidgetService.map_to_model!(widget, params)
# equivalent to:
service = UpdateWidgetService.new(widget, params).tap(&:map_to_model!)

service.widget   # your own accessor
service.errors   # combined errors (non-bang variants)
```

`map_to_model` / `map_to_model!` / `save_to_model` / `save_to_model!` all have a shortcut; the `!`
variants raise exactly like their instance counterparts.

## Combined validation

ModelMapper rules and the target's own validations are reported **together, at
once**, in one pass and one error shape — no separate `save!`-then-rescue step,
and no "fix the mapper errors first, then discover the model errors" round-trips.

The model is expected to carry **the bulk** of the validations; ModelMapper only
adds the rules a model cannot express (payload shape, referential checks against
a scope). On every call the mapper rules run **and** the target is assembled and
`target.valid?` is run, so both error sets come back in the same
`ModelMapper::ValidationError` (record errors wrapped as `ModelMapper::RecordError`,
one entry per attribute). A field already reported by a mapper rule is **not**
duplicated by the record error (the mapper owns the more specific rule).

This keeps ActiveRecord as the source of truth for everything it *can* express,
with ModelMapper layered on top only for what it can't.

> Note: the target is assembled and validated even when the mapper already found errors, so a
> `before_assignation` hook runs on the validated *subset* — write it to tolerate partial data
> (don't dereference a referential that may have failed to map).

## Persistence

The `save_*` methods persist; the `map_*` methods never do. Persistence strategy
(in order of priority):

1. `on_save` hook if defined — replaces the default save
2. `target.save!` (from `save_to_model!`) / `target.save` (from `save_to_model`) if the target responds to it
3. Raises `NotImplementedError` otherwise

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
  map_to_model!
rescue ModelMapper::ValidationError => e
  e.errors      # => { "name" => #<InvalidNilValueError>, "quantity" => #<InvalidFormatError> }
  e.fields      # => ["name", "quantity"]
  e.first_error # => #<InvalidNilValueError>
  e.message     # => "name: ...; quantity: ..."
end
```

The same applies to record (ActiveRecord) errors once mapping is clean — they are
merged into the same `ValidationError` as `ModelMapper::RecordError` entries.

Attributes that validated successfully still have their instance variables set, even when the overall validation fails.

## Errors

```
RuntimeError
  |-- ModelMapper::InvalidValueError        # value not in allowed set
  |     |-- ModelMapper::InvalidNilValueError  # required value is nil/blank
  |-- ModelMapper::InvalidFormatError       # wrong format (float, integer, date)
  |-- ModelMapper::RecordError              # wraps the target's own (ActiveRecord) error(s) for an attribute
  |-- ModelMapper::ValidationError          # wraps all errors (mapper + record) from a single call
```

All errors expose a `field` attribute (String, dot-separated key path like `"infraction.zone.id"`; nested associations/arrays use `"vehicle.immat"`, `"missions.0.driver"`).

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
