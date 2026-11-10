module ProcessControl
  class Group
    @mutex = Mutex.new
    @admission_closed = false
    @closed = false
    @inflight = 0
    @effects = 0
    @generation = 0_u64
    @launches = Set(Spawn::Pending).new
    @cleanup_busy = false
    @release_result : Control::Release::Result? = nil

    def initialize(@controller : Containment::Controller, request : Containment::Request = Containment::Request.new)
      unless @controller.capabilities.supports?(request.required)
        raise Error::Unsupported.new("controller does not satisfy containment requirements")
      end
    end

    def self.create(request : Containment::Request = Containment::Request.new, *, controller : Containment::Controller? = nil) : Containment::Creation::Result
      unless controller
        return Containment::Creation::Rejected.new(Error::Unsupported.new("no native containment profile is qualified"))
      end
      Containment::Creation::Created.new(new(controller, request))
    rescue ex : Error
      Containment::Creation::Rejected.new(ex)
    end

    def identity : Containment::Identity?
      @controller.identity
    end

    def capabilities : Capability::Snapshot
      @controller.capabilities
    end

    def closed? : Bool
      @mutex.synchronize { @closed }
    end

    def observe : Containment::Observation
      sample
    end

    def pending_launches : Array(Spawn::Pending)
      @mutex.synchronize { @launches.to_a }
    end

    def release_result : Control::Release::Result?
      @mutex.synchronize { @release_result }
    end

    def admit_spawn(&launch : -> Spawn::Result) : Spawn::Result
      admitted = @mutex.synchronize do
        unless @admission_closed || @closed
          @inflight += 1
          @generation &+= 1
          true
        end
      end
      return Spawn::Rejected.new(Error::Closed.new("group launch admission is closed")) unless admitted
      retained = false
      begin
        result = launch.call
        if pending = result.as?(Spawn::Pending)
          @mutex.synchronize { @launches.add(pending) }
          pending.on_settle { finish(pending) }
          retained = true
        end
        result
      ensure
        finish unless retained
      end
    end

    def spawn(command : Command, *, launcher : Spawn::Launcher? = nil, required : Capability::Request = Capability::Request.child,
              deadline : Wait::Deadline = Wait::Deadline.none, cancel : Wait::Cancellation? = nil) : Spawn::Result
      command.spawn(group: self, launcher: launcher, required: required, deadline: deadline, cancel: cancel)
    end

    def wait_empty(*, deadline : Wait::Deadline = Wait::Deadline.none, cancel : Wait::Cancellation? = nil) : Containment::Drain::Result
      loop do
        before = @mutex.synchronize { @generation }
        was_closed = closed?
        observation = was_closed ? Containment::Observation.new(identity) : sample
        inflight, admission, closed, after = @mutex.synchronize { {@inflight, @admission_closed, @closed, @generation} }
        state = if closed
                  Wait::State::Closed
                elsif before == after && observation.population.empty? && inflight == 0
                  Wait::State::Completed
                elsif cancel.try(&.cancelled?)
                  Wait::State::Cancelled
                elsif deadline.expired?
                  Wait::State::Expired
                end
        return Containment::Drain::Result.new(state, observation, inflight, admission) if state
        deadline.pause
      end
    rescue ex : Error
      inflight, admission, closed = @mutex.synchronize { {@inflight, @admission_closed, @closed} }
      observation = Containment::Observation.new(identity, diagnostic: ex.diagnostic)
      state = closed ? Wait::State::Closed : Wait::State::Failed
      Containment::Drain::Result.new(state, observation, inflight, admission, closed ? nil : Wait::Failure.new(ex))
    end

    def request_stop(request : Control::Stop::Request = Control::Stop::Request.new, *, deadline : Wait::Deadline = Wait::Deadline.none, cancel : Wait::Cancellation? = nil) : Control::Group::Result
      control(request, deadline: deadline, cancel: cancel)
    end

    def kill(request : Control::Kill::Request = Control::Kill::Request.new, *, deadline : Wait::Deadline = Wait::Deadline.none, cancel : Wait::Cancellation? = nil) : Control::Group::Result
      control(request, deadline: deadline, cancel: cancel)
    end

    def shutdown(*, policy : Control::Shutdown::Policy = Control::Shutdown::Policy.new, deadline : Wait::Deadline = Wait::Deadline.none,
                 cancel : Wait::Cancellation? = nil) : Control::Shutdown::Result
      @mutex.synchronize { @admission_closed = true }
      phases = [] of Control::Group::Result
      while @mutex.synchronize { @inflight > 0 }
        if deadline.expired? || cancel.try(&.cancelled?) || closed?
          drain = wait_empty(deadline: Wait::Deadline.after(Time::Span.zero), cancel: cancel)
          return Control::Shutdown::Result.new(drain.state, drain, phases, pending_launches)
        end
        deadline.pause
      end
      drain = wait_empty(deadline: Wait::Deadline.after(Time::Span.zero), cancel: cancel)
      return Control::Shutdown::Result.new(drain.state, drain, phases, pending_launches) if drain.state.completed? || closed? || cancel.try(&.cancelled?)
      unless deadline.expired?
        if stop = policy.stop
          phases << control(stop, deadline: deadline, cancel: cancel)
          grace = Wait::Deadline.after(policy.grace)
          if outer = deadline.at
            grace = Wait::Deadline.new(outer) if outer < grace.at.not_nil!
          end
          drain = wait_empty(deadline: grace, cancel: cancel)
        end
        unless drain.state.completed? || cancel.try(&.cancelled?) || deadline.expired?
          if kill = policy.kill
            phases << control(kill, deadline: deadline, cancel: cancel)
          end
          drain = wait_empty(deadline: deadline, cancel: cancel)
        end
      end
      Control::Shutdown::Result.new(drain.state, drain, phases, pending_launches)
    end

    def close(*, deadline : Wait::Deadline = Wait::Deadline.none, cancel : Wait::Cancellation? = nil) : Control::Release::Result
      @mutex.synchronize do
        @closed = true
        @admission_closed = true
        if existing = @release_result
          return existing
        end
      end
      cleanup(deadline: deadline, cancel: cancel)
    end

    def retry_cleanup(*, deadline : Wait::Deadline = Wait::Deadline.none, cancel : Wait::Cancellation? = nil) : Control::Release::Result
      raise Error::Ownership.new("cleanup requires a closed group") unless closed?
      cleanup(deadline: deadline, cancel: cancel)
    end

    private def control(request : Control::Request, *, deadline : Wait::Deadline, cancel : Wait::Cancellation?) : Control::Group::Result
      refusal = if closed?
                  Error::Closed.new("group is closed")
                elsif cancel.try(&.cancelled?) || (deadline.expired? && !deadline.immediate?)
                  Error.new("group control budget ended before admission")
                elsif !capabilities.supports?(Capability::Request.new([Capability::Operation.new(request.operation)]))
                  Error::Unsupported.new("group control operation unavailable")
                end
      return Control::Group::Result.new(request, [] of Control::Result, capabilities.mechanism, refusal) if refusal
      admitted = @mutex.synchronize do
        unless @closed
          @effects += 1
          true
        end
      end
      unless admitted
        return Control::Group::Result.new(request, [] of Control::Result, capabilities.mechanism, Error::Closed.new("group is closed"))
      end
      retained = false
      begin
        result = @controller.control(request, deadline: deadline, cancel: cancel)
        owners = result.reports.flat_map(&.pending_owners).uniq
        unless owners.empty?
          count = owners.size
          guard = Mutex.new
          owners.each do |owner|
            owner.on_settle do
              done = guard.synchronize { count -= 1; count == 0 }
              finish_effect if done
            end
          end
          retained = true
        end
        result
      ensure
        finish_effect unless retained
      end
    end

    private def sample : Containment::Observation
      @mutex.synchronize do
        raise Error::Closed.new("group is closed") if @closed
        @effects += 1
      end
      begin
        @controller.observe
      ensure
        finish_effect
      end
    end

    private def finish(pending : Spawn::Pending? = nil) : Nil
      @mutex.synchronize do
        @inflight -= 1
        @generation &+= 1
        @launches.delete(pending) if pending
      end
    end

    private def finish_effect : Nil
      @mutex.synchronize { @effects -= 1 }
    end

    private def cleanup(*, deadline : Wait::Deadline, cancel : Wait::Cancellation?) : Control::Release::Result
      @mutex.synchronize do
        if (existing = @release_result) && !existing.state.retryable? && !existing.retry_participants?
          return existing
        end
        if @inflight > 0 || @effects > 0 || @cleanup_busy
          result = Control::Release::Result.new([Control::Release::Record.new("admitted group work", :retryable)])
          @release_result = result
          return result
        end
        @cleanup_busy = true
      end
      begin
        previous = release_result
        result = if previous && previous.retry_participants?
                   previous.retry_participants(deadline: deadline, cancel: cancel)
                 else
                   @controller.release(deadline: deadline, cancel: cancel)
                 end
      rescue ex
        result = Control::Release::Result.new([Control::Release::Record.new("group authority", :uncertain,
          Diagnostic.new("group.release", ex.message || ex.class.name))])
      end
      @mutex.synchronize do
        @release_result = result
        @cleanup_busy = false
      end
      result
    end
  end
end
