require 'rubygems'
%w(will_paginate formtastic inherited_resources).each do |lib|
  begin
    require lib
  rescue MissingSourceFile
    eval("#{lib.upcase} = #{false}")
  else
    eval("#{lib.upcase} = #{true}")
  end
end

class DryScaffoldGenerator < Rails::Generator::NamedBase
  
  # Load defaults from config file - default or custom.
  begin
    default_config_file = File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'config', 'scaffold.yml'))
    custom_config_file = File.expand_path(File.join(Rails.root, 'config', 'scaffold.yml'))
    config_file = File.join(File.exist?(custom_config_file) ? custom_config_file : default_config_file)
    config = YAML::load(File.open(config_file))
    CONFIG_ARGS = config['dry_scaffold']['args'] rescue nil
    CONFIG_OPTIONS = config['dry_scaffold']['options'] rescue nil
  end
  
  DEFAULT_ARGS = {
      :actions => (CONFIG_ARGS['actions'].split(',').compact.uniq.collect { |v| v.downcase.to_sym } rescue nil),
      :formats => (CONFIG_ARGS['formats'].split(',').compact.uniq.collect { |v| v.downcase.to_sym } rescue nil)
    }
    
  DEFAULT_OPTIONS = {
      :resourceful => CONFIG_OPTIONS['resourceful'] || INHERITED_RESOURCES,
      :formtastic => CONFIG_OPTIONS['formtastic'] || FORMTASTIC,
      :pagination => CONFIG_OPTIONS['pagination'] || WILL_PAGINATE,
      :skip_tests => !CONFIG_OPTIONS['tests'] || false,
      :skip_helpers => !CONFIG_OPTIONS['helpers'] || false,
      :skip_views => !CONFIG_OPTIONS['views'] || false,
      :layout => CONFIG_OPTIONS['layout'] || false
    }
    
  # Formats.
  DEFAULT_RESPOND_TO_FORMATS =          [:html, :xml, :json].freeze
  ENHANCED_RESPOND_TO_FORMATS =         [:yml, :yaml, :txt, :text, :atom, :rss].freeze
  RESPOND_TO_FEED_FORMATS =             [:atom, :rss].freeze
  
  # Actions.
  DEFAULT_MEMBER_ACTIONS =              [:show, :new, :edit, :create, :update, :destroy].freeze
  DEFAULT_MEMBER_AUTOLOAD_ACTIONS =     (DEFAULT_MEMBER_ACTIONS - [:new, :create])
  DEFAULT_COLLECTION_ACTIONS =          [:index].freeze
  DEFAULT_COLLECTION_AUTOLOAD_ACTIONS = DEFAULT_COLLECTION_ACTIONS
  DEFAULT_CONTROLLER_ACTIONS =          (DEFAULT_COLLECTION_ACTIONS + DEFAULT_MEMBER_ACTIONS)
  
  DEFAULT_VIEW_TEMPLATE_FORMAT =        :haml
  DEFAULT_TEST_FRAMEWORK =              :test_unit
  
  CONTROLLERS_PATH =      File.join('app', 'controllers').freeze
  HELPERS_PATH =          File.join('app', 'helpers').freeze
  VIEWS_PATH =            File.join('app', 'views').freeze
  LAYOUTS_PATH =          File.join(VIEWS_PATH, 'layouts').freeze
  MODELS_PATH =           File.join('app', 'models').freeze
  FUNCTIONAL_TESTS_PATH = File.join('test', 'functional').freeze
  UNIT_TESTS_PATH =       File.join('test', 'unit').freeze
  ROUTES_FILE_PATH =      File.join(Rails.root, 'config', 'routes.rb').freeze
  
  RESOURCEFUL_COLLECTION_NAME = 'collection'.freeze
  RESOURCEFUL_SINGULAR_NAME =   'resource'.freeze
  
  NON_ATTR_ARG_KEY_PREFIX =     '_'.freeze
  
  # :{action} => [:{partial}, ...]
  ACTION_VIEW_TEMPLATES = {
      :index  => [:item],
      :show   => [],
      :new    => [:form],
      :edit   => [:form]
    }.freeze
  
  ACTION_FORMAT_BUILDERS = {
      :index => [:atom, :rss]
    }
    
  attr_reader   :controller_name,
                :controller_class_path,
                :controller_file_path,
                :controller_class_nesting,
                :controller_class_nesting_depth,
                :controller_class_name,
                :controller_underscore_name,
                :controller_singular_name,
                :controller_plural_name,
                :collection_name,
                :model_singular_name,
                :model_plural_name,
                :view_template_format,
                :test_framework,
                :actions,
                :formats,
                :config
                
  alias_method  :controller_file_name, :controller_underscore_name
  alias_method  :controller_table_name, :controller_plural_name
  
  def initialize(runtime_args, runtime_options = {})
    super
    
    @controller_name = @name.pluralize
    base_name, @controller_class_path, @controller_file_path, @controller_class_nesting, @controller_class_nesting_depth = extract_modules(@controller_name)
    @controller_class_name_without_nesting, @controller_underscore_name, @controller_plural_name = inflect_names(base_name)
    @controller_singular_name = base_name.singularize
    
    if @controller_class_nesting.empty?
      @controller_class_name = @controller_class_name_without_nesting
    else
      @controller_class_name = "#{@controller_class_nesting}::#{@controller_class_name_without_nesting}"
    end
    
    @view_template_format = DEFAULT_VIEW_TEMPLATE_FORMAT
    @test_framework = DEFAULT_TEST_FRAMEWORK
    
    @attributes ||= []
    @args_for_model ||= []
    
    # Non-attribute args, i.e. "_actions:new,create".
    @args.each do |arg|
      arg_entities = arg.split(':')
      if arg =~ /^#{NON_ATTR_ARG_KEY_PREFIX}/
        if arg =~ /^#{NON_ATTR_ARG_KEY_PREFIX}action/
          # Replace quantifiers with default actions
          arg_entities[1].gsub!(/\*/, DEFAULT_CONTROLLER_ACTIONS.join(','))
          arg_entities[1].gsub!(/new\+/, [:new, :create].join(','))
          arg_entities[1].gsub!(/edit\+/, [:edit, :update].join(','))
          
          arg_actions = arg_entities[1].split(',').compact.uniq
          @actions = arg_actions.collect { |action| action.downcase.to_sym }
        elsif arg =~ /^#{NON_ATTR_ARG_KEY_PREFIX}(format|respond_to)/
          # Replace quantifiers with default respond_to-formats
          arg_entities[1].gsub!(/\*/, DEFAULT_RESPOND_TO_FORMATS.join(','))
          
          arg_formats = arg_entities[1].split(',').compact.uniq
          @formats = arg_formats.collect { |format| format.downcase.to_sym }
        elsif arg =~ /^#{NON_ATTR_ARG_KEY_PREFIX}index/
          @args_for_model << arg
        end
      else
        @attributes << Rails::Generator::GeneratedAttribute.new(*arg_entities)
        @args_for_model << arg
      end
    end
    
    @actions ||= DEFAULT_ARGS[:actions] || DEFAULT_CONTROLLER_ACTIONS
    @formats ||= DEFAULT_ARGS[:formats] || DEFAULT_RESPOND_TO_FORMATS
    @options = DEFAULT_OPTIONS.merge(options)
  end
  
  def manifest
    record do |m|
      # Check for class naming collisions.
      m.class_collisions "#{controller_class_name}Controller", "#{controller_class_name}ControllerTest"
      m.class_collisions "#{controller_class_name}Helper", "#{controller_class_name}HelperTest"
      
      # Directories.
      m.directory File.join(CONTROLLERS_PATH, controller_class_path)
      m.directory File.join(HELPERS_PATH, controller_class_path) unless options[:skip_helpers]
      m.directory File.join(VIEWS_PATH, controller_class_path, controller_file_name) unless options[:skip_views]
      m.directory File.join(FUNCTIONAL_TESTS_PATH, controller_class_path) unless options[:skip_tests]
      m.directory File.join(UNIT_TESTS_PATH, 'helpers', controller_class_path) unless options[:skip_tests] || options[:skip_helpers]
      
      # Controllers.
      controller_template = options[:resourceful] ? 'inherited_resources' : 'action'
      m.template File.join('controllers', "#{controller_template}_controller.rb"),
        File.join(CONTROLLERS_PATH, controller_class_path, "#{controller_file_name}_controller.rb")
        
      # Controller Tests.
      unless options[:skip_tests]
        m.template File.join('controllers', 'tests', "#{test_framework}", 'functional_test.rb'),
          File.join(FUNCTIONAL_TESTS_PATH, controller_class_path, "#{controller_file_name}_controller_test.rb")
      end
      
      # Helpers.
      unless options[:skip_helpers]
        m.template File.join('helpers', 'helper.rb'),
          File.join(HELPERS_PATH, controller_class_path, "#{controller_file_name}_helper.rb")
          
        # Helper Tests
        unless options[:skip_tests]
          m.template File.join('helpers', 'tests', "#{test_framework}", 'unit_test.rb'),
            File.join(UNIT_TESTS_PATH, 'helpers', controller_class_path, "#{controller_file_name}_helper_test.rb")
        end
      end
      
      # Views.
      unless options[:skip_views]
        # View template for each action.
        (actions & ACTION_VIEW_TEMPLATES.keys).each do |action|
          m.template File.join('views', "#{view_template_format}", "#{action}.html.#{view_template_format}"),
            File.join(VIEWS_PATH, controller_file_name, "#{action}.html.#{view_template_format}")
            
          # View template for each partial - if not already copied.
          (ACTION_VIEW_TEMPLATES[action] || []).each do |partial|
            m.template File.join('views', "#{view_template_format}", "_#{partial}.html.#{view_template_format}"),
              File.join(VIEWS_PATH, controller_file_name, "_#{partial}.html.#{view_template_format}")
          end
        end
      end
      
      # Builders.
      unless options[:skip_builders]
        (actions & ACTION_FORMAT_BUILDERS.keys).each do |action|
          (formats & ACTION_FORMAT_BUILDERS[action] || []).each do |format|
            m.template File.join('views', 'builder', "#{action}.#{format}.builder"),
              File.join(VIEWS_PATH, controller_file_name, "#{action}.#{format}.builder")
          end
        end
      end
      
      # Layout.
      if options[:layout]
        m.template File.join('views', "#{view_template_format}", "layout.html.#{view_template_format}"),
          File.join(LAYOUTS_PATH, "#{controller_file_name}.html.#{view_template_format}")
      end
      
      # Routes.
      unless resource_route_exists?
        m.route_resources controller_file_name
      end
      
      # Models - use Rails default generator.
      m.dependency 'dry_model', [name] + @args_for_model, options.merge(:collision => :skip)
    end
  end
  
  def collection_instance
    "@#{collection_name}"
  end
  
  def resource_instance
    "@#{singular_name}"
  end
  
  def index_link
    "#{collection_name}_url"
  end
  
  def new_link
    "new_#{singular_name}_url"
  end
  
  def show_link(object_name = resource_instance)
    "#{singular_name}_url(#{object_name})"
  end
  
  def edit_link(object_name = resource_instance)
    "edit_#{show_link(object_name)}"
  end
  
  def destroy_link(object_name = resource_instance)
    "#{object_name}"
  end
  
  def feed_link(format)
    case format
    when :atom then
      ":href => #{plural_name}_url(:#{format}), :rel => 'self'"
    when :rss then
      "#{plural_name}_url(#{singular_name}, :#{format})"
    end
  end
  
  def feed_entry_link(format)
    case format
    when :atom then
      ":href => #{singular_name}_url(#{singular_name}, :#{format})"
    when :rss then
      "#{singular_name}_url(#{singular_name}, :#{format})"
    end
  end
  
  def feed_date(format)
    case format
    when :atom then
      "(#{collection_instance}.first.created_at rescue Time.now.utc).strftime('%Y-%m-%dT%H:%M:%SZ')"
    when :rss then
      "(#{collection_instance}.first.created_at rescue Time.now.utc).to_s(:rfc822)"
    end
  end
  
  def feed_entry_date(format)
    case format
    when :atom then
      "#{singular_name}.try(:updated_at).strftime('%Y-%m-%dT%H:%M:%SZ')"
    when :rss then
      "#{singular_name}.try(:updated_at).to_s(:rfc822)"
    end
  end
  
  protected
    
    def resource_route_exists?
      route_exp = "map.resources :#{controller_file_name}"
      File.read(ROUTES_FILE_PATH) =~ /(#{route_exp.strip}|#{route_exp.strip.tr('\'', '\"')})/
    end
    
    def symbol_array_to_expression(array)
      ":#{array.compact.join(', :')}" if array.present?
    end
    
    def assign_names!(name)
      super
      @model_singular_name = @singular_name
      @model_plural_name = @plural_name
      @collection_name = options[:resourceful] ? RESOURCEFUL_COLLECTION_NAME : @model_plural_name
      @singular_name = options[:resourceful] ? RESOURCEFUL_SINGULAR_NAME : @model_singular_name
      @plural_name = options[:resourceful] ? RESOURCEFUL_SINGULAR_NAME.pluralize : @model_plural_name
    end
    
    def add_options!(opt)
      opt.separator ''
      opt.separator 'Options:'
      
      ### CONTROLLERS + VIEWS
      
      opt.on('--skip-pagination',
        "Skip 'will_paginate' for collections in controllers and views, wich requires gem 'mislav-will_paginate'.") do |v|
        options[:pagination] = !v
      end
      
      opt.on('--skip-resourceful',
        "Skip 'inherited_resources' style controllers and views, wich requires gem 'josevalim-inherited_resources'.") do |v|
        options[:resourceful] = !v
      end
      
      opt.on('--skip-formtastic',
        "Skip 'formtastic' style forms, wich requires gem 'justinfrench-formtastic'.") do |v|
        options[:formtastic] = !v
      end
      
      opt.on('--layout', "Generate layout.") do |v|
        options[:layout] = v
      end
      
      opt.on('--skip-views', "Skip generation of views.") do |v|
        options[:skip_views] = v
      end
      
      opt.on('--skip-helper', "Skip generation of helpers.") do |v|
        options[:skip_helpers] = v
      end
      
      opt.on('--skip-builders', "Skip generation of helpers.") do |v|
        options[:skip_builders] = v
      end
      
      ### CONTROLLERS + MODELS
      
      opt.on('--skip-tests', "Skip generation of tests.") do |v|
        options[:skip_tests] = v
      end
      
      ### MODELS ONLY
      
      opt.on('--fixtures', "Model: Generate fixtures.") do |v|
        options[:fixtures] = v
      end
      
      opt.on('--fgirl', "Model: Generate \"factory_girl\" factories.") do |v|
        options[:factory_girl] = v
      end
      
      opt.on('--machinist', "Model: Generate \"machinist\" blueprints (factories).") do |v|
        options[:machinist] = v
      end
      
      opt.on('--odaddy', "Model: Generate \"object_daddy\" generator/factory methods.") do |v|
        options[:object_daddy] = v
      end
      
      opt.on('--skip-timestamps', "Model: Don't add timestamps to the migration file.") do |v|
        options[:skip_timestamps] = v
      end
      
      opt.on('--skip-migration', "Model: Skip generation of migration file.") do |v|
        options[:skip_migration] = v
      end
    end
    
    def banner
      ["Usage: #{$0} #{spec.name} ModelName",
        "[field:type field:type ...]",
        "[_actions:new,create,...]",
        "[_formats:html,json,...]",
        "[_indexes:field,field+field,field,...]",
        "[--skip-pagination]",
        "[--skip-resourceful]",
        "[--skip-formtastic]",
        "[--skip-views]", 
        "[--skip-helpers]",
        "[--skip-tests]",
        "[--skip-builders]",
        "[--layout]",
        "[--fixtures]",
        "[--factory_girl]",
        "[--machinist]",
        "[--object_daddy]",
        "[--skip-timestamps]",
        "[--skip-migration]"
      ].join(' ')
    end
    
end