require "digest/sha256"

require "digest/sha256"

module ProcessControl::Platform::Unix::Helper
  SOURCE = "native/helper.cr\0" + {{ read_file("#{__DIR__}/../../../../native/helper.cr") }} + "\0" +
           "native/helper/protocol.cr\0" + {{ read_file("#{__DIR__}/../../../../native/helper/protocol.cr") }} + "\0" +
           "native/helper/descriptors.cr\0" + {{ read_file("#{__DIR__}/../../../../native/helper/descriptors.cr") }} + "\0" +
           "native/helper/signals.cr\0" + {{ read_file("#{__DIR__}/../../../../native/helper/signals.cr") }} + "\0" +
           "native/helper/owner.cr\0" + {{ read_file("#{__DIR__}/../../../../native/helper/owner.cr") }} + "\0" +
           "scripts/helper/runtime.cr\0" + {{ read_file("#{__DIR__}/../../../../scripts/helper/runtime.cr") }} + "\0" +
           "scripts/build-helper.cr\0" + {{ read_file("#{__DIR__}/../../../../scripts/build-helper.cr") }} + "\0"

  def self.source : String
    File.expand_path("../../../../native/helper.cr", __DIR__)
  end

  TARGET = {{ flag?(:aarch64) ? "aarch64" : (flag?(:x86_64) ? "x86_64" : "unsupported") }} + "-" +
           {{ flag?(:darwin) ? "darwin" : (flag?(:linux) ? "linux" : "unsupported") }}

  def self.fingerprint(source = SOURCE, compiler = Crystal::DESCRIPTION, target = TARGET) : String
    Digest::SHA256.hexdigest("native-loop-v1\0#{compiler}\0#{target}\0#{source}")
  end

  def self.path : String
    if override = ENV["PROCESS_CONTROL_HELPER"]?
      return File.expand_path(override)
    end
    cache = ENV["XDG_CACHE_HOME"]? || File.join(Path.home.to_s, ".cache")
    File.join(cache, "process-control", TARGET, fingerprint, "helper")
  end
end
