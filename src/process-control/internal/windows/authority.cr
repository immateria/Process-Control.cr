module ProcessControl::Internal::Windows
  class Authority < Control::Authority
    MECHANISM = "windows-process-handle"

    getter identity : ProcessControl::Identity
    getter capabilities : Capability::Snapshot
    @release_mutex = Mutex.new
    @release : Control::Release::Result? = nil

    def initialize(@handle : LibC::HANDLE, @identity, @capabilities)
    end

    def self.profile(*, terminate : Bool) : Capability::Snapshot
      operations = %w(handle.observe wait.exit)
      operations << "control.kill" if terminate
      Capability::Snapshot.new(operations.map { |name| Capability::Operation.new(name) }, :retained, MECHANISM)
    end

    def self.acquire(pid : Int, required : Capability::Request, expected : ProcessControl::Identity?) : Handle
      raise ArgumentError.new("process identifier is outside native range") unless pid > 0 && pid <= UInt32::MAX
      terminate = required.operations.any? { |operation| operation.name == "control.kill" }
      capabilities = profile(terminate: terminate)
      raise Error::Unsupported.new("Windows process handle cannot satisfy requested authority") unless capabilities.supports?(required)
      access = QUERY | WAIT
      access |= TERMINATE if terminate
      native = LibC.OpenProcess(access, false, pid.to_u32)
      if native.null?
        code = WinError.value
        if code == WinError::ERROR_INVALID_PARAMETER
          raise Error::Missing.new("process is absent", Windows.diagnostic("OpenProcess", code))
        end
        raise Windows.error("OpenProcess", code)
      end

      identity = ProcessControl::Identity.new(pid)
      begin
        identity = Windows.identify(native, pid)
        if expected
          case identity.compare(expected)
          when .different?
            raise ProcessControl::Identity::Mismatch.new("expected process identity differs")
          when .indeterminate?
            raise ProcessControl::Identity::Unverifiable.new("expected generation cannot be established")
          end
        end
        Handle.new(new(native, identity, capabilities), required: required)
      rescue ex
        owner = Handle.new(new(native, identity, capabilities))
        cleanup = owner.close
        raise Handle::Acquisition::Failed.new(ex, owner) unless cleanup.complete?
        raise ex
      end
    end

    def observe : ProcessControl::Observation
      Windows.observe(@handle, @identity)
    end

    def wait_failure(observation : ProcessControl::Observation) : Wait::Failure?
      if detail = observation.diagnostic
        Wait::Failure.new(ProcessControl::Observation::Failed.new("Windows exit observation failed", detail))
      end
    end

    def perform(request : Control::Request, *, deadline : Wait::Deadline, cancel : Wait::Cancellation?) : Control::Result
      disposition = if request.is_a?(Control::Kill::Request) && @capabilities.operations.any? { |operation| operation.name == "control.kill" }
                      terminate(request.exit_code || 1_u32)
                    else
                      Control::Refused.new(Error::Unsupported.new("Windows handle does not support requested control"))
                    end
      Control::Result.new(request, @identity, disposition, MECHANISM)
    end

    private def terminate(code : UInt32) : Control::Disposition
      observation = observe
      if observation.termination.terminated?
        return Control::Satisfied.new(observation)
      end
      if LibC.TerminateProcess(@handle, code) == 0
        Control::Report::Failure.new(Windows.diagnostic("TerminateProcess"))
      else
        Control::Report::Success.new("TerminateProcess accepted the request")
      end
    end

    def duplicate : Control::Authority
      Authority.new(Windows.duplicate(@handle), @identity, @capabilities)
    end

    def release(*, deadline : Wait::Deadline, cancel : Wait::Cancellation?) : Control::Release::Result
      @release_mutex.synchronize do
        if previous = @release
          return previous
        end
        result = Windows.release(@handle, "Windows process handle", deadline, cancel)
        @release = result unless result.state.retryable?
        result
      end
    end
  end
end
