require "./spec_helper"
require "./native_spec"

{% if flag?(:darwin) || (flag?(:linux) && !flag?(:android)) %}
  describe "Unix target setup" do
    it "executes a new session leader while the helper still owns child status" do
      command = Fixture.captured("ps -o pgid= -p $$; exit 42").with(PC::Spawn::Session.new)
      child = Fixture.native(command)
      begin
        result = child.complete(deadline: PC::Wait::Deadline.after(5.seconds))
        String.new(result.output.not_nil!.bytes).strip.to_i64.should eq(child.handle.identity.pid)
        result.child.info.not_nil!.code.should eq(42_u32)
      ensure
        child.close
      end
    end

    it "enforces a byte-sized file limit on the target before exec" do
      directory = "/tmp/process-control-limit-#{Random::Secure.hex(10)}"
      Dir.mkdir(directory, 0o700)
      file = File.join(directory, "limited")
      begin
        command = Fixture.captured("exec /bin/dd if=/dev/zero of=limited bs=1024 count=4")
          .with_cwd(directory)
          .with(PC::Resource::Limit.new(:file, 1024))
        child = Fixture.native(command)
        begin
          result = child.complete(deadline: PC::Wait::Deadline.after(5.seconds))
          result.child.info.not_nil!.success?.should be_false
          File.size(file).should eq(1024)
        ensure
          child.close
        end
      ensure
        File.delete(file) if File.exists?(file)
        Dir.delete(directory)
      end
    end

    it "accounts for failed target setup without executing the program" do
      directory = "/tmp/process-control-setup-#{Random::Secure.hex(10)}"
      Dir.mkdir(directory, 0o700)
      wrapper = File.join(directory, "invalid-setup")
      marker = File.join(directory, "executed")
      File.write(wrapper, <<-SH)
        #!/bin/sh
        path=$1 token=$2
        shift 2
        exec "$PROCESS_CONTROL_REAL_HELPER" "$path" "$token" --limit invalid 1 1 "$@"
        SH
      File.chmod(wrapper, 0o700)
      begin
        launcher = PC::Platform::Unix::Launcher.new(wrapper)
        command = Fixture.captured("printf executed > \"$PROCESS_CONTROL_MARKER\"")
          .with_env({"PROCESS_CONTROL_REAL_HELPER" => PC::Platform::Unix::Helper.path, "PROCESS_CONTROL_MARKER" => marker})
        result = command.spawn(launcher: launcher, deadline: PC::Wait::Deadline.after(5.seconds)).as(PC::Spawn::Rejected)
        result.attempted.should be_true
        result.cleanup.complete?.should be_true
        diagnostic = result.error.diagnostic.not_nil!
        diagnostic.stage.should eq("setup")
        diagnostic.native_domain.should eq("errno")
        diagnostic.native_code.should eq(Errno::EINVAL.value.to_i64)
        File.exists?(marker).should be_false
      ensure
        File.delete(marker) if File.exists?(marker)
        File.delete(wrapper)
        Dir.delete(directory)
      end
    end
  end
{% end %}
