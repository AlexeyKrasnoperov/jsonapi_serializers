require 'jsonapi-serializers/version'
require 'jsonapi-serializers/attributes'
require 'jsonapi-serializers/serializer'

module JSONAPI
  module Serializer
    class Error < RuntimeError; end
    class AmbiguousCollectionError < Error; end
    class InvalidIncludeError < Error; end
  end
end
