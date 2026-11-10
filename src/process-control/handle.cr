module ProcessControl
  class Handle
    def self.open(pid : Int, *, required : Capability::Request = Capability::Request.observation, expected : Identity? = nil) : Handle
      {% if flag?(:darwin) %}
        if required.binding.try(&.checked?) || required.operations.any? { |operation| operation.name.starts_with?("control.") }
          return Platform::Darwin.open(pid, required: required, expected: expected)
        end
      {% end %}
      {% if flag?(:darwin) || (flag?(:linux) && !flag?(:android)) %}
        observation = Internal::Unix::Observer.sample(pid)
        raise Error::Missing.new("process is absent") if observation.presence.absent?
        raise Observation::Failed.new("process presence is unknown", observation.diagnostic) if observation.presence.unknown?
        if expected
          case observation.identity.compare(expected)
          when Identity::Comparison::Different
            raise Identity::Mismatch.new("expected process identity differs")
          when Identity::Comparison::Indeterminate
            raise Identity::Unverifiable.new("expected generation cannot be established")
          end
        end
        new(Internal::Unix::Observer.new(observation.identity), required: required)
      {% else %}
        raise Error::Unsupported.new("existing-process acquisition is not implemented on this platform")
      {% end %}
    end

    @mutex = Mutex.new
    @closed = false
    @inflight = 0
    @cleanup_busy = false
    @release_result : Control::Release::Result? = nil

    def initialize(@authority : Control::Authority, *, required : Capability::Request = Capability::Request.observation)
      unless @authority.capabilities.supports?(required)
        raise Error::Unsupported.new("authority does not satisfy the requested profile")
      end
    end

    def identity : Identity
      @authority.identity
    end

    def capabilities(*, refresh : Bool = false) : Capability::Snapshot
      @authority.capabilities
    end

    def closed? : Bool
      @mutex.synchronize { @closed }
    end

    def release_result : Control::Release::Result?
      @mutex.synchronize { @release_result }
    end

    def observe : Observation
      admit!
      begin
        @authority.observe
      ensure
        finish
      end
    end

    def duplicate(*, required : Capability::Request = Capability::Request.observation) : Handle
      admit!
      begin
        raise Error::Unsupported.new("duplicate profile unavailable") unless capabilities.supports?(required)
        authority = @authority.duplicate
        owner = Handle.new(authority, required: Capability::Request.new([] of Capability::Operation))
        begin
          comparison = authority.identity.compare(identity)
          raise Identity::Mismatch.new("duplicated identity differs") if comparison.different?
          raise Identity::Unverifiable.new("duplicated identity cannot be verified") if comparison.indeterminate?
          raise Error::Unsupported.new("duplicate lacks requested authority") unless authority.capabilities.supports?(required)
          owner
        rescue ex
          cleanup = owner.close
          raise Acquisition::Failed.new(ex, owner) unless cleanup.complete?
          raise ex
        end
      ensure
        finish
      end
    end

    def wait_exit(*, deadline : Wait::Deadline = Wait::Deadline.none, cancel : Wait::Cancellation? = nil) : Wait::Exit::Result
      loop do
        return Wait::Exit::Result.new(:closed, Observation.new(identity)) if closed?
        unless capabilities.supports?(Capability::Request.wait)
          error = Error::Unsupported.new("authority cannot wait for this process incarnation")
          return Wait::Exit::Result.new(:failed, Observation.new(identity), Wait::Failure.new(error))
        end
        observation = observe
        if failure = @authority.wait_failure
          return Wait::Exit::Result.new(:failed, observation, failure)
        end
        return Wait::Exit::Result.new(:completed, observation) if observation.termination.terminated?
        return Wait::Exit::Result.new(:cancelled, observation) if cancel.try(&.cancelled?)
        return Wait::Exit::Result.new(:expired, observation) if deadline.expired?
        deadline.pause
      end
    rescue ex : Error::Closed
      Wait::Exit::Result.new(:closed, Observation.new(identity))
    rescue ex : Error
      Wait::Exit::Result.new(:failed, Observation.new(identity), Wait::Failure.new(ex))
    end

    def request_stop(request : Control::Stop::Request = Control::Stop::Request.new, *, deadline : Wait::Deadline = Wait::Deadline.none, cancel : Wait::Cancellation? = nil) : Control::Result
      control(request, deadline: deadline, cancel: cancel)
    end

    def kill(request : Control::Kill::Request = Control::Kill::Request.new, *, deadline : Wait::Deadline = Wait::Deadline.none, cancel : Wait::Cancellation? = nil) : Control::Result
      control(request, deadline: deadline, cancel: cancel)
    end

    def signal(signal : Control::Signal, *, deadline : Wait::Deadline = Wait::Deadline.none, cancel : Wait::Cancellation? = nil) : Control::Result
      control(signal, deadline: deadline, cancel: cancel)
    end

    def suspend(request : Control::Suspend::Request = Control::Suspend::Request.new, *, deadline : Wait::Deadline = Wait::Deadline.none, cancel : Wait::Cancellation? = nil) : Control::Result
      control(request, deadline: deadline, cancel: cancel)
    end

    def resume(request : Control::Resume::Request = Control::Resume::Request.new, *, deadline : Wait::Deadline = Wait::Deadline.none, cancel : Wait::Cancellation? = nil) : Control::Result
      control(request, deadline: deadline, cancel: cancel)
    end

    def close(*, deadline : Wait::Deadline = Wait::Deadline.none, cancel : Wait::Cancellation? = nil) : Control::Release::Result
      existing = @mutex.synchronize do
        @closed = true
        @release_result
      end
      existing || cleanup(deadline: deadline, cancel: cancel)
    end

    def retry_cleanup(*, deadline : Wait::Deadline = Wait::Deadline.none, cancel : Wait::Cancellation? = nil) : Control::Release::Result
      raise Error::Ownership.new("cleanup retry requires a closed owner") unless closed?
      cleanup(deadline: deadline, cancel: cancel)
    end

    private def control(request : Control::Request, *, deadline : Wait::Deadline, cancel : Wait::Cancellation?) : Control::Result
      if closed?
        return refused(request, Error::Closed.new("process handle is closed"))
      end
      if cancel.try(&.cancelled?) || (deadline.expired? && !deadline.immediate?)
        return refused(request, Error.new("control cancelled or budget expired before admission"))
      end
      profile = Capability::Request.new([Capability::Operation.new(request.operation)])
      return refused(request, Error::Unsupported.new("control operation unavailable")) unless capabilities.supports?(profile)
      admit!
      retained = false
      begin
        result = @authority.perform(request, deadline: deadline, cancel: cancel)
        owners = pending_owners(result).uniq
        unless owners.empty?
          counter = owners.size
          guard = Mutex.new
          owners.each do |owner|
            owner.on_settle do
              done = guard.synchronize { counter -= 1; counter == 0 }
              finish if done
            end
          end
          retained = true
        end
        result
      ensure
        finish unless retained
      end
    rescue ex : Error::Closed
      refused(request, ex)
    end

    private def pending_owners(result : Control::Result) : Array(Control::Pending)
      case disposition = result.disposition
      when Control::Delivery::Unknown
        disposition.pending.try { |pending| [pending] } || [] of Control::Pending
      when Control::Report::Partial
        disposition.reports.flat_map { |report| pending_owners(report) }
      else
        [] of Control::Pending
      end
    end

    private def refused(request : Control::Request, reason : Error) : Control::Result
      Control::Result.new(request, identity, Control::Refused.new(reason), capabilities.mechanism)
    end

    private def admit! : Nil
      @mutex.synchronize do
        raise Error::Closed.new("process handle is closed") if @closed
        @inflight += 1
      end
    end

    private def finish : Nil
      @mutex.synchronize { @inflight -= 1 }
    end

    private def cleanup(*, deadline : Wait::Deadline, cancel : Wait::Cancellation?) : Control::Release::Result
      proceed = @mutex.synchronize do
        if (previous = @release_result) && !previous.state.retryable? && !previous.retry_participants?
          return previous
        end
        if @inflight > 0 || @cleanup_busy
          result = Control::Release::Result.new([Control::Release::Record.new("admitted operations", :retryable)])
          @release_result = result
          return result
        end
        @cleanup_busy = true
        true
      end
      begin
        previous = release_result
        result = if previous && previous.retry_participants?
                   previous.retry_participants(deadline: deadline, cancel: cancel)
                 else
                   @authority.release(deadline: deadline, cancel: cancel)
                 end
      rescue ex
        diagnostic = Diagnostic.new("release", ex.message || ex.class.name)
        result = Control::Release::Result.new([Control::Release::Record.new("native authority", :uncertain, diagnostic)])
      end
      @mutex.synchronize do
        @release_result = result
        @cleanup_busy = false
      end
      result
    end

    class Borrowed
      def initialize(@owner : Handle)
      end

      delegate identity, capabilities, closed?, observe, wait_exit, request_stop, kill, signal, suspend, resume, duplicate, to: @owner
    end

    module Acquisition
      class Failed < ProcessControl::Error::Unsupported
        getter failure : Exception
        getter owner : Handle

        def initialize(@failure, @owner)
          super("process acquisition refused with incomplete cleanup: #{@failure.message}")
        end
      end
    end
  end
end
