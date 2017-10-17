module JSONAPI
  module Serializer
    module ClassMethods
      def serialize(object, options = {})
        # Since this is being called on the class directly and not the module, override the
        # serializer option to be the current class.
        options[:serializer] = self

        JSONAPI::Serializer.serialize(object, options)
      end
    end
  end
end
