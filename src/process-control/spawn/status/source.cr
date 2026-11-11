module ProcessControl::Spawn::Status
  class Source
    getter identity : ProcessControl::Identity
    @mutex = Mutex.new
    @terminal : Wait::Child::Result? = nil

    def initialize(@identity)
    end

    def latest : Wait::Child::Result?
      @mutex.synchronize { @terminal }
    end

    def publish(info : Wait::Exit::Info) : Nil
      store(Wait::Child::Result.new(:completed, @identity, info, :terminated))
    end

    def fail(error : ProcessControl::Error, *, termination : Observation::Termination = Observation::Termination::Unknown, info : Wait::Exit::Info? = nil) : Nil
      store(Wait::Child::Result.new(:failed, @identity, info, termination: termination, failure: Wait::Failure.new(error)))
    end

    def wait_exit(*, deadline : Wait::Deadline = Wait::Deadline.none, cancel : Wait::Cancellation? = nil) : Wait::Child::Result
      loop do
        if terminal = latest
          return terminal
        end
        if cancel.try(&.cancelled?)
          return Wait::Child::Result.new(:cancelled, @identity)
        end
        return Wait::Child::Result.new(:expired, @identity) if deadline.expired?
        deadline.pause
      end
    end

    private def store(result : Wait::Child::Result) : Nil
      @mutex.synchronize do
        raise ProcessControl::Error::Ownership.new("child status already collected") if @terminal
        @terminal = result
      end
    end
  end
end
