module ProcessControl
  struct Observation
    enum Presence
      Present
      Absent
      Unknown
    end

    enum Termination
      Alive
      Terminated
      Unknown
    end

    enum Execution
      Runnable
      Stopped
      Suspended
      Zombie
      Unknown
    end

    class Failed < ProcessControl::Error; end

    getter identity : Identity
    getter presence : Presence
    getter termination : Termination
    getter execution : Execution
    getter sampled_at : Clock::Instant
    getter diagnostic : Diagnostic?
    getter exit_info : Wait::Exit::Info?

    def initialize(@identity, @presence = Presence::Unknown, @termination = Termination::Unknown,
                   @execution = Execution::Unknown, @diagnostic = nil, @sampled_at = Clock.now, *, @exit_info = nil)
      if @presence.absent? && (@termination.alive? || !@execution.unknown?)
        raise ArgumentError.new("absent process cannot have a live execution observation")
      end
      if @exit_info && !@termination.terminated?
        raise ArgumentError.new("exit status requires termination evidence")
      end
      if @execution.zombie? && !@termination.terminated?
        raise ArgumentError.new("zombie evidence requires termination evidence")
      end
    end
  end
end
