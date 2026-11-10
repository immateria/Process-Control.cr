require "digest/sha256"

module ProcessControl::Platform::Unix::Helper
  SOURCE = {{ read_file("#{__DIR__}/../../../../native/process_control_helper.c") }}

  def self.source : String
    File.expand_path("../../../../native/process_control_helper.c", __DIR__)
  end

  def self.path : String
    if override = ENV["PROCESS_CONTROL_HELPER"]?
      return File.expand_path(override)
    end
    cache = ENV["XDG_CACHE_HOME"]? || File.join(Path.home.to_s, ".cache")
    target = {% if flag?(:darwin) %} "darwin" {% elsif flag?(:linux) %} "linux" {% else %} "unsupported" {% end %}
    digest = Digest::SHA256.hexdigest(SOURCE)
    File.join(cache, "process-control", target, digest, "helper")
  end
end
