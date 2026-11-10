module ProcessControl::Control
  module Cleanup
    class Failed < ProcessControl::Error; end
  end

  module Release
    enum State
      Complete
      Retryable
      Uncertain
    end

    struct Record
      getter resource : String
      getter state : State
      getter diagnostic : ProcessControl::Diagnostic?
      getter participant : Participant?

      def initialize(@resource, @state, @diagnostic = nil, @participant = nil)
        if @participant && !@state.retryable?
          raise ArgumentError.new("only a retained retryable resource can expose a cleanup participant")
        end
      end
    end

    class Participant
      @mutex = Mutex.new
      @running = false
      @terminal : Record? = nil

      def initialize(@resource : String, &@operation : Wait::Deadline, Wait::Cancellation? -> Record)
      end

      def retry(*, deadline : Wait::Deadline, cancel : Wait::Cancellation?) : Record
        @mutex.synchronize do
          if terminal = @terminal
            return terminal
          end
          return Record.new(@resource, :retryable, participant: self) if @running
          @running = true
        end
        begin
          result = @operation.call(deadline, cancel)
        rescue ex
          result = Record.new(@resource, :uncertain, ProcessControl::Diagnostic.new("release.retry", ex.message || ex.class.name))
        end
        @mutex.synchronize do
          @running = false
          if result.state.retryable?
            result = Record.new(result.resource, :retryable, result.diagnostic, self)
          else
            @terminal = result
          end
        end
        result
      end
    end

    class Result
      getter state : State
      @records : Array(Record)

      def initialize(records : Enumerable(Record))
        @records = records.to_a.dup
        @state = if @records.any?(&.state.uncertain?)
                   State::Uncertain
                 elsif @records.any?(&.state.retryable?)
                   State::Retryable
                 else
                   State::Complete
                 end
      end

      def self.complete : self
        new([] of Record)
      end

      def records : Array(Record)
        @records.dup
      end

      def complete? : Bool
        @state.complete?
      end

      def retry_participants? : Bool
        @records.any? { |record| record.state.retryable? && !record.participant.nil? }
      end

      def retry_participants(*, deadline : Wait::Deadline, cancel : Wait::Cancellation?) : Result
        records = @records.map do |record|
          if record.state.retryable? && (participant = record.participant)
            participant.retry(deadline: deadline, cancel: cancel)
          else
            record
          end
        end
        Result.new(records)
      end
    end
  end
end
