require "c/fcntl"
require "c/time"
require "c/unistd"

module ProcessControl::Internal::Linux
  module Pidfd
    # Linux x86-64 and AArch64 UAPI. The syscall entry points avoid a
    # requirement on libc's pidfd wrapper versions.
    private SYS_SEND_SIGNAL = 424_i64
    private SYS_OPEN        = 434_i64
    private SYS_PPOLL       = {{ flag?(:aarch64) ? 73_i64 : 271_i64 }}
    private DUPLICATE       =     1030 # F_DUPFD_CLOEXEC
    private INPUT           = 0x01_i16
    private HANGUP          = 0x10_i16

    private lib ABI
      struct Poll
        fd : Int32
        events : Int16
        revents : Int16
      end
    end

    def self.open(pid : Int32) : Int32
      LibC.syscall(SYS_OPEN, pid, 0_u32).to_i32
    end

    # An invalid descriptor cannot deliver a signal. EBADF establishes that
    # this caller can reach the syscall, with target permissions still unknown.
    def self.signal_probe : Errno
      send_signal(-1, ::Signal::CONT.value)
      Errno.value
    end

    def self.send_signal(fd : Int32, signal : Int32) : Int32
      LibC.syscall(SYS_SEND_SIGNAL, fd, signal, Pointer(Void).null, 0_u32).to_i32
    end

    def self.duplicate(fd : Int32) : Int32
      LibC.fcntl(fd, DUPLICATE, 0)
    end

    def self.observe(fd : Int32, identity : Identity) : Observation
      poll = ABI::Poll.new(fd: fd, events: INPUT)
      timeout = LibC::Timespec.new
      result = LibC.syscall(SYS_PPOLL, pointerof(poll), 1_u64, pointerof(timeout), Pointer(Void).null, 0_u64)
      if result < 0
        error = diagnostic("handle.observe", "ppoll", Errno.value)
        raise Observation::Failed.new("pidfd observation failed", error)
      end
      if result == 0
        return Observation.new(identity, presence: :present, termination: :alive)
      end
      events = poll.revents
      if (events & ~(INPUT | HANGUP)) != 0 || events == 0
        error = Diagnostic.new("handle.observe", "unexpected pidfd poll events #{events}", stage: "ppoll")
        raise Observation::Failed.new("pidfd observation failed", error)
      end
      presence = (events & HANGUP) != 0 ? Observation::Presence::Absent : Observation::Presence::Unknown
      Observation.new(identity, presence: presence, termination: :terminated)
    end

    def self.diagnostic(operation : String, stage : String, errno : Errno) : Diagnostic
      Diagnostic.new(operation, errno.message, native_domain: "errno", native_code: errno.value.to_i64, stage: stage)
    end
  end
end
