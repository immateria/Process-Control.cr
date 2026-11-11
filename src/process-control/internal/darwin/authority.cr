module ProcessControl::Internal::Darwin
  class Authority < Control::Authority
    MECHANISM       = "darwin-audit-token-v1"
    WATCH_MECHANISM = "darwin-audit-token-kqueue-v1"
    OBSERVE         = Capability::Operation.new("handle.observe")
    WAIT            = Capability::Operation.new("wait.exit")
    SIGNALS         = %w(control.stop control.kill control.signal control.suspend control.resume)
      .map { |name| Capability::Operation.new(name) }

    getter identity : ProcessControl::Identity
    @token : Token? = nil
    @watch : Watch? = nil
    @watch_bound = false
    @mutex = Mutex.new
    @release_result : Control::Release::Result? = nil

    def self.profile(signaling : Bool, waiting : Bool) : Capability::Snapshot
      operations = [OBSERVE]
      operations.concat(SIGNALS) if signaling
      operations << WAIT if waiting
      Capability::Snapshot.new(operations, :checked, waiting ? WATCH_MECHANISM : MECHANISM)
    end

    def self.acquire(pid : Int, *, required : Capability::Request, expected : ProcessControl::Identity? = nil, driver : Driver) : Handle
      raise ArgumentError.new("process identifier is outside native range") unless pid > 0 && pid <= Int32::MAX
      operations = required.operations
      waiting = operations.includes?(WAIT)
      signaling = !waiting || operations.any? { |operation| SIGNALS.includes?(operation) }
      unless profile(signaling, waiting).supports?(required)
        raise Error::Unsupported.new("Darwin authority does not satisfy the requested profile")
      end
      raise Error::Unsupported.new("audit-token signaling is unavailable") if signaling && !driver.available?
      context = driver.context
      port, code = driver.open(pid.to_i32)
      raise mach_error("handle.open", "task-name", code) unless code == 0
      if port == 0
        raise Identity::Unverifiable.new("native acquisition returned a null Mach reference")
      end
      authority = new(port, ProcessControl::Identity.new(pid), driver, context, signaling)
      owner = Handle.new(authority, required: Capability::Request.new([] of Capability::Operation))
      begin
        authority.capture
        if expected
          comparison = authority.identity.compare(expected)
          raise Identity::Mismatch.new("expected process identity differs") if comparison.different?
          raise Identity::Unverifiable.new("expected identity cannot be established") if comparison.indeterminate?
        end
        authority.register_watch if waiting
        owner
      rescue ex
        cleanup = owner.close
        raise Handle::Acquisition::Failed.new(ex, owner) unless cleanup.complete?
        raise ex
      end
    end

    def initialize(@port : UInt32, @identity, @driver : Driver, @context : Int64, @signaling : Bool)
    end

    def capture : Nil
      check_context!
      raise Error::Ownership.new("audit token has already been acquired") if @token
      words, count, code = @driver.read(@port)
      check_context!
      raise self.class.mach_error("handle.open", "audit-token", code) unless code == 0
      raise Identity::Unverifiable.new("audit token has an unexpected native size") unless count == 8
      token = Token.new(words)
      raise Identity::Mismatch.new("audit token names a different PID") unless token.pid == @identity.pid
      @token = token
      @identity = token.identity
    end

    def capabilities : Capability::Snapshot
      return Capability::Snapshot.new([] of Capability::Operation, :checked, MECHANISM) unless @token
      self.class.profile(@signaling, @watch_bound)
    end

    protected def register_watch : Nil
      check!
      pid = @identity.pid.to_i32
      fd = @driver.open_watch
      @watch = Watch.new(fd, @identity, @driver)
      @driver.register_watch(fd, pid)
      # The Mach token precedes PID registration. A fresh PID lookup after
      # registration rules out binding an event from a replacement process.
      unless @driver.watch_version(pid) == @token.not_nil!.version
        raise Identity::Mismatch.new("Darwin exit watch names a different PID generation")
      end
      check_context!
      @watch_bound = true
    end

    def observe : ProcessControl::Observation
      check!
      if observation = @watch.try(&.observe)
        return observation
      end
      words, count, code = @driver.read(@port)
      if code != 0
        diagnostic = self.class.mach_error("handle.observe", "observation", code).diagnostic
        return ProcessControl::Observation.new(@identity, diagnostic: diagnostic)
      end
      token = Token.new(words)
      if count != 8 || token.pid != @token.not_nil!.pid || token.version != @token.not_nil!.version
        diagnostic = Diagnostic.new("handle.observe", "native identity could not be matched", stage: "audit-token")
        return ProcessControl::Observation.new(@identity, diagnostic: diagnostic)
      end
      ProcessControl::Observation.new(@identity, presence: :present)
    end

    def wait_failure : Wait::Failure?
      @watch.try(&.failure)
    end

    def perform(request : Control::Request, *, deadline : Wait::Deadline, cancel : Wait::Cancellation?) : Control::Result
      begin
        check!
      rescue ex : ProcessControl::Error
        return refused(request, ex)
      end
      return refused(request, Error::Unsupported.new("audit-token signaling was not acquired")) unless @signaling
      if cancel.try(&.cancelled?) || (deadline.expired? && !deadline.immediate?)
        return refused(request, Error.new("control cancelled or budget expired before native delivery"))
      end
      number = case request
               when Control::Stop::Request then ::Signal::TERM.value
               when Control::Kill::Request
                 return refused(request, Error::Unsupported.new("Windows exit code is unavailable on Darwin")) if request.exit_code
                 ::Signal::KILL.value
               when Control::Suspend::Request then ::Signal::STOP.value
               when Control::Resume::Request  then ::Signal::CONT.value
               when Control::Signal
                 return refused(request, Error::Unsupported.new("signal domain is not POSIX")) unless request.domain == "posix"
                 request.value
               else
                 return refused(request, Error::Unsupported.new("unknown control request"))
               end
      return refused(request, Error::Unsupported.new("signal is outside the native range")) unless number > 0 && number < 32
      code = @driver.signal(@token.not_nil!, number)
      disposition = if code == 0
                      Control::Report::Success.new("native signal #{number} accepted")
                    else
                      Control::Report::Failure.new(Diagnostic.new(request.operation, "native audit-token signal failed",
                        native_domain: "errno", native_code: code.to_i64, stage: "signal"))
                    end
      Control::Result.new(request, @identity, disposition, MECHANISM)
    end

    def duplicate : Control::Authority
      check!
      code = @driver.retain(@port)
      raise self.class.mach_error("handle.duplicate", "duplicate", code) unless code == 0
      copy = self.class.new(@port, @identity, @driver, @context, @signaling)
      copy.bind(@token.not_nil!, @watch)
      copy
    end

    protected def bind(token : Token, watch : Watch?) : Nil
      @token = token
      watch.try(&.retain)
      @watch = watch
      @watch_bound = !watch.nil?
    end

    def release(*, deadline : Wait::Deadline, cancel : Wait::Cancellation?) : Control::Release::Result
      if @driver.context != @context
        return retryable("Mach reference belongs to another process context")
      end
      @mutex.synchronize do
        if previous = @release_result
          return previous
        end
        if cancel.try(&.cancelled?) || (deadline.expired? && !deadline.immediate?)
          return retryable("native release was not attempted within its budget")
        end
        records = [] of Control::Release::Record
        if record = @watch.try(&.release)
          records << record
        end
        code = @driver.release(@port)
        if code != 0
          diagnostic = self.class.mach_error("handle.close", "release", code).diagnostic
          records << Control::Release::Record.new("Darwin task-name reference", :uncertain, diagnostic)
        end
        @release_result = Control::Release::Result.new(records)
      end
    end

    private def retryable(message : String) : Control::Release::Result
      diagnostic = Diagnostic.new("handle.close", message, stage: "before-release")
      records = [Control::Release::Record.new("Darwin task-name reference", :retryable, diagnostic)]
      records << Control::Release::Record.new("Darwin exit watch", :retryable, diagnostic) if @watch
      Control::Release::Result.new(records)
    end

    private def check_context! : Nil
      raise Error::Context::Mismatch.new("Mach reference belongs to another process context") unless @driver.context == @context
    end

    private def check! : Nil
      check_context!
      raise Error::Closed.new("native reference is closed") if @mutex.synchronize { !@release_result.nil? }
      raise Error::Ownership.new("audit token has not been acquired") unless @token
    end

    private def refused(request : Control::Request, reason : ProcessControl::Error) : Control::Result
      Control::Result.new(request, @identity, Control::Refused.new(reason), MECHANISM)
    end

    def self.mach_error(operation : String, stage : String, code : Int32) : ProcessControl::Error
      diagnostic = Diagnostic.new(operation, "Mach operation failed", native_domain: "kern_return_t", native_code: code.to_i64, stage: stage)
      if code == ::Native::Kernel::Darwin::ABI::KERN_PROTECTION_FAILURE || code == ::Native::Kernel::Darwin::ABI::KERN_NO_ACCESS
        Error::Access::Denied.new("Mach reference access denied", diagnostic)
      else
        Observation::Failed.new("Mach reference operation failed", diagnostic)
      end
    end
  end
end
