require 'directed_edge'
require 'active_support'
require 'active_record'
require 'will_paginate'

module DirectedEdge
  module Edgy
    class << self
      attr_accessor :database, :models
    end

    def self.configure(&block)
      config = Configuration.instance
      block.call(config)
      raise "user= and password= must be set in config block" unless config.user && config.password
      Edgy.database = DirectedEdge::Database.new(config.user, config.password)
    end

    def self.included(base)
      base.send :include, Utilities
      base.send :extend, ClassMethods
      base.alias_method_chain :save, :edgy
      base.alias_method_chain :destroy, :edgy
    end

    def self.export
      throw "No acts_as_edgy models in use." if @models.blank?
      throw "Database not set." unless Edgy.database

      file = "#{Rails.root}/tmp/edgy_export.xml"
      exporter = DirectedEdge::Exporter.new(file)
      @models.each { |m| m.edgy_export(exporter) }
      exporter.finish
      Edgy.database.import(file)
    end

    def self.clear
      empty = "#{Rails.root}/tmp/edgy_empty.xml"
      DirectedEdge::Exporter.new(empty).finish unless File.exists? empty
      Edgy.database.import(empty)
    end

    def save_with_edgy(*args)
      Future.new do
        if self.class.edgy_triggers
          self.class.edgy_triggers.each do |trigger|

            ### TODO: This should use the ID from the bridge rather than just
            ### assuming foreign_key is the right one.

            trigger_id = send(trigger.name.foreign_key)
            trigger.find(trigger_id).edgy_export if trigger_id
          end
        end
      end if Configuration.instance.send_updates
      save_without_edgy(*args)
    end

    def destroy_with_edgy
      if Configuration.instance.send_updates && self.class.edgy_modeled
        Future.new { edgy_item.destroy }
      end
      destroy_without_edgy
    end

    def edgy_related(options = {})
      Future.new do
        tags = options.delete(:tags) || Set.new([ edgy_type ])
        edgy_records(edgy_item.related(tags, options))
      end
    end

    def edgy_recommended(options = {})
      Future.new do
        tags = options.delete(:tags)
        unless tags
          tags = Set.new
          self.class.edgy_routes.each { |name, c| tags.add(c.to_class.edgy_type) }
        end
        edgy_records(edgy_item.recommended(tags, options))
      end
    end

    def edgy_export
      item = edgy_item
      item.add_tag(edgy_type)

      # Create an exporter so that we make sure that all linked items exist.

      exporter = DirectedEdge::Exporter.new(Edgy.database)

      self.class.edgy_paginated_sql_each(self.class.edgy_sql_for_export(id)) do |record|
        target_id = "#{record.to_type}_#{record.to_id}"
        item.link_to(target_id, 0, record.link_type)
        target = DirectedEdge::Item.new(exporter.database, target_id)
        target.add_tag(record.to_type)
        exporter.export(target)
      end

      exporter.finish
      item.save(:overwrite => true)
    end

    private

    def edgy_records(ids)
      return [] if ids.empty?
      same_names = true
      first_name = edgy_name(ids.first)
      record_ids = ids.map { |i| same_names = false if edgy_name(i) != first_name ; edgy_id(i) }
      if same_names
        first_name.classify.constantize.find(record_ids)
      else
        ids.map { |i| edgy_record(i) }
      end
    end

    def edgy_record(item_id)
      edgy_name(item_id).classify.constantize.find(edgy_id(item_id))
    end

    def edgy_item
      DirectedEdge::Item.new(Edgy.database, "#{edgy_type}_#{id}")
    end

    class Configuration
      include Singleton
      attr_accessor :user, :password, :send_updates
      def initialize
        @send_updates = true
      end
    end

    # The utilities are small helpers that are shared between the ClassMethods
    # module and the main Edgy module.

    module Utilities
      def edgy_type
        is_a?(ActiveRecord::Base) ? self.class.name.underscore : name.underscore
      end

      def edgy_sql_for_export(for_id = nil)
        instance = is_a?(ActiveRecord::Base) ? self.class : self
        instance.edgy_routes.map { |c| c[1].sql_for_export(c[0], for_id) }.join(' union ') +
          ' order by from_id'
      end

      private

      def edgy_name(item_id)
        item_id.sub(/_.*/, '')
      end

      def edgy_id(item_id)
        item_id.sub(/.*_/, '')
      end
    end

    module ClassMethods
      include Utilities
      attr_reader :edgy_routes
      attr_accessor :edgy_triggers, :edgy_modeled

      def acts_as_edgy(name, *bridges)
        target = bridges.last

        Edgy.models ||= Set.new
        Edgy.models.add(self)
        Edgy.models.add(target)

        @edgy_modeled = true
        target.edgy_modeled = true

        trigger_from = bridges.first.is_a?(Bridge) ? bridges.first.klass : bridges.first
        trigger_from.edgy_triggers ||= Set.new
        trigger_from.edgy_triggers.add(self)

        @edgy_routes ||= {}

        if bridges.first.is_a? Bridge
          to_class =
            unless bridges.last.is_a? Bridge
              bridges.pop
            else
              edgy_name(bridges.last.to_column.to_s).classify.constantize
            end
          if bridges.first.klass != self
            bridges.insert(0, Bridge.new(self, 'id', edgy_find_method(self, bridges.first.klass)))
          end
          @edgy_routes[name] = Connection.new(self, to_class, *bridges)
        else
          @edgy_routes[name] = edgy_build_connection(self, *bridges)
        end
      end

      def edgy_export(exporter)
        if @edgy_routes
          item = nil
          edgy_paginated_sql_each(edgy_sql_for_export) do |record|
            item_id = "#{record.from_type}_#{record.from_id}"
            unless item == item_id
              exporter.export(item) if item
              item = DirectedEdge::Item.new(exporter.database, item_id)
              item.add_tag(record.from_type)
            end
            item.link_to("#{record.to_type}_#{record.to_id}", 0, record.link_type) if record.to_id
          end
          exporter.export(item) if item
        else
          find_each do |record|
            item = DirectedEdge::Item.new(exporter.database, "#{edgy_type}_#{record.id}")
            item.add_tag(edgy_type)
            exporter.export(item)
          end
        end
      end

      def edgy_paginated_sql_each(query, &block)
        page = 1
        begin
          results = paginate_by_sql(query, :page => page)
          results.each { |r| block.call(r) }
          page += 1
        end while !results.empty?
      end

      def edgy_find_method(in_class, referring_to)
        if in_class.column_names.include? referring_to.name.foreign_key
          referring_to.name.foreign_key
        else
          'id'
        end
      end

      private

      def edgy_build_connection(*classes)
        raise "There must be at least three classes in an edgy path." if classes.size < 3
        bridges = []
        first = previous = classes.first
        while classes.size > 1
          current = classes.shift
          bridges.push(Bridge.new(current,
                                  edgy_find_method(current, previous),
                                  edgy_find_method(current, classes.first)))
          previous = current
        end
        Connection.new(first, classes.last, *bridges)
      end
    end
  end

  # By default strings of classes can be used and bridges will be built
  # automatically between them based on the standard foreign keys.  However, in
  # cases where non-standard foreign keys are used, a Bridge may be explicitly
  # created.

  class Bridge
    attr_reader :klass, :from_column, :to_column
    def initialize(klass, from_column, to_column)
      @klass = klass
      @from_column = from_column
      @to_column = to_column
    end
  end

  private

  class Connection
    attr_accessor :from_class, :to_class

    def initialize(from_class, to_class, *bridges)
      @from_class = from_class
      @to_class = to_class
      @bridges = bridges
    end

    def sql_for_export(link_type, for_id = nil)
      to_column = "#{@bridges.last.klass.table_name}.#{@bridges.last.to_column}"

      what = "#{from_class.table_name}.id as from_id, "
      what << "#{quote(from_type)} as from_type, "
      what << "#{to_column} as to_id, "
      what << conditional(to_column, to_type, 'to_type') << ', '
      what << conditional(to_column, link_type, 'link_type')

      from = "#{from_class.table_name} "
      where = "#{from_class.table_name}.id " + (for_id ? "= #{for_id}" : "is not null")

      bridges = @bridges.clone
      previous = bridges.shift

      bridges.each do |bridge|
        from << "left outer join #{bridge.klass.table_name} "
        from << "on #{previous.klass.table_name}.#{previous.to_column} = "
        from << "#{bridge.klass.table_name}.#{bridge.from_column} "
        previous = bridge
      end

      "select #{what} from #{from} where #{where}"
    end

    def from_type
      from_class.edgy_type
    end

    def to_type
      to_class.edgy_type
    end

    private

    def conditional(test, value, as)
      "case when #{test} is not null then #{quote(value)} end as #{as}"
    end

    def quote(value)
      @bridges.first.klass.quote_value(value.to_s)
    end
  end

  class Future
    def initialize(&finalize)
      @future = Thread.new do
        begin
          finalize.call
        rescue => ex
          warn "Exception in background thread: #{ex}"
        end
      end
    end

    def method_missing(method, *args, &block)
      data.send(method, *args, &block)
    end

    def to_s
      data.to_s
    end

    private

    def data
      @data ||= @future.value
    end
  end

end

ActiveRecord::Base.send :include, DirectedEdge::Edgy
