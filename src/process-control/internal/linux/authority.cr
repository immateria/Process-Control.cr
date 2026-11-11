module ProcessControl::Internal::Linux
  class Authority < Control::Authority
    MECHANISM = "linux-pidfd"
    private WAIT      = %w(handle.observe wait.exit).map { |name| Capability::Operation.new(name) }
    private CONTROL   = %w(control.stop control.kill control.signal control.suspend control.resume)
      .map { |name| Capability::Operation.new(name) }

    getter identity : ProcessControl::Identity
    getter capabilities : Capability::Snapshot
    @mutex = Mutex.new
    @release : Control::Release::Result? = nil

    def self.acquire(pid : Int, *, required : Capability::Request, expected : ProcessControl::Identity?) : Handle
      raise ArgumentError.new("process identifier is outside native range") unless pid > 0 && pid <= Int32::MAX
      full = Capability::Snapshot.new(WAIT + CONTROL, :retained, MECHANISM)
      raise Error::Unsupported.new("pidfd authority does not satisfy the requested profile") unless full.supports?(required)
      identity = ProcessControl::Identity.new(pid)
      if expected
        comparison = identity.compare(expected)
        raise Identity::Mismatch.new("expected process identity differs") if comparison.different?
        raise Identity::Unverifiable.new("expected identity cannot be established by pidfd acquisition") if comparison.indeterminate?
      end

      # The retained fd itself is authoritative. The public identity remains
      # PID-only because no portable pidfd generation token is exported.
      signal_probe = Pidfd.signal_probe
      capabilities = signal_probe == Errno::EBADF ? full : Capability::Snapshot.new(WAIT, :retained, MECHANISM)
      unless capabilities.supports?(required)
        diagnostic = Pidfd.diagnostic("handle.open", "pidfd_send_signal", signal_probe)
        raise Error::Unsupported.new("pidfd signaling is unavailable to the caller", diagnostic)
      end
      context = Process.pid
      fd = Pidfd.open(pid.to_i32)
      raise open_error(Errno.value) if fd < 0
      authority = new(fd, identity, capabilities, context)
      owner = Handle.new(authority, required: required)
      begin
        authority.observe
        owner
      rescue ex
        cleanup = owner.close
        raise Handle::Acquisition::Failed.new(ex, owner) unless cleanup.complete?
        raise ex
      end
    end

    def initialize(@fd : Int32, @identity, @capabilities, @context : Int64)
    end

    def observe : ProcessControl::Observation
      check_context!
      @mutex.synchronize do
        check_open!
        Pidfd.observe(@fd, @identity)
      end
    end

    def perform(request : Control::Request, *, deadline : Wait::Deadline, cancel : Wait::Cancellation?) : Control::Result
      check_context!
      @mutex.synchronize do
        check_open!
        if cancel.try(&.cancelled?) || (deadline.expired? && !deadline.immediate?)
          return refused(request, Error.new("control cancelled or budget expired before native delivery"))
        end
        number = case request
                 when Control::Stop::Request then ::Signal::TERM.value
                 when Control::Kill::Request
                   return refused(request, Error::Unsupported.new("explicit exit codes are unavailable on Linux")) if request.exit_code
                   ::Signal::KILL.value
                 when Control::Suspend::Request then ::Signal::STOP.value
                 when Control::Resume::Request  then ::Signal::CONT.value
                 when Control::Signal
                   return refused(request, Error::Unsupported.new("signal domain is not POSIX")) unless request.domain == "posix"
                   request.value
                 else
                   return refused(request, Error::Unsupported.new("unknown control request"))
                 end
        result = Pidfd.send_signal(@fd, number)
        errno = Errno.value
        disposition = if result == 0
                        Control::Report::Success.new("pidfd signal #{number} accepted")
                      else
                        Control::Report::Failure.new(Pidfd.diagnostic(request.operation, "pidfd_send_signal", errno))
                      end
        Control::Result.new(request, @identity, disposition, MECHANISM)
      end
    rescue ex : ProcessControl::Error
      refused(request, ex)
    end

    def duplicate : Control::Authority
      check_context!
      @mutex.synchronize do
        check_open!
        fd = Pidfd.duplicate(@fd)
        if fd < 0
          raise Error::Ownership.new("pidfd duplication failed", Pidfd.diagnostic("handle.duplicate", "fcntl", Errno.value))
        end
        self.class.new(fd, @identity, @capabilities, @context)
      end
    end

    def release(*, deadline : Wait::Deadline, cancel : Wait::Cancellation?) : Control::Release::Result
      return retryable("pidfd belongs to another process context") if Process.pid != @context
      @mutex.synchronize do
        if previous = @release
          return previous
        end
        if cancel.try(&.cancelled?) || (deadline.expired? && !deadline.immediate?)
          return retryable("pidfd close was not attempted within its budget")
        end
        @release = if LibC.close(@fd) == 0
                     Control::Release::Result.complete
                   else
                     diagnostic = Pidfd.diagnostic("handle.close", "close", Errno.value)
                     Control::Release::Result.new([Control::Release::Record.new("Linux pidfd", :uncertain, diagnostic)])
                   end
      end
    end

    private def check_context! : Nil
      raise Error::Context::Mismatch.new("pidfd belongs to another process context") unless Process.pid == @context
    end

    private def check_open! : Nil
      raise Error::Closed.new("pidfd is closed") if @release
    end

    private def refused(request : Control::Request, reason : Error) : Control::Result
      Control::Result.new(request, @identity, Control::Refused.new(reason), MECHANISM)
    end

    private def retryable(message : String) : Control::Release::Result
      diagnostic = Diagnostic.new("handle.close", message, stage: "before-release")
      Control::Release::Result.new([Control::Release::Record.new("Linux pidfd", :retryable, diagnostic)])
    end

    private def self.open_error(errno : Errno) : Error
      diagnostic = Pidfd.diagnostic("handle.open", "pidfd_open", errno)
      case errno
      when Errno::ESRCH
        Error::Missing.new("process is absent", diagnostic)
      when Errno::EACCES, Errno::EPERM
        Error::Access::Denied.new("pidfd acquisition denied", diagnostic)
      when Errno::ENOSYS, Errno::ENODEV
        Error::Unsupported.new("pidfd acquisition is unavailable", diagnostic)
      else
        Error.new("pidfd acquisition failed", diagnostic)
      end
    end
  end
end
