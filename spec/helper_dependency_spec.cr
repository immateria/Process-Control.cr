require "spec"
require "file_utils"
require "random/secure"
require "../src/process-control/platform/unix/helper"

# These inputs are the package's actual compile-time source and audit manifest.
# A stale source identity could silently reuse a helper from before a raw ABI edit.
describe ProcessControl::Platform::Unix::Helper do
  it "changes the helper identity when dependency source bytes change" do
    sources = Native::Kernel::Source::FILES.dup
    sources.should_not be_empty
    key = sources.keys.sort.first
    original = ProcessControl::Platform::Unix::Helper.fingerprint
    original.should eq(ProcessControl::Platform::Unix::Helper.fingerprint(dependency_sources: sources))
    sources[key] += "\n# changed dependency content\n"
    ProcessControl::Platform::Unix::Helper.fingerprint(dependency_sources: sources).should_not eq(original)
  end

  it "changes the helper identity when the assembly audit profile changes" do
    assembly = Native::Kernel::Audit::ASSEMBLY.dup
    assembly.should_not be_empty
    original = ProcessControl::Platform::Unix::Helper.fingerprint
    assembly[0] += "changed constraint"
    ProcessControl::Platform::Unix::Helper.fingerprint(assembly: assembly).should_not eq(original)
  end
end

{% unless flag?(:windows) %}
  describe ProcessControl::Platform::Unix::Helper do
    it "resolves the selected compiler and relative caller paths for an external child build" do
      directory = File.join(Dir.tempdir, "helper-path-#{Random::Secure.hex(8)}")
      Dir.mkdir(directory)
      previous = ENV["CRYSTAL_PATH"]?
      begin
        Dir.cd(directory) do
          ENV["CRYSTAL_PATH"] = "caller-libs"
          environment = ProcessControl::Platform::Unix::Helper.compiler_environment(ENV["CRYSTAL"]? || "crystal")
          paths = environment["CRYSTAL_PATH"].split(':')
          paths.should contain(File.join(Dir.current, "caller-libs"))
          paths.first.should eq(File.join(Native::Kernel::Source.root, "src"))
          # A child requiring stdlib and the dependency must build from here,
          # even though the caller path intentionally contains no stdlib.
          source = File.join(directory, "dependency.cr")
          File.write(source, "require \"digest/sha256\"\nrequire \"native-kernel/source\"\nputs Native::Kernel::Source.root\n")
          output = IO::Memory.new
          errors = IO::Memory.new
          status = Process.run(ENV["CRYSTAL"]? || "crystal", ["run", source],
            chdir: directory, env: environment, output: output, error: errors)
          status.success?.should be_true, errors.to_s
          output.to_s.strip.should eq(Native::Kernel::Source.root)
        end
      ensure
        ENV["CRYSTAL_PATH"] = previous
        FileUtils.rm_rf(directory)
      end
    end
  end
{% end %}
