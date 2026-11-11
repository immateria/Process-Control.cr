require "./spec_helper"

{% if flag?(:linux) && !flag?(:android) && (flag?(:aarch64) || flag?(:x86_64)) %}
  describe "Linux delegated cgroup" do
    it "rejects a directory that is not on cgroup v2" do
      expect_raises(PC::Error::Unsupported) do
        PC::Platform::Linux::Cgroup.open("/tmp")
      end
    end

    if root = ENV["PROCESS_CONTROL_CGROUP_SPEC_ROOT"]?
      it "observes, freezes, thaws and kills an explicitly delegated domain" do
        directory = File.join(root, "process-control-#{Random::Secure.hex(12)}")
        Dir.mkdir(directory, 0o700)
        group = nil.as(PC::Group?)
        begin
          group = PC::Platform::Linux::Cgroup.open(directory)
          group.capabilities.binding.delegated?.should be_true
          group.observe.population.empty?.should be_true
          required = PC::Capability::Request.new([PC::Capability::Operation.new("group.birth")], :delegated)
          if birth = group.birth
            birth.path.should eq(directory)
            group.capabilities.supports?(required).should be_true
          else
            group.capabilities.supports?(required).should be_false
            if ENV["PROCESS_CONTROL_REQUIRE_CGROUP_BIRTH"]? == "1"
              raise "cgroup birth profile unavailable"
            end
          end
          group.suspend.effect.should be_a(PC::Control::Report::Success)
          deadline = PC::Wait::Deadline.after(5.seconds)
          while group.observe.frozen != true && !deadline.expired?
            deadline.pause
          end
          group.observe.frozen.should be_true
          group.resume.effect.should be_a(PC::Control::Report::Success)
          deadline = PC::Wait::Deadline.after(5.seconds)
          while group.observe.frozen != false && !deadline.expired?
            deadline.pause
          end
          group.observe.frozen.should be_false
          group.kill.effect.should be_a(PC::Control::Report::Success)
          group.wait_empty.state.completed?.should be_true
          group.birth.should be_nil
          group.close.complete?.should be_true
          Dir.exists?(directory).should be_true
        ensure
          group.try(&.close)
          Dir.delete(directory)
        end
      end

      it "refuses an attachment requirement for an explicitly delegated domain" do
        directory = File.join(root, "process-control-#{Random::Secure.hex(12)}")
        Dir.mkdir(directory, 0o700)
        begin
          operations = [PC::Capability::Operation.new("group.attach")]
          request = PC::Containment::Request.new(PC::Capability::Request.new(operations, :delegated))
          expect_raises(PC::Error::Unsupported) do
            PC::Platform::Linux::Cgroup.open(directory, request)
          end
        ensure
          Dir.delete(directory)
        end
      end
    end
  end
{% end %}
