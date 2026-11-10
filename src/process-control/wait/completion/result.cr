module ProcessControl::Wait::Completion
  class Result
    getter state : Wait::State
    getter child : Wait::Child::Result
    getter output : Stream::Capture::Snapshot?
    getter error : Stream::Capture::Snapshot?
    getter failure : Wait::Failure?

    def initialize(@state, @child, records : Enumerable(Stream::Drain::Record), @output = nil, @error = nil, @failure = nil)
      @records = records.to_a.dup
    end

    def records : Array(Stream::Drain::Record)
      @records.dup
    end

    def outstanding : Array(Stream::Drain::Record)
      @records.reject(&.settled)
    end
  end
end
