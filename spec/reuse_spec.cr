require "./spec_helper"
require "./native_spec"

{% if flag?(:linux) && !flag?(:android) %}
  if ENV["PROCESS_CONTROL_PID_REUSE_SPEC"]? == "1"
    describe "isolated Linux PID reuse" do
      it "collects the target when Crystal may have a cached status for the helper's reused PID" do
        # The opt-in probe writes only the last-PID allocator of a disposable
        # user/PID namespace whose PID 1 is this spec binary.
        Process.pid.should eq(1)
        File.readlink("/proc/self").should eq("1")
        mapping = File.read("/proc/self/uid_map").split
        mapping.size.should eq(3)
        mapping[0].should eq("0")
        mapping[1].to_i64.should be > 0
        mapping[2].should eq("1")

        ::Process.run("/bin/true").success?.should be_true
        pid = LibC.fork
        LibC._exit(91) if pid == 0
        pid.should be > 1
        deadline = PC::Wait::Deadline.after(5.seconds)
        while LibC.kill(pid, 0) == 0 && !deadline.expired?
          deadline.pause
        end
        LibC.kill(pid, 0).should eq(-1)
        Errno.value.should eq(Errno::ESRCH)

        File.write("/proc/sys/kernel/ns_last_pid", (pid - 1).to_s)
        child = Fixture.native(Fixture.captured("printf '%s' \"$PPID\"; exit 37"))
        begin
          result = child.complete(deadline: PC::Wait::Deadline.after(5.seconds))
          String.new(result.output.not_nil!.bytes).to_i32.should eq(pid)
          result.child.info.not_nil!.code.should eq(37_u32)
        ensure
          child.close
        end
      end
    end
  end
{% end %}
