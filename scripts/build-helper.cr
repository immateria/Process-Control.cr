require "file_utils"
require "random/secure"
require "json"
require "set"
require "../src/process-control/platform/unix/helper"
require "./helper/runtime"

{% unless flag?(:darwin) || (flag?(:linux) && !flag?(:android)) %}
  abort "The Unix helper supports macOS and Linux."
{% end %}

compiler = ENV["CRYSTAL"]? || "crystal"
destination = nil.as(String?)
until ARGV.empty?
  argument = ARGV.shift
  if argument == "--compiler"
    compiler = ARGV.shift? || abort "--compiler requires an executable"
  elsif destination
    abort "Unexpected argument: #{argument}"
  else
    destination = argument
  end
end
version = IO::Memory.new
status = Process.run(compiler, ["--version"], output: version, error: STDERR)
unless status.success? && version.to_s.strip == Crystal::DESCRIPTION.strip
  abort "Select the same Crystal compiler used to run this builder with --compiler PATH."
end
destination ||= ProcessControl::Platform::Unix::Helper.path
FileUtils.mkdir_p(File.dirname(destination), mode: 0o700)
workspace = File.join(File.dirname(destination), "build-#{Random::Secure.hex(12)}")
Dir.mkdir(workspace, 0o700)
temporary = File.join(workspace, "helper")
begin
  # Optimization can fold an uninitialized global to zero and hide its load.
  development = File.join(workspace, "development")
  development_output = IO::Memory.new
  development_args = %w(build --cross-compile --single-module --no-debug --error-on-warnings -Dwithout_main --emit llvm-ir)
  # Crystal 1.10 uses its unoptimized development mode without an -O option.
  {% if compare_versions(Crystal::VERSION, "1.11.0") >= 0 %}
    development_args << "-O0"
  {% end %}
  development_args.concat([ProcessControl::Platform::Unix::Helper.source, "-o", development])
  status = Process.run(compiler,
    development_args,
    chdir: workspace, output: development_output, error: STDERR)
  unless status.success?
    STDERR << development_output.to_s
    abort "Native helper development compilation failed."
  end
  development_ir = File.read(development + ".ll")
  begin
    ProcessControl::Platform::Unix::Helper::Runtime.verify(development_ir)
  rescue ex
    File.write(destination + ".development.rejected.ll", development_ir)
    raise ex
  end
  status = Process.run(compiler,
    ["build", "--release", "--no-debug", "--error-on-warnings", "-Dwithout_main", "--emit", "llvm-ir",
     ProcessControl::Platform::Unix::Helper.source, "-o", temporary],
    chdir: workspace, output: STDOUT, error: STDERR)
  abort "Native helper compilation failed." unless status.success?
  ir = File.read(temporary + ".ll")
  begin
    ProcessControl::Platform::Unix::Helper::Runtime.verify(ir)
  rescue ex
    File.write(destination + ".rejected.ll", ir)
    raise ex
  end
  File.write(destination + ".audit.json", {"source" => ProcessControl::Platform::Unix::Helper.fingerprint,
                                           "compiler" => Crystal::DESCRIPTION, "target" => ProcessControl::Platform::Unix::Helper::TARGET,
                                           "ir" => Digest::SHA256.hexdigest(ir), "development_ir" => Digest::SHA256.hexdigest(development_ir)}.to_json)
  File.rename(temporary + ".ll", destination + ".ll")
  File.rename(development + ".ll", destination + ".development.ll")
  File.chmod(temporary, 0o700)
  File.rename(temporary, destination)
  puts destination
ensure
  FileUtils.rm_rf(workspace)
end
