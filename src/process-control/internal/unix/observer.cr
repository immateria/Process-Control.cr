module ProcessControl::Internal::Unix
  class Observer < Control::Authority
    getter identity : ProcessControl::Identity

    def initialize(@identity)
    end

    def self.sample(pid : Int) : ProcessControl::Observation
      raise ArgumentError.new("process identifier is outside native range") unless pid > 0 && pid <= Int32::MAX
      identity = ProcessControl::Identity.new(pid)
      if LibC.kill(pid.to_i32, 0) == 0
        return ProcessControl::Observation.new(identity, presence: :present)
      end
      error = Errno.value
      if error == Errno::ESRCH
        ProcessControl::Observation.new(identity, presence: :absent)
      else
        diagnostic = Diagnostic.new("observe", error.message, native_domain: "errno", native_code: error.value.to_i64)
        presence = error == Errno::EPERM || error == Errno::EACCES ? ProcessControl::Observation::Presence::Present : ProcessControl::Observation::Presence::Unknown
        ProcessControl::Observation.new(identity, presence: presence, diagnostic: diagnostic)
      end
    end

    def capabilities : Capability::Snapshot
      Capability::Snapshot.new([Capability::Operation.new("handle.observe")], :sampled, "unix-pid-query")
    end

    def observe : ProcessControl::Observation
      self.class.sample(@identity.pid)
    end

    def perform(request : Control::Request, *, deadline : Wait::Deadline, cancel : Wait::Cancellation?) : Control::Result
      reason = Error::Unsupported.new("a sampled PID is not control authority")
      Control::Result.new(request, @identity, Control::Refused.new(reason), "unix-pid-query")
    end

    def duplicate : Control::Authority
      Observer.new(@identity)
    end

    def release(*, deadline : Wait::Deadline, cancel : Wait::Cancellation?) : Control::Release::Result
      Control::Release::Result.complete
    end
  end
end

module ProcessControl
  def self.observe(pid : Int) : Observation
    Internal::Unix::Observer.sample(pid)
  end
end
