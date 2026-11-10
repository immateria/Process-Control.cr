module ProcessControl
  class Child
    getter streams : Stream::Endpoints
    @mutex = Mutex.new
    @closed = false
    @closing = false
    @release_result : Control::Release::Result? = nil
    @stream_release : Control::Release::Result? = nil

    def initialize(@owner : Handle, @source : Spawn::Status::Source, @streams = Stream::Endpoints.new)
      unless @owner.identity.compare(@source.identity).consistent?
        raise Identity::Mismatch.new("control and status identities do not agree")
      end
    end

    def identity : Identity
      @owner.identity
    end

    def handle : Handle::Borrowed
      Handle::Borrowed.new(@owner)
    end

    def exit_info : Wait::Exit::Info?
      @source.latest.try(&.info)
    end

    def wait_exit(*, deadline : Wait::Deadline = Wait::Deadline.none, cancel : Wait::Cancellation? = nil) : Wait::Child::Result
      @source.wait_exit(deadline: deadline, cancel: cancel)
    end

    def complete(*, deadline : Wait::Deadline = Wait::Deadline.none, cancel : Wait::Cancellation? = nil,
                 drain : Stream::Drain::Policy = Stream::Drain::Policy.new) : Wait::Completion::Result
      child = wait_exit(deadline: deadline, cancel: cancel)
      return completion(child.state, child) unless child.state.completed?
      @streams.close_input
      cut_at = drain.cut_after.try { |span| Time.instant + span }
      loop do
        records = @streams.records
        if records.all?(&.settled)
          failed = records.find(&.diagnostic)
          state = if failed
                    Wait::State::Failed
                  elsif records.any?(&.cut) && !drain.cut_after
                    Wait::State::Closed
                  else
                    Wait::State::Completed
                  end
          return completion(state, child)
        end
        if cut_at && Time.instant >= cut_at
          @streams.cut_outputs
          cut_at = nil
        end
        return completion(:cancelled, child) if cancel.try(&.cancelled?)
        return completion(:expired, child) if deadline.expired?
        deadline.pause
      end
    end

    private def completion(state : Wait::State, child : Wait::Child::Result) : Wait::Completion::Result
      failure = child.failure
      if record = @streams.records.find(&.diagnostic)
        failure ||= Wait::Failure.new(Observation::Failed.new("stream copy failed", record.diagnostic))
      end
      Wait::Completion::Result.new(state, child, @streams.records, @streams.capture("stdout"), @streams.capture("stderr"), failure)
    end

    def closed? : Bool
      @mutex.synchronize { @closed }
    end

    def release_result : Control::Release::Result?
      @mutex.synchronize { @release_result }
    end

    def close(*, deadline : Wait::Deadline = Wait::Deadline.none, cancel : Wait::Cancellation? = nil) : Control::Release::Result
      @mutex.synchronize do
        if result = @release_result
          return result
        end
        if @closing
          return Control::Release::Result.new([Control::Release::Record.new("child release", :retryable)])
        end
        @closing = true
        @closed = true
      end
      streams = @streams.close
      owner = @owner.close(deadline: deadline, cancel: cancel)
      result = Control::Release::Result.new(streams.records + owner.records)
      @mutex.synchronize do
        @stream_release = streams
        @release_result = result
        @closing = false
      end
      result
    end

    def retry_cleanup(*, deadline : Wait::Deadline = Wait::Deadline.none, cancel : Wait::Cancellation? = nil) : Control::Release::Result
      raise Error::Ownership.new("cleanup retry requires a closed child") unless closed?
      streams = @mutex.synchronize { @stream_release }
      unless streams
        return Control::Release::Result.new([Control::Release::Record.new("child release", :retryable)])
      end
      owner = @owner.retry_cleanup(deadline: deadline, cancel: cancel)
      result = Control::Release::Result.new(streams.records + owner.records)
      @mutex.synchronize { @release_result = result }
      result
    end
  end
end
