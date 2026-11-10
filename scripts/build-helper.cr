require "file_utils"
require "random/secure"
require "../src/process-control/platform/unix/helper"

{% unless flag?(:darwin) || (flag?(:linux) && !flag?(:android)) %}
  abort "The Unix helper supports macOS and Linux."
{% end %}

destination = ARGV[0]? || ProcessControl::Platform::Unix::Helper.path
FileUtils.mkdir_p(File.dirname(destination), mode: 0o700)
temporary = "#{destination}.#{Process.pid}.#{Random::Secure.hex(8)}"
begin
  status = Process.run(ENV["CC"]? || "cc",
    ["-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", ProcessControl::Platform::Unix::Helper.source, "-o", temporary],
    output: STDOUT, error: STDERR)
  abort "Native helper compilation failed." unless status.success?
  File.chmod(temporary, 0o700)
  File.rename(temporary, destination)
  puts destination
ensure
  File.delete(temporary) if File.exists?(temporary)
end
