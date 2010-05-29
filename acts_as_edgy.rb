require 'directed_edge'
require 'active_support'
require 'active_record'

module DirectedEdge
  module Edgy
    def self.included(base)
      base.send :include, Utilities
      base.send :extend, ClassMethods
    end

    class << self
      attr_accessor :edgy_database
    end

    def edgy_related(options = {})
      item_type = self.class.name.underscore
      tags = options.delete(:tags) || Set.new([ item_type ])
      item = DirectedEdge::Item.new(Edgy.edgy_database, "#{item_type}_#{id}")
      edgy_records(item.related(tags, options))
    end

    def edgy_recommended(options = {})
      item_type = self.class.name.underscore
      tags = options.delete(:tags)
      unless tags
        tags = Set.new
        self.class.edgy_connections.each { |c| tags.add(c.to_class.name.underscore) }
      end
      item = DirectedEdge::Item.new(Edgy.edgy_database, "#{item_type}_#{id}")
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
        @edgy_names ||= []
        @edgy_connections ||= []
        @edgy_names.push(name)

        if bridges.first.is_a? Bridge
          to_class =
            unless bridges.last.is_a? Bridge
              bridges.pop
            else
              edgy_name(bridges.last.to_column.to_s).classify.constantize
            end
          @edgy_connections.push(Connection.new(self, to_class, *bridges))
        else
          @edgy_connections.push(edgy_build_connection(self, *bridges));
        end
      end

      def edgy_export(exporter)
        raise "Model not initialized with acts_as_edgy" unless @edgy_connections
        (0..@edgy_connections.size - 1).each do |i|
          connection = @edgy_connections[i]
          from_name = connection.from_class.name.underscore
          to_name = connection.to_class.name.underscore

          from = nil
          links = Set.new
          to_ids = Set.new

          find_by_sql(connection.sql_for_export).each do |record|
            if from != record.from_id && !links.empty?
              item = DirectedEdge::Item.new(exporter.database, "#{from_name}_#{record.from_id}")
              item.add_tag(from_name)
              links.each { |link| item.link_to("#{to_name}_#{link}", 0, @edgy_names[i]) }
              exporter.export(item)
              links.clear
            end
            from = record.from_id
            links.add(record.to_id)
            to_ids.add(record.to_id)
          end

          to_ids.each do |id|
            item = DirectedEdge::Item.new(exporter.database, "#{to_name}_#{id}")
            item.add_tag(to_name)
            exporter.export(item)
          end
        end
        exporter
      end

      private

      def edgy_find_method(in_class, referring_to)
        if in_class.column_names.include? referring_to.name.foreign_key
          referring_to.name.foreign_key
        elsif in_class.column_names.include? referring_to.name.foreign_key
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

      what = "#{first.klass.table_name}.#{first.from_column} as from_id, "
      what << "#{last.klass.table_name}.#{last.to_column} as to_id"

      from = ""
      where = ""

      @bridges.each do |bridge|
        from << ", " unless bridge == first
        from << bridge.klass.table_name
        where << " = #{bridge.klass.table_name}.#{bridge.from_column}" unless bridge == first
        where << " and " unless (bridge == first || bridge == last)
        where << "#{bridge.klass.table_name}.#{bridge.to_column}" unless bridge == last
      end

      "select #{what} from #{from} where #{where} order by from_id;"
    end
  end
end

ActiveRecord::Base.send :include, DirectedEdge::Edgy
