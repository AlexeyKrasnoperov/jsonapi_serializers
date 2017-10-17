module JSONAPI
  module Serializer
    module InstanceMethods
      @@unformatted_attribute_names = {}

      attr_accessor :object
      attr_accessor :context
      attr_accessor :base_url

      def initialize(object, options = {})
        @object = object
        @options = options
        @context = options[:context] || {}
        @base_url = options[:base_url]

        # Internal serializer options, not exposed through attr_accessor. No touchie.
        @_fields = options[:fields] || {}
        @_include_linkages = options[:include_linkages] || []
      end

      # Override this to customize the JSON:API "id" for this object.
      # Always return a string from this method to conform with the JSON:API spec.
      def id
        object.id.to_s
      end

      # Override this to customize the JSON:API "type" for this object.
      # By default, the type is the object's class name lowercased, pluralized, and dasherized,
      # per the spec naming recommendations: http://jsonapi.org/recommendations/#naming
      # For example, 'MyApp::LongCommment' will become the 'long-comments' type.
      def type
        class_name = object.class.name
        JSONAPI::Serializer.transform_key_casing(class_name.demodulize.tableize).freeze
      end

      # Override this to customize how attribute names are formatted.
      # By default, attribute names are dasherized per the spec naming recommendations:
      # http://jsonapi.org/recommendations/#naming
      def format_name(attribute_name)
        attr_name = attribute_name.to_s
        JSONAPI::Serializer.transform_key_casing(attr_name).freeze
      end

      # The opposite of format_name. Override this if you override format_name.
      def unformat_name(attribute_name)
        attr_name = attribute_name.to_s
        @@unformatted_attribute_names[attr_name] ||= attr_name.underscore.freeze
      end

      # Override this to provide resource-object jsonapi object containing the version in use.
      # http://jsonapi.org/format/#document-jsonapi-object
      def jsonapi; end

      # Override this to provide resource-object metadata.
      # http://jsonapi.org/format/#document-structure-resource-objects
      def meta; end

      # Override this to set a base URL (http://example.com) for all links. No trailing slash.
      def base_url
        @base_url
      end

      def self_link
        "#{base_url}/#{type}/#{id}"
      end

      def relationship_self_link(attribute_name)
        "#{self_link}/relationships/#{format_name(attribute_name)}"
      end

      def relationship_related_link(attribute_name)
        "#{self_link}/#{format_name(attribute_name)}"
      end

      def links
        data = {}
        data['self'] = self_link if self_link
        data
      end

      def relationships
        data = {}
        # Merge in data for has_one relationships.
        has_one_relationships.each do |attribute_name, attr_data|
          formatted_attribute_name = format_name(attribute_name)

          data[formatted_attribute_name] = {}

          if attr_data[:options][:include_links]
            links_self = relationship_self_link(attribute_name)
            links_related = relationship_related_link(attribute_name)
            data[formatted_attribute_name]['links'] = {} if links_self || links_related
            data[formatted_attribute_name]['links']['self'] = links_self if links_self
            data[formatted_attribute_name]['links']['related'] = links_related if links_related
          end

          next unless @_include_linkages.include?(formatted_attribute_name) || attr_data[:options][:include_data]
          object = has_one_relationship(attribute_name, attr_data)
          if object.nil?
            # Spec: Resource linkage MUST be represented as one of the following:
            # - null for empty to-one relationships.
            # http://jsonapi.org/format/#document-structure-resource-relationships
            data[formatted_attribute_name]['data'] = nil
          else
            related_object_serializer = JSONAPI::Serializer.find_serializer(object, attr_data[:options])
            data[formatted_attribute_name]['data'] = {
              'id' => related_object_serializer.id.to_s,
              'type' => related_object_serializer.type.to_s
            }
          end
        end

        # Merge in data for has_many relationships.
        has_many_relationships.each do |attribute_name, attr_data|
          formatted_attribute_name = format_name(attribute_name)

          data[formatted_attribute_name] = {}

          if attr_data[:options][:include_links]
            links_self = relationship_self_link(attribute_name)
            links_related = relationship_related_link(attribute_name)
            data[formatted_attribute_name]['links'] = {} if links_self || links_related
            data[formatted_attribute_name]['links']['self'] = links_self if links_self
            data[formatted_attribute_name]['links']['related'] = links_related if links_related
          end

          # Spec: Resource linkage MUST be represented as one of the following:
          # - an empty array ([]) for empty to-many relationships.
          # - an array of linkage objects for non-empty to-many relationships.
          # http://jsonapi.org/format/#document-structure-resource-relationships
          next unless @_include_linkages.include?(formatted_attribute_name) || attr_data[:options][:include_data]
          data[formatted_attribute_name]['data'] = []
          objects = has_many_relationship(attribute_name, attr_data) || []
          objects.each do |obj|
            related_object_serializer = JSONAPI::Serializer.find_serializer(obj, attr_data[:options])
            data[formatted_attribute_name]['data'] << {
              'id' => related_object_serializer.id.to_s,
              'type' => related_object_serializer.type.to_s
            }
          end
        end
        data
      end

      def attributes
        return {} if self.class.attributes_map.nil?
        attributes = {}
        self.class.attributes_map.each do |attribute_name, attr_data|
          next unless should_include_attr?(attribute_name, attr_data)
          value = evaluate_attr_or_block(attribute_name, attr_data[:attr_or_block])
          attributes[format_name(attribute_name)] = value
        end
        attributes
      end

      def has_one_relationships
        return {} if self.class.to_one_associations.nil?
        data = {}
        self.class.to_one_associations.each do |attribute_name, attr_data|
          next unless should_include_attr?(attribute_name, attr_data)
          data[attribute_name] = attr_data
        end
        data
      end

      def has_one_relationship(attribute_name, attr_data)
        evaluate_attr_or_block(attribute_name, attr_data[:attr_or_block])
      end

      def has_many_relationships
        return {} if self.class.to_many_associations.nil?
        data = {}
        self.class.to_many_associations.each do |attribute_name, attr_data|
          next unless should_include_attr?(attribute_name, attr_data)
          data[attribute_name] = attr_data
        end
        data
      end

      def has_many_relationship(attribute_name, attr_data)
        evaluate_attr_or_block(attribute_name, attr_data[:attr_or_block])
      end

      def should_include_attr?(attribute_name, attr_data)
        # Allow "if: :show_title?" and "unless: :hide_title?" attribute options.
        if_method_name = attr_data[:options][:if]
        unless_method_name = attr_data[:options][:unless]
        formatted_attribute_name = format_name(attribute_name).to_sym
        show_attr = true
        show_attr &&= send(if_method_name) if if_method_name
        show_attr &&= !send(unless_method_name) if unless_method_name
        show_attr &&= @_fields[type.to_s].include?(formatted_attribute_name) if @_fields[type.to_s]
        show_attr
      end
      protected :should_include_attr?

      def evaluate_attr_or_block(_attribute_name, attr_or_block)
        if attr_or_block.is_a?(Proc)
          # A custom block was given, call it to get the value.
          instance_eval(&attr_or_block)
        else
          # Default behavior, call a method by the name of the attribute.
          object.send(attr_or_block)
        end
      end
      protected :evaluate_attr_or_block
    end
  end
end
