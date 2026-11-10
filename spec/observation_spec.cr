require "./spec_helper"

{% if flag?(:darwin) || (flag?(:linux) && !flag?(:android)) %}
  describe "existing process observation" do
    it "propagates a terminal protocol failure through the handle wait" do
      left, right = UNIXSocket.pair
      session = PC::Internal::Unix::Session.new(left, "fixture-token", Process.pid, 32)
      right.close
      source = session.source.wait_exit(deadline: PC::Wait::Deadline.after(1.second))
      source.state.failed?.should be_true
      handle = PC::Handle.new(PC::Internal::Unix::Authority.new(session))
      begin
        handle.observe.diagnostic.should_not be_nil
        handle.wait_exit(deadline: PC::Wait::Deadline.after(Time::Span.zero)).state.failed?.should be_true
      ensure
        handle.close
      end
    end

    it "keeps PID presence separate from termination and control authority" do
      observation = PC.observe(Process.pid)
      observation.presence.present?.should be_true
      observation.termination.unknown?.should be_true
      handle = PC::Handle.open(Process.pid, required: PC::Capability::Request.observation)
      begin
        handle.kill.disposition.should be_a(PC::Control::Refused)
        handle.wait_exit.state.failed?.should be_true
        {% unless flag?(:darwin) %}
          expect_raises(PC::Error::Unsupported) do
            PC::Handle.open(Process.pid, required: PC::Capability::Request.control)
          end
        {% end %}
        expected = PC::Identity.new(Process.pid, generation: PC::Identity::Generation.new("unavailable", "expected"))
        expect_raises(PC::Identity::Unverifiable) do
          PC::Handle.open(Process.pid, expected: expected)
        end
      ensure
        handle.close
      end
    end
  end
{% end %}
