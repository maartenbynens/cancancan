module CanCan
  module ModelAdapters
    class ActiveRecord4Adapter < AbstractAdapter
      include ActiveRecordAdapter
      def self.for_class?(model_class)
        model_class <= ActiveRecord::Base
      end

      private

      # As of rails 4, `includes()` no longer causes active record to
      # look inside the where clause to decide to outer join tables
      # you're using in the where. Instead, `references()` is required
      # in addition to `includes()` to force the outer join.
      def build_relation(*where_conditions)
        relation = @model_class.where(*where_conditions)
        relation = relation.includes(joins).references(joins) if joins.present?
        relation
      end

      def self.override_condition_matching?(subject, name, _value)
        # ActiveRecord introduced enums in version 4.1.
        (ActiveRecord::VERSION::MAJOR > 4 || ActiveRecord::VERSION::MINOR >= 1) &&
          subject.class.defined_enums.include?(name.to_s)
      end

      def self.matches_condition?(subject, name, value)
        # Get the mapping from enum strings to values.
        enum = subject.class.send(name.to_s.pluralize)
        # Get the value of the attribute as an integer.
        attribute = enum[subject.send(name)]
        # Check to see if the value matches the condition.
        value.is_a?(Enumerable) ? 
          (value.include? attribute) :
          attribute == value
      end

      # Rails 4.2 deprecates `sanitize_sql_hash_for_conditions`
      def sanitize_sql(conditions)
        if ActiveRecord::VERSION::MAJOR > 4 && Hash === conditions
          table = @model_class.send(:arel_table)
          table_metadata = ActiveRecord::TableMetadata.new(@model_class, table)
          predicate_builder = ActiveRecord::PredicateBuilder.new(table_metadata)
          
          sanitize_sql_private(conditions) do |method, conditions| 
            predicate_builder.send(method, conditions)
          end


        elsif ActiveRecord::VERSION::MINOR >= 2 && Hash === conditions
          table = Arel::Table.new(@model_class.send(:table_name))

          sanitize_sql_private(conditions, @model_class, table) do |method, model_class, *args|
            ActiveRecord::PredicateBuilder.send(method, model_class, *args)
          end

        else
          @model_class.send(:sanitize_sql, conditions)
        end
      end

      private

      def sanitize_sql_private(rule_conditions, model_class = nil, table = nil)
        conditions = yield(:resolve_column_aliases, model_class, rule_conditions)
        conditions = @model_class.send(:expand_hash_conditions_for_aggregates, conditions)

        conditions.stringify_keys! #if args.length == 1

        json_conditions, conditions = conditions.partition { |k,v| v.is_a?(Hash) && @model_class.columns.find { |c| c.name == k.to_s } }.map(&:to_h)

        conditions = yield(:build_from_hash, model_class, conditions, table).map { |b|
          @model_class.send(:connection).visitor.compile b
        }

        json_conditions = json_conditions.map do |k,v|
          kk, vv = v.first
          @model_class.send(:sanitize_sql, ["#{@model_class.send(:table_name)}.#{k}->'#{kk}' = :value", value: vv.to_s])
        end
        (conditions + json_conditions).join(' AND ')
      end
    end
  end
end
