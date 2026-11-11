require "digest/sha256"
require "native-kernel/source"
require "native-kernel/audit"

module ProcessControl::Platform::Unix::Helper
  # Snapshot both local build/audit code and every source in the resolved package.
  # The raw require is deliberately absent: this metadata is portable.
  {% begin %}
  LOCAL_SOURCES = {
    {% for name in [
                     "native/helper.cr",
                     "native/helper/protocol.cr",
                     "native/helper/text.cr",
                     "native/helper/io.cr",
                     "native/helper/darwin.cr",
                     "native/helper/darwin/system.cr",
                     "native/helper/darwin/signals.cr",
                     "native/helper/darwin/descriptors.cr",
                     "native/helper/darwin/setup.cr",
                     "native/helper/darwin/io.cr",
                     "native/helper/darwin/owner.cr",
                     "native/helper/descriptors.cr",
                     "native/helper/signals.cr",
                     "native/helper/setup.cr",
                     "native/helper/cgroup.cr",
                     "native/helper/owner.cr",
                     "scripts/helper/runtime.cr",
                     "scripts/helper/kernel.cr",
                     "scripts/build-helper.cr",
                     "src/process-control/platform/unix/helper.cr",
                     "scripts/check-darwin.cr",
                   ] %}
      {{name}} => {{read_file(__DIR__ + "/../../../../" + name)}},
    {% end %}
  }
  {% end %}
  SOURCE = LOCAL_SOURCES.to_a.sort_by(&.[0]).map { |entry| "#{entry[0]}\0#{entry[1]}\0" }.join

  def self.source : String
    File.expand_path("../../../../native/helper.cr", __DIR__)
  end

  def self.root : String
    File.expand_path("..", File.dirname(source))
  end

  TARGET = {{ flag?(:aarch64) ? "aarch64" : (flag?(:x86_64) ? "x86_64" : "unsupported") }} + "-" +
           {{ flag?(:darwin) ? "darwin" : (flag?(:linux) ? "linux" : "unsupported") }}

  def self.fingerprint(source = SOURCE, compiler = Crystal::DESCRIPTION, target = TARGET, *,
                       dependency_sources = Native::Kernel::Source::FILES,
                       assembly = Native::Kernel::Audit::ASSEMBLY) : String
    digest = Digest::SHA256.new
    ["native-loop-v2", compiler, target, source].each { |input| digest << input.bytesize.to_s << ":" << input }
    dependency_sources.keys.sort.each do |name|
      [name, dependency_sources[name]].each { |input| digest << input.bytesize.to_s << ":" << input }
    end
    digest << "assembly:"
    assembly.sort.each { |input| digest << input.bytesize.to_s << ":" << input }
    digest.hexfinal
  end

  # A builder compiled before an edit must never stamp the new helper with its
  # old embedded identity. Check again after compilation before installing it.
  def self.verify_sources! : Nil
    LOCAL_SOURCES.each do |name, bytes|
      unless File.read(File.join(root, name)) == bytes
        raise ArgumentError.new("Helper source changed since builder compilation: #{name}")
      end
    end
    Native::Kernel::Source::FILES.each do |name, bytes|
      unless File.read(File.join(Native::Kernel::Source.root, name)) == bytes
        raise ArgumentError.new("Native-Kernel source changed since builder compilation: #{name}")
      end
    end
  end

  # Child builds run outside the checkout. Resolve caller entries before that
  # chdir, and obtain the selected compiler's own default library paths without
  # allowing CRYSTAL_PATH to suppress its stdlib. Metadata identifies the exact
  # dependency resolved when this builder was compiled, including overrides.
  def self.compiler_environment(compiler : String) : Hash(String, String)
    defaults = IO::Memory.new
    status = Process.run(compiler, ["env", "CRYSTAL_PATH"], env: {"CRYSTAL_PATH" => nil},
      chdir: root, output: defaults, error: STDERR)
    raise ArgumentError.new("Cannot resolve the selected compiler's CRYSTAL_PATH") unless status.success?
    separator = {{ flag?(:windows) ? ";" : ":" }}
    paths = [File.join(Native::Kernel::Source.root, "src")]
    if inherited = ENV["CRYSTAL_PATH"]?
      inherited.split(separator).each { |path| paths << File.expand_path(path, Dir.current) }
    end
    defaults.to_s.strip.split(separator).each { |path| paths << File.expand_path(path, root) }
    {"CRYSTAL_PATH" => paths.uniq.join(separator)}
  end

  def self.path : String
    if override = ENV["PROCESS_CONTROL_HELPER"]?
      return File.expand_path(override)
    end
    cache = ENV["XDG_CACHE_HOME"]? || File.join(Path.home.to_s, ".cache")
    File.join(cache, "process-control", TARGET, fingerprint, "helper")
  end
end
