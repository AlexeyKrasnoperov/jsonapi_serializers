require 'set'
require 'active_support/inflector'
require 'active_support/configurable'
require 'case_transform'

module JSONAPI
  module Serializer
    include ActiveSupport::Configurable
    def self.included(target)
      target.extend(ClassMethods)
      target.class_eval do
        include InstanceMethods
        include JSONAPI::Attributes
      end
    end

    class << self
      def serialize(objects, options = {})
        options.symbolize_keys!
        options[:fields] ||= {}

        includes = normalize(options[:include])

        fields = {}
        # Normalize fields to accept a comma-separated string or an array of strings.
        options[:fields].map do |type, whitelisted_fields|
          fields[type.to_s] = normalize(whitelisted_fields).map(&:to_sym)
        end

        # An internal-only structure that is passed through serializers as they are created.
        passthrough_options = {
          context: options[:context],
          serializer: options[:serializer],
          namespace: options[:namespace],
          include: includes,
          fields: fields,
          base_url: options[:base_url]
        }

        # Duck-typing check for a collection being passed without is_collection true.
        # We always must be told if serializing a collection because the JSON:API spec distinguishes
        # how to serialize null single resources vs. empty collections.
        unless options[:skip_collection_check]
          if options[:is_collection] && !objects.respond_to?(:each)
            raise JSONAPI::Serializer::AmbiguousCollectionError,
                  'Attempted to serialize a single object as a collection.'
          end

          if !options[:is_collection] && objects.respond_to?(:each)
            raise JSONAPI::Serializer::AmbiguousCollectionError,
                  'Must provide `is_collection: true` to `serialize` when serializing collections.'
          end
        end

        # Automatically include linkage data for any relation that is also included.
        if includes
          direct_children_includes = includes.reject { |key| key.include?('.') }
          passthrough_options[:include_linkages] = direct_children_includes
        end

        # Spec: Primary data MUST be either:
        # - a single resource object or null, for requests that target single resources.
        # - an array of resource objects or an empty array ([]), for resource collections.
        # http://jsonapi.org/format/#document-structure-top-level
        primary_data = if options[:is_collection]
                         serialize_primary_multi(objects, passthrough_options)
                       elsif objects.nil?
                         nil
                       else
                         serialize_primary(objects, passthrough_options)
                       end
        result = {
          'data' => primary_data
        }
        result['jsonapi'] = options[:jsonapi] if options[:jsonapi]
        result['meta'] = options[:meta] if options[:meta]
        result['links'] = options[:links] if options[:links]

        # If 'include' relationships are given, recursively find and include each object.
        if includes
          relationship_data = {}
          inclusion_tree = parse_relationship_paths(includes)

          # Given all the primary objects (either the single root object or collection of objects),
          # recursively search and find related associations that were specified as includes.
          objects = Array(objects)
          objects.compact.each do |obj|
            # Use the mutability of relationship_data as the return datastructure to take advantage
            # of the internal special merging logic.
            find_recursive_relationships(obj, inclusion_tree, relationship_data, passthrough_options)
          end

          result['included'] = relationship_data.map do |_, data|
            included_passthrough_options = {}
            included_passthrough_options[:base_url] = passthrough_options[:base_url]
            included_passthrough_options[:context] = passthrough_options[:context]
            included_passthrough_options[:fields] = passthrough_options[:fields]

            included_passthrough_options[:serializer] = find_serializer_class(data[:object], data[:options])
            included_passthrough_options[:namespace] = passthrough_options[:namespace]
            included_passthrough_options[:include_linkages] = data[:include_linkages]
            serialize_primary(data[:object], included_passthrough_options)
          end
        end
        result
      end

      def serialize_errors(raw_errors)
        if is_activemodel_errors?(raw_errors)
          { 'errors' => activemodel_errors(raw_errors) }
        else
          { 'errors' => raw_errors }
        end
      end

      def find_serializer(object, options)
        klass = find_serializer_class(object, options)
        klass.new(object, options)
      end

      def transform_key_casing(value)
        CaseTransform.send(JSONAPI::Serializer.config.key_transform || :dash, value)
      end

      private

      def normalize(possible_string)
        return unless possible_string
        Array((possible_string.is_a?(String) ? possible_string.split(',') : possible_string)).uniq
      end

      def find_serializer_class(object, options)
        class_name = if options[:serializer]
                       options[:serializer].to_s
                     elsif options[:namespace]
                       "#{options[:namespace]}::#{object.class.name}Serializer"
                     elsif object.respond_to?(:jsonapi_serializer_class_name)
                       object.jsonapi_serializer_class_name.to_s
                     else
                       "#{object.class.name}Serializer"
                     end
        class_name.constantize
      end

      def activemodel_errors(raw_errors)
        raw_errors.to_hash(full_messages: true).inject([]) do |result, (attribute, messages)|
          result + messages.map { |message| single_error(attribute.to_s, message) }
        end
      end

      def is_activemodel_errors?(raw_errors)
        raw_errors.respond_to?(:to_hash) && raw_errors.respond_to?(:full_messages)
      end

      def single_error(attribute, message)
        {
          'source' => {
            'pointer' => "/data/attributes/#{transform_key_casing(attribute)}"
          },
          'detail' => message
        }
      end

      def serialize_primary(object, options = {})
        serializer_class = options[:serializer] || find_serializer_class(object, options)

        # Spec: Primary data MUST be either:
        # - a single resource object or null, for requests that target single resources.
        # http://jsonapi.org/format/#document-structure-top-level
        return if object.nil?

        serializer = serializer_class.new(object, options)
        data = {}

        # "The id member is not required when the resource object originates at the client
        #  and represents a new resource to be created on the server."
        # http://jsonapi.org/format/#document-resource-objects
        # We'll assume that if the id is blank, it means the resource is to be created.
        data['id'] = serializer.id.to_s if serializer.id && !serializer.id.empty?
        data['type'] = serializer.type.to_s

        # Merge in optional top-level members if they are non-nil.
        # http://jsonapi.org/format/#document-structure-resource-objects
        # Call the methods once now to avoid calling them twice when evaluating the if's below.
        attributes = serializer.attributes
        links = serializer.links
        relationships = serializer.relationships
        jsonapi = serializer.jsonapi
        meta = serializer.meta
        data['attributes'] = attributes unless attributes.empty?
        data['links'] = links unless links.empty?
        data['relationships'] = relationships unless relationships.empty?
        data['jsonapi'] = jsonapi unless jsonapi.nil?
        data['meta'] = meta unless meta.nil?
        data
      end

      def serialize_primary_multi(objects, options = {})
        # Spec: Primary data MUST be either:
        # - an array of resource objects or an empty array ([]), for resource collections.
        # http://jsonapi.org/format/#document-structure-top-level
        return [] unless objects.any?

        objects.map { |obj| serialize_primary(obj, options) }
      end

      # Recursively find object relationships and returns a tree of related objects.
      # Example return:
      # {
      #   ['comments', '1'] => {object: <Comment>, include_linkages: ['author']},
      #   ['users', '1'] => {object: <User>, include_linkages: []},
      #   ['users', '2'] => {object: <User>, include_linkages: []},
      # }
      def find_recursive_relationships(root_object, root_inclusion_tree, results, options)
        root_inclusion_tree.each do |attribute_name, child_inclusion_tree|
          # Skip the sentinal value, but we need to preserve it for siblings.
          next if attribute_name == :_include

          specific_serializer_options = results.find do |k, _v|
            k.first == root_object.id.to_s &&
              k.last == transform_key_casing(root_object.class.name.split('::').last.underscore).pluralize
          end
          specific_serializer_options = specific_serializer_options.last[:options] if specific_serializer_options

          specified_serializer = specific_serializer_options[:serializer] if specific_serializer_options
          options_to_be_passed = specified_serializer ? options.merge(serializer: specified_serializer) : options
          serializer = JSONAPI::Serializer.find_serializer(root_object, options_to_be_passed)
          unformatted_attr_name = serializer.unformat_name(attribute_name).to_sym

          # We know the name of this relationship, but we don't know where it is stored internally.
          # Check if it is a has_one or has_many relationship.
          object = nil
          is_valid_attr = false
          if serializer.has_one_relationships.key?(unformatted_attr_name)
            is_valid_attr = true
            attr_data = serializer.has_one_relationships[unformatted_attr_name]
            object = serializer.has_one_relationship(unformatted_attr_name, attr_data)
          elsif serializer.has_many_relationships.key?(unformatted_attr_name)
            is_valid_attr = true
            attr_data = serializer.has_many_relationships[unformatted_attr_name]
            object = serializer.has_many_relationship(unformatted_attr_name, attr_data)
          end

          unless is_valid_attr
            raise JSONAPI::Serializer::InvalidIncludeError, "'#{attribute_name}' is not a valid include."
          end

          if attribute_name != serializer.format_name(attribute_name)
            expected_name = serializer.format_name(attribute_name)

            raise JSONAPI::Serializer::InvalidIncludeError,
                  "'#{attribute_name}' is not a valid include.  Did you mean '#{expected_name}' ?"
          end

          # We're finding relationships for compound documents, so skip anything that doesn't exist.
          next if object.nil?

          # Full linkage: a request for comments.author MUST automatically include comments
          # in the response.
          objects = Array(object)
          if child_inclusion_tree[:_include] == true
            # Include the current level objects if the _include attribute exists.
            # If it is not set, that indicates that this is an inner path and not a leaf and will
            # be followed by the recursion below.
            objects.each do |obj|
              obj_serializer = JSONAPI::Serializer.find_serializer(obj, attr_data[:options])
              # Use keys of ['posts', '1'] for the results to enforce uniqueness.
              # Spec: A compound document MUST NOT include more than one resource object for each
              # type and id pair.
              # http://jsonapi.org/format/#document-structure-compound-documents
              key = [obj_serializer.id, obj_serializer.type]

              # This is special: we know at this level if a child of this parent will also been
              # included in the compound document, so we can compute exactly what linkages should
              # be included by the object at this level. This satisfies this part of the spec:
              #
              # Spec: Resource linkage in a compound document allows a client to link together
              # all of the included resource objects without having to GET any relationship URLs.
              # http://jsonapi.org/format/#document-structure-resource-relationships
              current_child_includes = []
              inclusion_names = child_inclusion_tree.keys.reject { |k| k == :_include }
              inclusion_names.each do |inclusion_name|
                if child_inclusion_tree[inclusion_name][:_include]
                  current_child_includes << inclusion_name
                end
              end

              # Special merge: we might see this object multiple times in the course of recursion,
              # so merge the include_linkages each time we see it to load all the relevant linkages.
              current_child_includes += results[key] && results[key][:include_linkages] || []
              current_child_includes.uniq!
              results[key] = { object: obj, include_linkages: current_child_includes, options: attr_data[:options] }
            end
          end

          # Recurse deeper!
          next if child_inclusion_tree.empty?
          # For each object we just loaded, find all deeper recursive relationships.
          objects.each do |obj|
            find_recursive_relationships(obj, child_inclusion_tree, results, options)
          end
        end
        nil
      end

      # Takes a list of relationship paths and returns a hash as deep as the given paths.
      # The _include: true is a sentinal value that specifies whether the parent level should
      # be included.
      #
      # Example:
      #   Given: ['author', 'comments', 'comments.user']
      #   Returns: {
      #     'author' => {_include: true},
      #     'comments' => {_include: true, 'user' => {_include: true}},
      #   }
      def parse_relationship_paths(paths)
        relationships = {}
        paths.each { |path| merge_relationship_path(path, relationships) }
        relationships
      end

      def merge_relationship_path(path, data)
        parts = path.split('.', 2)
        current_level = parts[0].strip
        data[current_level] ||= { _include: true }

        return unless parts.length == 2
        # Need to recurse more.
        merge_relationship_path(parts[1], data[current_level])
      end
    end
  end
end
