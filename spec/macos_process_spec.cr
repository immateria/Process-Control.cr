require "./spec_helper"
require "./native_spec"

{% if flag?(:darwin) %}
  describe "macOS native session launch" do
    it "collects target memory and CPU usage with a repeatable terminal result" do
      script = "BEGIN { s = \"0123456789abcdef\"; for (i = 0; i < 20; i++) s = s s; if (length(s) != 16777216) exit 91; exit 37 }"
      command = PC::Command.new("/usr/bin/awk", [script]).with_stdio(
        PC::Stream::Stdio.new(input: PC::Stream::Close.new,
          output: PC::Stream::Close.new, error: PC::Stream::Close.new))
      child = Fixture.native(command)
      cleanup = child.handle.duplicate
      begin
        child.close
        result = child.wait_exit(deadline: PC::Wait::Deadline.after(10.seconds))
        result.state.completed?.should be_true
        info = result.info.not_nil!
        info.code.should eq(37_u32)
        usage = info.usage.not_nil!
        usage.domain.should eq("darwin.wait4")
        usage.max_rss_bytes.should be >= 16_777_216_i64
        (usage.user.to_span + usage.system.to_span).should be > Time::Span.zero
        repeated = child.wait_exit(deadline: PC::Wait::Deadline.after(Time::Span.zero)).info.not_nil!
        repeated.usage.not_nil!.max_rss_bytes.should eq(usage.max_rss_bytes)
        repeated.usage.not_nil!.user.seconds.should eq(usage.user.seconds)
        repeated.usage.not_nil!.user.microseconds.should eq(usage.user.microseconds)
      ensure
        cleanup.kill(deadline: PC::Wait::Deadline.after(5.seconds))
        child.wait_exit(deadline: PC::Wait::Deadline.after(5.seconds))
        cleanup.close(deadline: PC::Wait::Deadline.after(5.seconds))
        child.close
      end
    end

    it "preserves accounting when the collected target dies from a signal" do
      child = Fixture.native(Fixture.captured("kill -TERM $$; exit 99"))
      begin
        info = child.wait_exit(deadline: PC::Wait::Deadline.after(5.seconds)).info.not_nil!
        info.signal.should eq(Signal::TERM.value)
        info.usage.not_nil!.max_rss_bytes.should be > 0
      ensure
        child.handle.kill(deadline: PC::Wait::Deadline.after(5.seconds))
        child.wait_exit(deadline: PC::Wait::Deadline.after(5.seconds))
        child.close
      end
    end

    it "keeps the live target as session and group leader without changing its parent" do
      parent_session = Native::Kernel::Darwin::Process.getsid
      parent_group = Native::Kernel::Darwin::Process.getpgid
      parent_session.error.should eq(0)
      parent_group.error.should eq(0)
      command = PC::Command.new("/bin/sh", ["-c", "read -r release; test \"$release\" = complete || exit 90; exit 43"])
        .with_stdio(PC::Stream::Stdio.new(input: PC::Stream::Pipe.new,
          output: PC::Stream::Close.new, error: PC::Stream::Close.new))
        .with(PC::Spawn::Session.new)
      child = Fixture.native(command)
      begin
        pid = child.identity.pid.to_i32
        session = Native::Kernel::Darwin::Process.getsid(pid)
        group = Native::Kernel::Darwin::Process.getpgid(pid)
        session.error.should eq(0)
        group.error.should eq(0)
        session.primary.should eq(pid)
        group.primary.should eq(pid)
        own_session = Native::Kernel::Darwin::Process.getsid
        own_group = Native::Kernel::Darwin::Process.getpgid
        own_session.error.should eq(0)
        own_group.error.should eq(0)
        own_session.primary.should eq(parent_session.primary)
        own_group.primary.should eq(parent_group.primary)
        child.wait_exit(deadline: PC::Wait::Deadline.after(Time::Span.zero)).state.expired?.should be_true
        child.streams.input.not_nil!.puts "complete"
        child.streams.close_input
        result = child.complete(deadline: PC::Wait::Deadline.after(5.seconds))
        result.state.completed?.should be_true
        result.child.info.not_nil!.code.should eq(43_u32)
      ensure
        child.streams.close_input
        child.handle.kill(deadline: PC::Wait::Deadline.after(5.seconds))
        child.wait_exit(deadline: PC::Wait::Deadline.after(5.seconds))
        child.close(deadline: PC::Wait::Deadline.after(5.seconds))
      end
    end
  end
{% end %}
