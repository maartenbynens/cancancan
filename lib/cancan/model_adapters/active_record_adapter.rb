module CanCan
  module ModelAdapters
    module ActiveRecordAdapter
      # Returns conditions intended to be used inside a database query. Normally you will not call this
      # method directly, but instead go through ModelAdditions#accessible_by.
      #
      # If there is only one "can" definition, a hash of conditions will be returned matching the one defined.
      #
      #   can :manage, User, :id => 1
      #   query(:manage, User).conditions # => { :id => 1 }
      #
      # If there are multiple "can" definitions, a SQL string will be returned to handle complex cases.
      #
      #   can :manage, User, :id => 1
      #   can :manage, User, :manager_id => 1
      #   cannot :manage, User, :self_managed => true
      #   query(:manage, User).conditions # => "not (self_managed = 't') AND ((manager_id = 1) OR (id = 1))"
      #
      def conditions
        if @rules.size == 1 && @rules.first.base_behavior
          # Return the conditions directly if there's just one definition
          tableized_conditions(@rules.first.conditions).dup
        else
          @rules.reverse.inject(false_sql) do |sql, rule|
            merge_conditions(sql, tableized_conditions(rule.conditions).dup, rule.base_behavior)
          end
        end
      end

      def tableized_conditions(conditions, model_class = @model_class)
        return conditions unless conditions.kind_of? Hash
        conditions.inject({}) do |result_hash, (name, value)|
          if value.kind_of? Hash
            value = value.dup
            association_class = model_class.reflect_on_association(name).klass.name.constantize
            nested = value.inject({}) do |nested,(k,v)|
              if v.kind_of? Hash
                value.delete(k)
                nested[k] = v
              else
                result_hash[model_class.reflect_on_association(name).table_name.to_sym] = value
              end
              nested
            end
            result_hash.merge!(tableized_conditions(nested,association_class))
          else
            result_hash[name] = value
          end
          result_hash
        end
      end

      # Returns the associations used in conditions for the :joins option of a search.
      # See ModelAdditions#accessible_by
      def joins
        joins_hash = {}
        @rules.each do |rule|
          merge_joins(joins_hash, rule.associations_hash)
        end
        clean_joins(joins_hash) unless joins_hash.empty?
      end

      def database_records
        if override_scope
          @model_class.where(nil).merge(override_scope)
        elsif @model_class.respond_to?(:where) && @model_class.respond_to?(:joins)
          if mergeable_conditions?
            build_relation(conditions)
          else
            build_relation(*(@rules.map(&:conditions)))
          end
        else
          @model_class.all(conditions: conditions, joins: joins)
        end
      end

      private

      def mergeable_conditions?
        @rules.find { |rule| rule.unmergeable? }.blank?
      end

      def override_scope
        conditions = @rules.map(&:conditions).compact
        if defined?(ActiveRecord::Relation) && conditions.any? { |c| c.kind_of?(ActiveRecord::Relation) }
          if conditions.size == 1
            conditions.first
          else
            rule = @rules.detect { |rule| rule.conditions.kind_of?(ActiveRecord::Relation) }
            raise Error, "Unable to merge an Active Record scope with other conditions. Instead use a hash or SQL for #{rule.actions.first} #{rule.subjects.first} ability."
          end
        end
      end

      def merge_conditions(sql, conditions_hash, behavior)
        if conditions_hash.blank?
          behavior ? true_sql : false_sql
        else
          conditions = sanitize_sql(conditions_hash)
          case sql
          when true_sql
            behavior ? true_sql : "not (#{conditions})"
          when false_sql
            behavior ? conditions : false_sql
          else
            behavior ? "(#{conditions}) OR (#{sql})" : "not (#{conditions}) AND (#{sql})"
          end
        end
      end

      def false_sql
        sanitize_sql(['?=?', true, false])
      end

      def true_sql
        sanitize_sql(['?=?', true, true])
      end

      def sanitize_sql(conditions)
        @model_class.send(:sanitize_sql, conditions)
      end

      # Takes two hashes and does a deep merge.
      def merge_joins(base, add)
        add.each do |name, nested|
          if base[name].is_a?(Hash)
            merge_joins(base[name], nested) unless nested.empty?
          else
            base[name] = nested
          end
        end
      end

      # Removes empty hashes and moves everything into arrays.
      def clean_joins(joins_hash)
        joins = []
        joins_hash.each do |name, nested|
          joins << (nested.empty? ? name : { name => clean_joins(nested) })
        end
        joins
      end
    end
  end
end

ActiveRecord::Base.class_eval do
  include CanCan::ModelAdditions
end
