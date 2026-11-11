require "../spec_helper"

{% if flag?(:linux) && !flag?(:android) && (flag?(:aarch64) || flag?(:x86_64)) %}
  module Fixture::Linux
    # The real controller retains its descriptors and native behavior. Only the
    # trusted helper path is replaced so the tests can gate the launch protocol.
    class Controller < PC::Internal::Linux::Cgroup
      getter launcher : PC::Platform::Unix::Launcher

      def initialize(path : String, helper : String)
        @launcher = PC::Platform::Unix::Launcher.new(helper)
        super(path)
        capture
      end
    end

    def self.await(&condition : -> Bool) : Nil
      deadline = PC::Wait::Deadline.after(5.seconds)
      until condition.call
        raise "Linux fixture did not reach its gate" if deadline.expired?
        deadline.pause
      end
    end

    def self.wrapper(directory : String, mode : String) : String
      path = File.join(directory, "helper")
      File.write(path, <<-SH)
        #!/bin/sh
        export PROCESS_CONTROL_LINUX_FIXTURE="#{mode}"
        exec "$PROCESS_CONTROL_SPEC_BINARY" "$@"
        SH
      File.chmod(path, 0o700)
      path
    end

    def self.command(command : PC::Command, directory : String) : PC::Command
      command.with_env({
        "PROCESS_CONTROL_LINUX_DIRECTORY" => directory,
        "PROCESS_CONTROL_REAL_HELPER"     => PC::Platform::Unix::Helper.path,
        "PROCESS_CONTROL_SPEC_BINARY"     => Process.executable_path.not_nil!,
      })
    end

    def self.remove(directory : String) : Nil
      Dir.children(directory).each { |name| File.delete(File.join(directory, name)) }
      Dir.delete(directory)
    end
  end
{% end %}
