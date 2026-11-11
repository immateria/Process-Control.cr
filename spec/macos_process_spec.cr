require "./spec_helper"
require "./native_spec"

{% if flag?(:darwin) %}
  describe "macOS native session launch" do
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
