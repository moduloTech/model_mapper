# frozen_string_literal: true

module ModelMapper

  class Railtie < Rails::Railtie

    initializer 'model_mapper.i18n' do
      I18n.load_path += Dir[File.join(ModelMapper.root, 'config', 'locales', '*.yml')]
    end

  end

end
