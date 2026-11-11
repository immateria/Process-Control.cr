require "./spec_helper"

{% if flag?(:darwin) %}
  module Fixture::Darwin::Bootstrap
    alias Kernel = PC::Internal::Darwin::Kernel
    EXAMPLE = "releases startup capacity when only the listener descriptor fits"
    NOFILE  = 8_u64 # Darwin's resource ABI, also used by the native helper.

    def self.children : Array(Int32)
      pids = Slice(Int32).new(65_536, 0)
      result = Kernel::Process.list(pids.to_unsafe.as(Void*), pids.bytesize)
      raise "could not enumerate fixture children" unless result.error == 0
      unless result.primary >= 0 && result.primary < pids.bytesize && result.primary % sizeof(Int32) == 0
        raise "fixture process roster is incomplete or malformed"
      end
      children = [] of Int32
      pids[0, result.primary.to_i32 // sizeof(Int32)].each do |pid|
        next if pid <= 0
        info = PC::Internal::Darwin::LibProc::Short.new
        sample = Kernel::Process.info(pid, PC::Internal::Darwin::LibProc::PIDT_SHORTBSDINFO,
          0_u64, pointerof(info).as(Void*), sizeof(PC::Internal::Darwin::LibProc::Short))
        next unless sample.error == 0
        raise "fixture process record is incomplete" unless sample.primary == sizeof(PC::Internal::Darwin::LibProc::Short)
        children << pid if info.ppid == Process.pid
      end
      children
    end

    def self.collect(pid : Int32) : Nil
      request = PC::Capability::Request.new(%w(handle.observe wait.exit control.kill)
        .map { |name| PC::Capability::Operation.new(name) }, :checked)
      handle = PC::Platform::Darwin.open(pid, required: request)
      begin
        handle.kill
        raise "fixture helper did not terminate" unless handle.wait_exit(deadline: PC::Wait::Deadline.after(5.seconds)).state.completed?
      ensure
        handle.close
      end
    end

    def self.pressure : Nil
      # This runs only in a disposable exec, with its own runtime and FD table.
      sleep 1.millisecond
      launcher = PC::Platform::Unix::Launcher.new(capacity: 1)
      PC::Internal.executable?(launcher.helper).should be_true
      command = PC::Command.new("/usr/bin/true").with_stdio(PC::Stream::Stdio.new(
        input: PC::Stream::Close.new, output: PC::Stream::Close.new, error: PC::Stream::Close.new))
      before = children
      original = LibC::Rlimit.new
      Kernel.call(194, NOFILE, pointerof(original).address).error.should eq(0)
      limited = original
      limited.rlim_cur = Math.min(original.rlim_cur, 64_u64)
      descriptors = [] of Int32
      attempt = nil.as(PC::Spawn::Result?)
      begin
        Kernel.call(195, NOFILE, pointerof(limited).address).error.should eq(0)
        loop do
          opened = Kernel.call(5, "/dev/null".to_unsafe.address, 0_u64, 0_u64)
          break if opened.error == Errno::EMFILE.value
          opened.error.should eq(0)
          descriptors << opened.primary.to_i32!
        end
        # The listener consumes this slot; accept must then fail before START.
        Kernel.call(6, descriptors.pop.to_u64!).error.should eq(0)
        attempt = command.spawn(launcher: launcher, deadline: PC::Wait::Deadline.after(250.milliseconds))
      ensure
        Kernel.call(195, NOFILE, pointerof(original).address).error.should eq(0)
        descriptors.each { |fd| Kernel.call(6, fd.to_u64!) }
      end
      verified = false
      begin
        attempt.should be_a(PC::Spawn::Rejected)
        deadline = PC::Wait::Deadline.after(5.seconds)
        until (children - before).empty? || deadline.expired?
          deadline.pause
        end
        (children - before).should be_empty
        resumed = command.spawn(launcher: launcher, deadline: PC::Wait::Deadline.after(5.seconds))
        if rejection = resumed.as?(PC::Spawn::Rejected)
          fail rejection.error.message
        end
        following = resumed.as(PC::Spawn::Started).child
        begin
          following.wait_exit(deadline: PC::Wait::Deadline.after(5.seconds)).info.not_nil!.success?.should be_true
        ensure
          following.close
        end
        verified = true
      ensure
        # A failing implementation may have left a suspended helper behind.
        (children - before).each { |pid| collect(pid) } unless verified
      end
    end
  end

  describe "Darwin direct helper bootstrap" do
    it Fixture::Darwin::Bootstrap::EXAMPLE do
      if ENV["PROCESS_CONTROL_BOOTSTRAP_PRESSURE"]? == "1"
        Fixture::Darwin::Bootstrap.pressure
      else
        output = IO::Memory.new
        result = Process.run(Process.executable_path.not_nil!, ["--example", Fixture::Darwin::Bootstrap::EXAMPLE],
          env: {"PROCESS_CONTROL_BOOTSTRAP_PRESSURE" => "1", "PROCESS_CONTROL_HELPER" => PC::Platform::Unix::Helper.path},
          output: output, error: output)
        fail output.to_s unless result.success?
      end
    end
  end
{% end %}
