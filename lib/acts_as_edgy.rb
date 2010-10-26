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
      base.send :alias_method, :pre_edgy_save, :save
      base.alias_method_chain :save, :edgy
    end

    def self.export
      throw "No acts_as_edgy models in use." if @models.blank?
      throw "Database not set." unless Edgy.database

      file = "#{Rails.root}/tmp/edgy_export.xml"
      exporter = DirectedEdge::Exporter.new(file)
      @models.each { |m| m.edgy_export(exporter) }
      exporter.finish

      self.clear
      Edgy.database.import(file)
    end

    def self.clear
      empty = "#{Rails.root}/tmp/edgy_empty.xml"
      DirectedEdge::Exporter.new(empty).finish unless File.exists? empty
      Edgy.database.import(empty)
    end

    def save_with_edgy(*args)
      save_without_edgy(*args)
    end

    def edgy_related(options = {})
      item_type = self.class.name.underscore
      tags = options.delete(:tags) || Set.new([ item_type ])
      item = DirectedEdge::Item.new(Edgy.database, "#{item_type}_#{id}")
      edgy_records(item.related(tags, options))
    end

    def edgy_recommended(options = {})
      item_type = self.class.name.underscore
      tags = options.delete(:tags)
      unless tags
        tags = Set.new
        self.class.edgy_connections.each { |c| tags.add(c.to_class.name.underscore) }
      end
      item = DirectedEdge::Item.new(Edgy.database, "#{item_type}_#{id}")
      edgy_records(item.recommended(tags, options))
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

    class Configuration
      include Singleton
      attr_accessor :user, :password
    end

    module Utilities
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
      attr_reader :edgy_connections

      def acts_as_edgy(name, *bridges)
        @edgy_routes ||= {}
        Edgy.models ||= Set.new
        Edgy.models.add(self)

        if bridges.first.is_a? Bridge
          to_class =
            unless bridges.last.is_a? Bridge
              bridges.pop
            else
              edgy_name(bridges.last.to_column.to_s).classify.constantize
            end
          @edgy_routes[name] = Connection.new(self, to_class, *bridges)
        else
          @edgy_routes[name] = edgy_build_connection(self, *bridges)
        end
      end

      def edgy_export(exporter)
        raise "Model not initialized with acts_as_edgy" unless @edgy_routes

        @edgy_routes.each do |name, connection|
          from_type = connection.from_class.name.underscore
          to_type = connection.to_class.name.underscore

          from_id = nil
          link_ids = Set.new
          to_ids = Set.new

          export = lambda do
            item = DirectedEdge::Item.new(exporter.database, "#{from_type}_#{from_id}")
            item.add_tag(from_type)
            link_ids.each { |link| item.link_to("#{to_type}_#{link}", 0, name) }
            exporter.export(item)
            link_ids.clear
          end

          edgy_paginated_sql_each(connection.sql_for_export) do |record|
            export.call unless from_id == record.from_id || link_ids.empty?
            from_id = record.from_id
            link_ids.add(record.to_id)
            to_ids.add(record.to_id)
          end

          export.call unless link_ids.empty?

          to_ids.each do |id|
            item = DirectedEdge::Item.new(exporter.database, "#{to_type}_#{id}")
            item.add_tag(to_type)
            exporter.export(item)
          end
        end
        exporter
      end

      def edgy_paginated_sql_each(query, &block)
        page = 1
        begin
          results = paginate_by_sql(query, :page => page)
          results.each { |r| block.call(r) }
          page += 1
        end while !results.empty?
      end

      private

      def edgy_find_method(in_class, referring_to)
        if in_class.column_names.include? referring_to.name.foreign_key
          referring_to.name.foreign_key
        else
          'id'
        end
      end

      def edgy_build_connection(*classes)
        raise "There must be at least three classes in an edgy path." if classes.size < 3
        bridges = []
        first = previous = classes.shift
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

    def sql_for_single(from_id)
      what = "#{@to_class.table_name}.id"
      from = "#{@to_class.table_name}"
      where = from_id.to_s

      @bridges.each do |bridge|
        from << ", #{bridge.klass.table_name}"
        where << " = #{bridge.klass.table_name}.#{bridge.from_column}"
        where << " and #{bridge.klass.table_name}.#{bridge.to_column}"
      end

      where << " = #{@to_class.table_name}.id"
      "select #{what} from #{from} where #{where};"
    end

    def sql_for_export
      first = @bridges.first
      last = @bridges.last

      from_column = "#{first.klass.table_name}.#{first.from_column}"
      to_column = "#{last.klass.table_name}.#{last.to_column}"

      what = "#{from_column} as from_id, #{to_column} as to_id"
      from = ""
      where = "#{from_column} is not null and #{to_column} is not null and "

      @bridges.each do |bridge|
        from << ", " unless bridge == first
        from << bridge.klass.table_name
        where << " = #{bridge.klass.table_name}.#{bridge.from_column}" unless bridge == first
        where << " and " unless (bridge == first || bridge == last)
        where << "#{bridge.klass.table_name}.#{bridge.to_column}" unless bridge == last
      end

      "select #{what} from #{from} where #{where} order by from_id"
    end
  end

  class Future
    def initialize(&finalize)
      @future = Thread.new(&finalize)
    end

    def method_missing(method, *args)
      data.send(method, *args)
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
