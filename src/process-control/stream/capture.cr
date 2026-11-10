module ProcessControl::Stream
  struct Capture
    class Snapshot
      @bytes : Bytes
      getter truncated : Bool

      def initialize(bytes : Bytes, @truncated)
        @bytes = bytes.dup
      end

      def bytes : Bytes
        @bytes.dup
      end
    end

    class Buffer
      getter name : String
      @mutex = Mutex.new
      @buffer = IO::Memory.new
      @truncated = false
      @settled = false
      @cut = false
      @diagnostic : ProcessControl::Diagnostic? = nil

      def initialize(@name, @source : Endpoint, @budget : Budget)
        spawn(name: "process-control-#{@name}") { copy }
      end

      def snapshot : Snapshot
        @mutex.synchronize { Snapshot.new(@buffer.to_slice, @truncated) }
      end

      def record : Drain::Record
        @mutex.synchronize { Drain::Record.new(@name, @settled, @cut, @diagnostic) }
      end

      def cut : Nil
        close = @mutex.synchronize do
          unless @settled
            @cut = true
            @truncated = true
            true
          end
        end
        @source.close if close && !@source.closed?
      end

      private def copy : Nil
        chunk = Bytes.new(16_384)
        while (count = @source.read(chunk)) > 0
          @mutex.synchronize do
            space = @budget.max_bytes - @buffer.size
            retained = {space, count}.min
            @buffer.write(chunk[0, retained]) if retained > 0
            @truncated = true if count > retained
          end
        end
      rescue ex
        @mutex.synchronize do
          unless @cut
            @diagnostic = ProcessControl::Diagnostic.new("stream.copy", ex.message || ex.class.name)
          end
        end
      ensure
        @source.close unless @source.closed?
        @mutex.synchronize { @settled = true }
      end
    end
  end
end
