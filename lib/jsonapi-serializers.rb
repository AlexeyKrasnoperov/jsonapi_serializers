require 'jsonapi-serializers/version'
require 'jsonapi-serializers/attributes'
require 'jsonapi-serializers/serializer'
require 'jsonapi-serializers/serializer/class_methods'
require 'jsonapi-serializers/serializer/instance_methods'

module JSONAPI
  module Serializer
    class Error < RuntimeError; end
    class AmbiguousCollectionError < Error; end
    class InvalidIncludeError < Error; end
  end
end
