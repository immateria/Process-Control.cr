module ProcessControl::Stream
  class Endpoint < IO
    getter native : IO::FileDescriptor
    @eof = false
    @cut = false

    def initialize(@native)
    end

    def read(slice : Bytes) : Int32
      count = @native.read(slice)
      @eof = true if count == 0 && !slice.empty?
      count
    end

    def write(slice : Bytes) : Nil
      @native.write(slice)
    end

    def closed? : Bool
      @native.closed?
    end

    def close : Nil
      @cut = true unless @eof
      @native.close
    end

    def record(name : String) : Drain::Record
      Drain::Record.new(name, @eof || closed?, @cut)
    end
  end

  class Endpoints
    getter input : Endpoint?
    getter output : Endpoint?
    getter error : Endpoint?

    def initialize(@input = nil, @output = nil, @error = nil, captures : Enumerable(Capture::Buffer) = [] of Capture::Buffer)
      @captures = captures.to_a.dup
    end

    def records : Array(Drain::Record)
      records = [] of Drain::Record
      @output.try { |endpoint| records << endpoint.record("stdout") }
      @error.try { |endpoint| records << endpoint.record("stderr") }
      @captures.each { |capture| records << capture.record }
      records
    end

    def capture(name : String) : Capture::Snapshot?
      @captures.find { |capture| capture.name == name }.try(&.snapshot)
    end

    def cut_outputs : Nil
      @captures.each(&.cut)
      @output.try { |endpoint| endpoint.close unless endpoint.closed? }
      @error.try { |endpoint| endpoint.close unless endpoint.closed? }
    end

    def close_input : Nil
      @input.try { |endpoint| endpoint.close unless endpoint.closed? }
    end

    def close : Control::Release::Result
      records = [] of Control::Release::Record
      @captures.each do |capture|
        begin
          capture.cut
        rescue ex
          records << Control::Release::Record.new(capture.name, :uncertain, ProcessControl::Diagnostic.new("stream.close", ex.message || ex.class.name))
        end
      end
      {"stdin" => @input, "stdout" => @output, "stderr" => @error}.each do |name, endpoint|
        next unless endpoint
        begin
          endpoint.close unless endpoint.closed?
        rescue ex
          records << Control::Release::Record.new(name, :uncertain, ProcessControl::Diagnostic.new("stream.close", ex.message || ex.class.name))
        end
      end
      Control::Release::Result.new(records)
    end
  end
end
