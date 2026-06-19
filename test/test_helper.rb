# frozen_string_literal: true

require 'minitest/autorun'
require 'active_record'
require 'i18n'

# Setup in-memory SQLite database
ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
ActiveRecord::Schema.define do
  create_table :widgets, force: true do |t|
    t.string :name
    t.integer :category_id
    t.string :status
    t.float :price
    t.integer :quantity
    t.boolean :active
    t.string :code
  end

  create_table :categories, force: true do |t|
    t.string :name
    t.boolean :enabled, default: true
  end
end

# Load i18n
I18n.load_path += Dir[File.join(File.expand_path('../../config/locales', __FILE__), '*.yml')]
I18n.default_locale = :en

# Minimal to_bool extension (normally provided by the host app)
class String
  TRUE_VALUES = %w[true 1 yes on t].freeze

  def to_bool
    TRUE_VALUES.include?(strip.downcase)
  end
end

class Object
  def to_bool
    !!self
  end
end

require 'model_mapper'

# Test models
class Category < ActiveRecord::Base
  scope :enabled, -> { where(enabled: true) }
end

class Widget < ActiveRecord::Base
  belongs_to :category, optional: true
end

# Same table as Widget, but with its own ActiveRecord validations — used to
# exercise the combined (mapper + record) validation path.
class StrictWidget < ActiveRecord::Base
  self.table_name = 'widgets'
  belongs_to :category, optional: true

  validates :name, presence: true
  validates :status, inclusion: { in: %w[active inactive archived] }, allow_nil: true
end
