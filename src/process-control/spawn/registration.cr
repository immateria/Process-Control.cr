module ProcessControl::Spawn
  class Registration
    include Pending::Owner

    @mutex = Mutex.new
    @consumed = false
    @aborting = false
    @retry_requested = false
    @control_attempted = false
    @control_pending : Control::Pending? = nil
    @stream_release : Control::Release::Result? = nil
    @authority_release : Control::Release::Result? = nil

    def initialize(@authority : Control::Authority, @source : Status::Source, @streams = Stream::Endpoints.new)
    end

    def publish(*, required : Capability::Request = Capability::Request.child) : Result
      @mutex.synchronize do
        raise ProcessControl::Error::Ownership.new("registration already consumed") if @consumed
        @consumed = true
      end
      error = if !@authority.identity.compare(@source.identity).consistent?
                ProcessControl::Identity::Mismatch.new("registration identities differ")
              elsif !@authority.capabilities.supports?(required)
                ProcessControl::Error::Unsupported.new("registration lacks requested authority")
              end
      if error
        pending = Pending.new(ProcessControl::Diagnostic.new("registration", error.message || "registration refused"))
        pending.retain(self)
        pending.on_abort do |deadline, cancel|
          @mutex.synchronize do
            @aborting = true
            @retry_requested = true
          end
          pending.resolve(deadline: deadline, cancel: cancel)
        end
        spawn(name: "process-control-registration-cleanup") { monitor(pending, error) }
        return pending
      end
      Started.new(ProcessControl::Child.new(ProcessControl::Handle.new(@authority), @source, @streams))
    end

    private def monitor(pending : Pending, error : ProcessControl::Error) : Nil
      loop do
        aborting, retry_requested = @mutex.synchronize do
          value = {@aborting, @retry_requested}
          @retry_requested = false
          value
        end
        if aborting && !@control_attempted
          @control_attempted = true
          request = Control::Kill::Request.new
          profile = Capability::Request.new([Capability::Operation.new(request.operation)])
          if @authority.capabilities.supports?(profile) && !@authority.observe.termination.terminated?
            result = @authority.perform(request, deadline: Wait::Deadline.none, cancel: nil)
            if unknown = result.disposition.as?(Control::Delivery::Unknown)
              @control_pending = unknown.pending
            end
          end
        end
        control_settled = @control_pending.try(&.latest) || @control_pending.nil?
        source_collected = @source.latest.try(&.info)
        authority_accounted = @authority.capabilities.binding.sampled? || @authority.observe.termination.terminated?
        if control_settled && source_collected && authority_accounted
          @stream_release ||= @streams.close
          if !@authority_release
            @authority_release = @authority.release(deadline: Wait::Deadline.none, cancel: nil)
          elsif retry_requested
            previous = @authority_release.not_nil!
            if previous.retry_participants?
              @authority_release = previous.retry_participants(deadline: Wait::Deadline.none, cancel: nil)
            elsif previous.state.retryable?
              @authority_release = @authority.release(deadline: Wait::Deadline.none, cancel: nil)
            end
          end
          combined = Control::Release::Result.new(@stream_release.not_nil!.records + @authority_release.not_nil!.records)
          pending.note_cleanup(combined)
          if combined.complete?
            pending.publish(Rejected.new(error, combined, attempted: true))
            return
          end
          pending.note(ProcessControl::Diagnostic.new("registration.cleanup", "native release remains #{combined.state}"))
        end
        sleep 5.milliseconds
      end
    rescue ex
      pending.note(ProcessControl::Diagnostic.new("registration.cleanup", ex.message || ex.class.name))
    end
  end
end
