require "digest/sha256"
require "file_utils"
require "json"
require "random/secure"
require "set"
require "./helper/runtime"
require "../src/process-control/platform/unix/helper"

{% unless flag?(:darwin) %}
  {% raise "Native Darwin qualification requires macOS." %}
{% end %}

compiler = ENV["CRYSTAL"]? || "crystal"
description = IO::Memory.new
unless Process.run(compiler, ["--version"], output: description).success? && description.to_s.strip == Crystal::DESCRIPTION.strip
  abort "Select the compiler running this script with CRYSTAL=PATH."
end
abort "Pass at most one external receipt directory." if ARGV.size > 1
root = File.expand_path("..", __DIR__)
destination = File.expand_path(ARGV.first? || File.join(Dir.tempdir, "process-control-darwin-#{Random::Secure.hex(8)}"))
if destination == root || destination.starts_with?(root + File::SEPARATOR)
  abort "The qualification directory must be outside the repository."
end
abort "The qualification directory already exists." if File.exists?(destination)
Dir.mkdir_p(destination, 0o700)
puts "Receipts #{destination}"

inputs = %w(scripts/check-darwin.cr scripts/helper/runtime.cr scripts/helper/kernel.cr)
%w(src spec native).each do |directory|
  Dir.glob(File.join(root, directory, "**", "*.cr")).each do |path|
    inputs << Path[path].relative_to(root).to_s
  end
end
inputs.sort!.uniq!
sources = inputs.to_h do |name|
  {name, Digest::SHA256.hexdigest(File.read(File.join(root, name)))}
end
ProcessControl::Platform::Unix::Helper.verify_sources!
dependency_sources = Native::Kernel::Source::FILES.to_h do |name, bytes|
  {name, Digest::SHA256.hexdigest(bytes)}
end
compiler_environment = ProcessControl::Platform::Unix::Helper.compiler_environment(compiler)
artifacts = {} of String => Hash(String, String)
fixtures = %w(darwin-reuse darwin-interruption)
fixtures.each do |name|
  source = File.join(root, "spec", "native", "#{name}.cr")
  output = File.join(destination, name)
  development = output + "-development"
  flags = %w(build --cross-compile --single-module --no-debug --error-on-warnings -Dwithout_main --emit llvm-ir)
  {% if compare_versions(Crystal::VERSION, "1.11.0") >= 0 %}
    flags << "-O0"
  {% end %}
  flags.concat([source, "-o", development])
  environment = compiler_environment.merge({"CRYSTAL_CACHE_DIR" => File.join(destination, "compiler")})
  File.open(output + ".build.log", "w") do |log|
    unless Process.run(compiler, flags, env: environment, output: log, error: log).success?
      abort "Development compilation failed. See #{output}.build.log"
    end
    unless Process.run(compiler,
             ["build", "--release", "--cross-compile", "--no-debug", "--error-on-warnings", "-Dwithout_main", "--emit", "llvm-ir", source, "-o", output],
             env: environment, output: log, error: log).success?
      abort "Release compilation failed. See #{output}.build.log"
    end
  end
  symbols = Set(String).new
  assembly = ProcessControl::Platform::Unix::Helper::Runtime.kernel_assembly
  [development + ".ll", output + ".ll"].each do |path|
    ProcessControl::Platform::Unix::Helper::Runtime.verify(File.read(path), native_symbols: symbols, assembly: assembly)
  end
  architecture = {{ flag?(:aarch64) ? "arm64" : "x86_64" }}
  File.open(output + ".build.log", "a") do |log|
    unless Process.run("cc", ["-arch", architecture, output + ".o", "-o", output, "-Wl,-dead_strip"],
             output: log, error: log).success?
      abort "Native fixture linking failed. See #{output}.build.log"
    end
  end
  imports = IO::Memory.new
  unless Process.run("xcrun", ["nm", "-u", output], output: imports, error: STDERR).success?
    abort "Native fixture import inspection failed."
  end
  abort "Native fixture imports external library symbols:\n#{imports}" unless imports.to_s.strip.empty?
  artifacts[name] = {
    "executable"     => Digest::SHA256.hexdigest(File.read(output)),
    "development_ir" => Digest::SHA256.hexdigest(File.read(development + ".ll")),
    "release_ir"     => Digest::SHA256.hexdigest(File.read(output + ".ll")),
    "native_symbols" => symbols.to_a.sort.join(" "),
    "assembly"       => assembly.to_a.sort.join("\n"),
  }
  puts "Audited development and release #{name}"
end
File.write(File.join(destination, "manifest.json"), {
  "compiler"           => Crystal::DESCRIPTION,
  "sources"            => sources,
  "dependency_sources" => dependency_sources,
  "artifacts"          => artifacts,
}.to_json)

environment = compiler_environment.merge({
  "PROCESS_CONTROL_DARWIN_QUALIFICATION"        => "1",
  "PROCESS_CONTROL_DARWIN_REUSE_FIXTURE"        => File.join(destination, "darwin-reuse"),
  "PROCESS_CONTROL_DARWIN_INTERRUPTION_FIXTURE" => File.join(destination, "darwin-interruption"),
  "CRYSTAL_CACHE_DIR"                           => File.join(destination, "spec-compiler"),
})
log_path = File.join(destination, "runtime.log")
passed = File.open(log_path, "w") do |log|
  Process.run(compiler,
    %w(spec spec/darwin_reuse_spec.cr spec/darwin_interruption_spec.cr --no-color --error-on-warnings),
    chdir: root, env: environment, output: log, error: log).success?
end
puts File.read(log_path)
abort "Darwin qualification failed. See #{log_path}" unless passed
sources.each do |name, digest|
  unless Digest::SHA256.hexdigest(File.read(File.join(root, name))) == digest
    abort "Qualification input changed during the run: #{name}"
  end
end
dependency_sources.each do |name, digest|
  unless Digest::SHA256.hexdigest(File.read(File.join(Native::Kernel::Source.root, name))) == digest
    abort "Qualification dependency input changed during the run: #{name}"
  end
end
ProcessControl::Platform::Unix::Helper.verify_sources!
