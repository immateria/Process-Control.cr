require "./spec_helper"

{% if flag?(:darwin) %}
  module Fixture::Darwin::Reuse
    class Registration < PC::Internal::Darwin::Native
      getter ports = 0
      getter queues = 0

      def initialize(@phase : Symbol, &@advance : -> Nil)
      end

      def register_watch(fd : Int32, pid : Int32) : Nil
        @advance.call if @phase == :before
        super
        @advance.call if @phase == :after
      end

      def close_watch(fd : Int32) : Int32
        @queues += 1
        super
      end

      def release(port : UInt32) : Int32
        @ports += 1
        super
      end
    end

    def self.line(process : Process) : Array(String)
      line = process.output.gets || raise "native factory ended without receipt"
      puts line
      line.split
    end

    def self.receive(channel : Channel(T)) : T forall T
      select
      when value = channel.receive
        value
      when timeout(5.seconds)
        raise "native registration gate timed out"
      end
    end

    def self.collect(process : Process, owner : PC::Handle?) : Nil
      finished = Channel(String?).new(1)
      spawn do
        begin
          process.wait
          finished.send(nil)
        rescue ex
          finished.send(ex.message || ex.class.name)
        end
      end
      select
      when failure = finished.receive
      when timeout(10.seconds)
        owner.try(&.kill)
        failure = receive(finished)
      end
      raise "native fixture collection failed: #{failure}" if failure
    end
  end

  if ENV["PROCESS_CONTROL_DARWIN_QUALIFICATION"]? == "1"
    describe "actual Darwin PID reuse" do
      it "collects the unreleased target when the caller closes the control pipe" do
        factory = Process.new(ENV["PROCESS_CONTROL_DARWIN_REUSE_FIXTURE"],
          input: Process::Redirect::Pipe, output: Process::Redirect::Pipe, error: STDERR)
        factory.output.read_timeout = 5.seconds
        fixture_owner = nil.as(PC::Handle?)
        target = nil.as(PC::Handle?)
        collected = false
        begin
          fixture_owner = PC::Handle.open(factory.pid, required: PC::Capability::Request.control)
          first = Fixture::Darwin::Reuse.line(factory)
          first[0].should eq("ORIGINAL")
          target = PC::Handle.open(first[1].to_i, required: PC::Capability::Request.wait)
          factory.input.close
          receipt = Fixture::Darwin::Reuse.line(factory)
          receipt.should eq(["ABORTED", (23 << 8).to_s])
          factory.wait.exit_code.should eq(73)
          collected = true
          target.wait_exit(deadline: PC::Wait::Deadline.after(5.seconds)).state.completed?.should be_true
        ensure
          begin
            factory.input.close unless factory.input.closed?
            Fixture::Darwin::Reuse.collect(factory, fixture_owner) unless collected
          ensure
            target.try(&.close)
            fixture_owner.try(&.close)
          end
        end
      end

      it "retains old evidence and refuses both real registration races after replacement" do
        factory = Process.new(ENV["PROCESS_CONTROL_DARWIN_REUSE_FIXTURE"], input: Process::Redirect::Pipe, output: Process::Redirect::Pipe, error: STDERR)
        factory.output.read_timeout = 60.seconds
        fixture_owner = nil.as(PC::Handle?)
        original = nil.as(PC::Handle?)
        copy = nil.as(PC::Handle?)
        control = nil.as(PC::Handle?)
        replacement = nil.as(PC::Handle?)
        collected = false
        entered = Channel(Nil).new(2)
        proceed = Channel(Nil).new(2)
        finished = Channel(Bool).new(2)
        drivers = [] of Fixture::Darwin::Reuse::Registration
        workers = 0
        completed = 0
        gates_released = false
        begin
          fixture_owner = PC::Handle.open(factory.pid, required: PC::Capability::Request.control)
          first = Fixture::Darwin::Reuse.line(factory)
          first[0].should eq("ORIGINAL")
          pid = first[1].to_i
          request = PC::Capability::Request.new(
            %w(handle.observe wait.exit control.kill).map { |name| PC::Capability::Operation.new(name) }, :checked)
          original = PC::Handle.open(pid, required: request)
          copy = original.duplicate(required: request)
          control = PC::Handle.open(pid, required: PC::Capability::Request.control)
          previous = original.identity
          puts "original generation=#{previous.generation.not_nil!.value}"
          [:before, :after].each do |phase|
            driver = Fixture::Darwin::Reuse::Registration.new(phase) do
              entered.send(nil)
              proceed.receive
            end
            drivers << driver
            workers += 1
            spawn do
              begin
                handle = PC::Internal::Darwin::Authority.acquire(pid, required: request, driver: driver)
                handle.close
                finished.send(false)
              rescue PC::Identity::Mismatch
                finished.send(true)
              rescue ex
                STDERR.puts ex.inspect_with_backtrace
                finished.send(false)
              end
            end
          end
          2.times { Fixture::Darwin::Reuse.receive(entered) }
          factory.input.write_byte(99_u8)
          factory.input.flush
          reaped = Fixture::Darwin::Reuse.line(factory)
          reaped[0].should eq("REAPED")
          reaped[1].to_i.should eq(23 << 8)
          deadline = PC::Wait::Deadline.after(180.seconds)
          loop do
            receipt = Fixture::Darwin::Reuse.line(factory)
            if receipt[0] == "REUSED"
              receipt[1].to_i.should eq(pid)
              break
            end
            receipt[0].should eq("PROGRESS")
            raise "PID allocator did not reuse original within budget" if deadline.expired?
          end
          births = Fixture::Darwin::Reuse.line(factory)
          births[0].should eq("BIRTHS")
          births[1].to_i.should be <= 250_000
          replacement = PC::Handle.open(pid, required: request)
          replacement.identity.pid.should eq(previous.pid)
          replacement.identity.generation.not_nil!.value.should_not eq(previous.generation.not_nil!.value)
          puts "replacement generation=#{replacement.identity.generation.not_nil!.value}"
          workers.times { proceed.send(nil) }
          gates_released = true
          workers.times do
            matched = Fixture::Darwin::Reuse.receive(finished)
            completed += 1
            matched.should be_true
          end
          drivers.each do |driver|
            driver.ports.should eq(1)
            driver.queues.should eq(1)
          end
          expect_raises(PC::Identity::Mismatch) { PC::Handle.open(pid, required: request, expected: previous) }
          [original, copy].each do |held|
            exit = held.wait_exit(deadline: PC::Wait::Deadline.after(5.seconds))
            exit.state.completed?.should be_true
            exit.observation.identity.should eq(previous)
            exit.observation.termination.terminated?.should be_true
            failure = held.kill.disposition.as(PC::Control::Report::Failure).diagnostic
            failure.native_domain.should eq("errno")
            failure.native_code.should eq(Errno::ESRCH.value)
            replacement.wait_exit(deadline: PC::Wait::Deadline.after(Time::Span.zero)).state.expired?.should be_true
          end
          control.observe.presence.unknown?.should be_true
          [:request_stop, :kill, :suspend, :resume].each do |operation|
            result = case operation
                     when :request_stop then control.request_stop
                     when :kill         then control.kill
                     when :suspend      then control.suspend
                     else                    control.resume
                     end
            result.disposition.as(PC::Control::Report::Failure).diagnostic.native_code.should eq(Errno::ESRCH.value)
            factory.input.write_byte(112_u8)
            factory.input.flush
            receipt = Fixture::Darwin::Reuse.line(factory)
            receipt.should eq(["ALIVE", "37"])
            replacement.wait_exit(deadline: PC::Wait::Deadline.after(Time::Span.zero)).state.expired?.should be_true
          end
          replacement.observe.presence.present?.should be_true
          replacement.wait_exit(deadline: PC::Wait::Deadline.after(Time::Span.zero)).state.expired?.should be_true
          replacement.kill.disposition.should be_a(PC::Control::Report::Success)
          replacement.wait_exit(deadline: PC::Wait::Deadline.after(5.seconds)).state.completed?.should be_true
          factory.input.write_byte(99_u8)
          factory.input.flush
          target = Fixture::Darwin::Reuse.line(factory)
          target[0].should eq("COLLECTED")
          target[1].to_i.should eq(9)
          factory.wait.success?.should be_true
          collected = true
          puts "stale token delivery=ESRCH; replacement survived until checked kill; native parent collected SIGKILL"
        ensure
          begin
            workers.times { proceed.send(nil) } unless gates_released
            while completed < workers
              Fixture::Darwin::Reuse.receive(finished)
              completed += 1
            end
          ensure
            begin
              replacement.try(&.kill)
            ensure
              begin
                factory.input.close unless factory.input.closed?
                Fixture::Darwin::Reuse.collect(factory, fixture_owner) unless collected
              ensure
                replacement.try(&.close)
                control.try(&.close)
                copy.try(&.close)
                original.try(&.close)
                fixture_owner.try(&.close)
              end
            end
          end
        end
      end
    end
  end
{% end %}
