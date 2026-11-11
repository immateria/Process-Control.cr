require "./spec_helper"
require "./support/cgroup"

{% if flag?(:linux) && !flag?(:android) && (flag?(:aarch64) || flag?(:x86_64)) %}
  if (root = ENV["PROCESS_CONTROL_CGROUP_SPEC_ROOT"]?) && ENV["PROCESS_CONTROL_REQUIRE_CGROUP_BIRTH"]? == "1"
    describe "Linux cgroup birth placement" do
      it "rejects a cgroup directory with the wrong retained identity" do
        directory = File.join(root, "process-control-#{Random::Secure.hex(12)}")
        Dir.mkdir(directory, 0o700)
        fixture = "/tmp/process-control-identity-#{Random::Secure.hex(10)}"
        Dir.mkdir(fixture, 0o700)
        wrapper = File.join(fixture, "mismatched-cgroup")
        File.write(wrapper, <<-SH)
          #!/bin/sh
          path=$1 token=$2
          shift 2
          exec "$PROCESS_CONTROL_REAL_HELPER" "$path" "$token" --cgroup "$PROCESS_CONTROL_GROUP" 0 0 "$@"
          SH
        File.chmod(wrapper, 0o700)
        begin
          launcher = PC::Platform::Unix::Launcher.new(wrapper)
          command = PC::Command.new("/bin/true").with_env({
            "PROCESS_CONTROL_REAL_HELPER" => PC::Platform::Unix::Helper.path,
            "PROCESS_CONTROL_GROUP"       => directory,
          })
          launch = command.spawn(launcher: launcher, deadline: PC::Wait::Deadline.after(5.seconds))
          if launch.is_a?(PC::Spawn::Pending)
            launch = launch.abort(deadline: PC::Wait::Deadline.after(5.seconds))
          end
          launch.as?(PC::Spawn::Started).try { |started| started.child.close }
          diagnostic = launch.as(PC::Spawn::Rejected).error.diagnostic.not_nil!
          diagnostic.stage.should eq("setup")
          diagnostic.native_code.should eq(Errno::ESTALE.value.to_i64)
        ensure
          File.delete(wrapper)
          Dir.delete(fixture)
          Dir.delete(directory)
        end
      end

      it "rejects a real pathname replacement after admitting the original cgroup" do
        directory = File.join(root, "process-control-#{Random::Secure.hex(12)}")
        fixture = "/tmp/process-control-replacement-#{Random::Secure.hex(10)}"
        Dir.mkdir(directory, 0o700)
        Dir.mkdir(fixture, 0o700)
        marker = File.join(fixture, "workload")
        proceed = File.join(fixture, "proceed")
        controller = Fixture::Linux::Controller.new(directory, Fixture::Linux.wrapper(fixture, "cgroup-gate"))
        group = PC::Group.new(controller)
        substitute = nil.as(PC::Group?)
        child = nil.as(PC::Child?)
        pending = nil.as(PC::Spawn::Pending?)
        begin
          original = group.birth.not_nil!
          command = Fixture::Linux.command(
            PC::Command.new("/bin/sh", ["-c", "cat /proc/self/cgroup > \"$1\"", "sh", marker]), fixture)
          pending = group.spawn(command, deadline: PC::Wait::Deadline.after(Time::Span.zero)).as(PC::Spawn::Pending)
          ready = File.join(fixture, "ready")
          Fixture::Linux.await { File.exists?(ready) }
          File.read(ready).should eq("#{directory} #{original.device} #{original.inode}")
          group.pending_launches.should eq([pending])
          group.observe.population.empty?.should be_true

          Dir.delete(directory)
          Dir.mkdir(directory, 0o700)
          substitute = PC::Platform::Linux::Cgroup.open(directory)
          replacement = substitute.birth.not_nil!
          replacement.device.should eq(original.device)
          replacement.inode.should_not eq(original.inode)
          File.write(proceed, "release")

          result = pending.resolve(deadline: PC::Wait::Deadline.after(5.seconds))
          child = result.as?(PC::Spawn::Started).try(&.child)
          rejected = result.as(PC::Spawn::Rejected)
          rejected.attempted.should be_true
          rejected.cleanup.complete?.should be_true
          diagnostic = rejected.error.diagnostic.not_nil!
          diagnostic.stage.should eq("setup")
          diagnostic.native_domain.should eq("errno")
          diagnostic.native_code.should eq(Errno::ESTALE.value.to_i64)
          File.exists?(marker).should be_false
          substitute.observe.population.empty?.should be_true
          group.pending_launches.should be_empty
          pending = nil

          # A new controller can use the replacement. This keeps an unrelated
          # launch failure from satisfying the stale-identity assertions.
          valid = PC::Command.new("/bin/sh", ["-c", "cat /proc/self/cgroup > \"$1\"", "sh", marker])
          child = substitute.spawn(valid, deadline: PC::Wait::Deadline.after(5.seconds)).as(PC::Spawn::Started).child
          child.wait_exit(deadline: PC::Wait::Deadline.after(5.seconds)).info.not_nil!.code.should eq(0_u32)
          File.read(marker).strip.should eq("0::#{directory.lchop("/sys/fs/cgroup")}")
        ensure
          File.write(proceed, "release")
          pending.try { |ticket| ticket.abort(deadline: PC::Wait::Deadline.after(5.seconds)) }
          child.try(&.close)
          substitute.try(&.close)
          group.close
          Dir.delete(directory)
          Fixture::Linux.remove(fixture)
        end
      end

      it "retains the admission when STARTED is lost after confirmed cgroup birth" do
        directory = File.join(root, "process-control-#{Random::Secure.hex(12)}")
        fixture = "/tmp/process-control-started-#{Random::Secure.hex(10)}"
        Dir.mkdir(directory, 0o700)
        Dir.mkdir(fixture, 0o700)
        gate = File.join(fixture, "target-gate")
        target = File.join(fixture, "target")
        started = File.join(fixture, "started")
        collected = File.join(fixture, "collected")
        controller = Fixture::Linux::Controller.new(directory, Fixture::Linux.wrapper(fixture, "drop-started"))
        group = PC::Group.new(controller)
        script = <<-SH
          printf '%s' "$$" > "$1.tmp"
          mv "$1.tmp" "$1"
          attempt=0
          while [ ! -e "$2" ] && [ "$attempt" -lt 400 ]; do
            sleep 0.01
            attempt=$((attempt + 1))
          done
          exit 37
          SH
        command = Fixture::Linux.command(PC::Command.new("/bin/sh", ["-c", script, "sh", target, gate]), fixture)
        begin
          ticket = group.spawn(command, deadline: PC::Wait::Deadline.after(Time::Span.zero)).as(PC::Spawn::Pending)
          Fixture::Linux.await do
            ticket.diagnostic.stage == "acknowledgment" && File.exists?(started) && File.exists?(target)
          end
          pid = File.read(started).to_i64
          File.read(target).to_i64.should eq(pid)
          File.read("/proc/#{pid}/cgroup").strip.split(':', 3).last.should eq(directory.lchop("/sys/fs/cgroup"))
          group.observe.population.populated?.should be_true

          policy = PC::Control::Shutdown::Policy.new(kill: PC::Control::Kill::Request.new)
          shutdown = group.shutdown(policy: policy, deadline: PC::Wait::Deadline.after(20.milliseconds))
          shutdown.state.expired?.should be_true
          shutdown.drain.inflight.should eq(1)
          shutdown.pending_launches.should eq([ticket])
          shutdown.phases.should be_empty
          group.spawn(command).as(PC::Spawn::Rejected).attempted.should be_false
          ticket.abort(deadline: PC::Wait::Deadline.after(Time::Span.zero)).as(PC::Spawn::Pending).same?(ticket).should be_true

          File.write(gate, "release")
          Fixture::Linux.await { File.exists?(collected) }
          File.read(collected).should eq("0")
          group.observe.population.empty?.should be_true
          drain = group.wait_empty(deadline: PC::Wait::Deadline.after(Time::Span.zero))
          drain.state.expired?.should be_true
          drain.inflight.should eq(1)
          group.pending_launches.should eq([ticket])
          group.close.state.retryable?.should be_true
          group.retry_cleanup.state.retryable?.should be_true
          expect_raises(PC::Error::Ownership) { ticket.close }
        ensure
          File.write(gate, "release")
          # The fixture owns this controller separately. Its target has a
          # bounded lifetime, so dispose its descriptors after the public
          # ownership assertions without inventing a recovered launch result.
          Fixture::Linux.await { controller.observe.population.empty? }
          controller.release(deadline: PC::Wait::Deadline.none, cancel: nil).complete?.should be_true
          Dir.delete(directory)
          Fixture::Linux.remove(fixture)
        end
      end

      it "starts inside the cgroup and drains descendants across sessions" do
        directory = File.join(root, "process-control-#{Random::Secure.hex(12)}")
        Dir.mkdir(directory, 0o700)
        group = nil.as(PC::Group?)
        child = nil.as(PC::Child?)
        begin
          group = PC::Platform::Linux::Cgroup.open(directory)
          script = <<-SH
            IFS= read -r membership < /proc/self/cgroup
            printf '%s\n' "$membership"
            setsid /bin/sh -c 'printf "separate session\n"; exec sleep 30' &
            wait
            SH
          stdio = PC::Stream::Stdio.new(output: PC::Stream::Pipe.new)
          command = PC::Command.new("/bin/sh", ["-c", script]).with_stdio(stdio)
          plan = command.prepare(group: group)
          direct = PC::Platform::Unix::Launcher.default.launch(plan, deadline: PC::Wait::Deadline.none, cancel: nil)
          direct.as(PC::Spawn::Attempt::Rejected).result.error.should be_a(PC::Error::Ownership)
          group.admit_spawn do
            group.suspend.refusal.should be_a(PC::Error::Ownership)
            PC::Spawn::Rejected.new(PC::Error.new("fixture did not start a target"))
          end
          group.suspend.effect.should be_a(PC::Control::Report::Success)
          group.spawn(command).as(PC::Spawn::Rejected).attempted.should be_false
          group.resume.effect.should be_a(PC::Control::Report::Success)
          thaw = PC::Wait::Deadline.after(5.seconds)
          while group.observe.frozen == true && !thaw.expired?
            thaw.pause
          end
          group.observe.frozen.should eq(false)
          launch = group.spawn(command, deadline: PC::Wait::Deadline.after(5.seconds))
          if launch.is_a?(PC::Spawn::Pending)
            launch.abort(deadline: PC::Wait::Deadline.after(5.seconds))
          end
          raise launch.error if launch.is_a?(PC::Spawn::Rejected)
          child = launch.as(PC::Spawn::Started).child
          output = child.streams.output.not_nil!
          output.native.read_timeout = 5.seconds
          output.gets.should eq("0::#{directory.lchop("/sys/fs/cgroup")}")
          output.gets.should eq("separate session")
          group.observe.population.populated?.should be_true

          policy = PC::Control::Shutdown::Policy.new(kill: PC::Control::Kill::Request.new)
          shutdown = group.shutdown(policy: policy, deadline: PC::Wait::Deadline.after(5.seconds))
          shutdown.state.completed?.should be_true
          shutdown.phases.last.effect.should be_a(PC::Control::Report::Success)
          child.wait_exit(deadline: PC::Wait::Deadline.after(5.seconds)).info.not_nil!.signal.should eq(9)
          output.gets.should be_nil
          group.spawn(command).should be_a(PC::Spawn::Rejected)
        ensure
          if group
            group.kill unless group.closed?
            group.wait_empty(deadline: PC::Wait::Deadline.after(5.seconds))
            group.close
          end
          child.try(&.close)
          Dir.delete(directory)
        end
      end
    end
  end
{% end %}
