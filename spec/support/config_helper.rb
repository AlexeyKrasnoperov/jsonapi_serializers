module ConfigHelper
  def config
    JSONAPI::Serializer.config
  end

  def with_config(hash)
    old_config = config.dup
    JSONAPI::Serializer.config.update(hash)
    yield
  ensure
    JSONAPI::Serializer.config.replace(old_config)
  end
end
