require "c/fileapi"
require "c/fcntl"
require "c/io"
require "c/processenv"

module ProcessControl::Internal::Windows
  class Stdio
    private PIPE_REJECT_REMOTE_CLIENTS =         0x8_u32
    private STANDARD_INPUT             = 0xffff_fff6_u32
    private STANDARD_OUTPUT            = 0xffff_fff5_u32
    private STANDARD_ERROR             = 0xffff_fff4_u32

    @temporary = [] of {LibC::HANDLE, String}
    @parents = [] of {Stream::Endpoint, String}
    @captures = [] of {Stream::Endpoint, String, Stream::Capture::Budget}

    def prepare(spec : Stream::Stdio) : LibC::HANDLE[3]
      StaticArray[
        prepare(spec.input, STANDARD_INPUT, "stdin"),
        prepare(spec.output, STANDARD_OUTPUT, "stdout"),
        prepare(spec.error, STANDARD_ERROR, "stderr"),
      ]
    end

    def endpoints : Stream::Endpoints
      captured = @captures.map { |endpoint, name, budget| Stream::Capture::Buffer.new(name, endpoint, budget) }
      Stream::Endpoints.new(endpoint("stdin"), endpoint("stdout"), endpoint("stderr"), captured)
    end

    def close_temporaries : Array(Control::Release::Record)
      entries = @temporary.dup
      @temporary.clear
      entries.reverse_each.map { |handle, name| Windows.close(handle, name) }.to_a
    end

    def close_parents : Array(Control::Release::Record)
      entries = @parents.dup
      @parents.clear
      entries.map do |endpoint, name|
        begin
          endpoint.close
          Control::Release::Record.new(name, :complete)
        rescue ex
          Control::Release::Record.new(name, :uncertain, ProcessControl::Diagnostic.new("stream.close", ex.message || ex.class.name))
        end
      end
    end

    private def endpoint(name : String) : Stream::Endpoint?
      return nil if @captures.any? { |_, stream, _| stream == name }
      @parents.find { |_, stream| stream == name }.try(&.[0])
    end

    private def prepare(spec : Stream::Spec, standard : UInt32, name : String) : LibC::HANDLE
      input = standard == STANDARD_INPUT
      source = case spec
               when Stream::Inherit
                 handle = LibC.GetStdHandle(standard)
                 handle.null? || handle == LibC::INVALID_HANDLE_VALUE ? null_device(input, name) : handle
               when Stream::Close
                 null_device(input, name)
               when Stream::Pipe, Stream::Capture
                 make_pipe(input, name, spec)
               when IO::FileDescriptor
                 descriptor(spec, name)
               else
                 raise Error::Unsupported.new("unsupported Windows stdio policy")
               end
      remember(Windows.duplicate(source, inheritable: true), "#{name} inheritance handle")
    end

    private def descriptor(io : IO::FileDescriptor, name : String) : LibC::HANDLE
      raise Error::Closed.new("#{name} descriptor is closed") if io.closed?
      {% if Crystal::System::FileDescriptor.has_constant?("Handle") %}
        raise Error::Unsupported.new("#{name} requires a synchronous Windows descriptor") unless io.system_blocking?
        LibC::HANDLE.new(io.fd)
      {% else %}
        raise Error::Unsupported.new("#{name} requires a synchronous Windows descriptor") unless io.blocking
        Crystal::System::FileDescriptor.windows_handle!(io.fd)
      {% end %}
    end

    private def null_device(input : Bool, name : String) : LibC::HANDLE
      access = input ? LibC::GENERIC_READ : LibC::GENERIC_WRITE
      path = "NUL".to_utf16
      handle = LibC.CreateFileW(path, access, LibC::FILE_SHARE_READ | LibC::FILE_SHARE_WRITE, nil, LibC::OPEN_EXISTING, 0_u32, nil)
      raise Windows.error("CreateFileW(NUL)") if handle == LibC::INVALID_HANDLE_VALUE
      remember(handle, "#{name} null device")
    end

    private def make_pipe(input : Bool, name : String, spec : Stream::Pipe | Stream::Capture) : LibC::HANDLE
      path = Path.windows(File.tempname("process-control", nil, dir: %q(\\.\pipe))).normalize.to_s
      write_flags = LibC::PIPE_ACCESS_OUTBOUND | LibC::FILE_FLAG_FIRST_PIPE_INSTANCE
      write_flags |= LibC::FILE_FLAG_OVERLAPPED if input
      write = LibC.CreateNamedPipeA(path, write_flags, PIPE_REJECT_REMOTE_CLIENTS, 1_u32, 65_536_u32, 65_536_u32, 0_u32, nil)
      raise Windows.error("CreateNamedPipeA") if write == LibC::INVALID_HANDLE_VALUE
      remember(write, "#{name} pipe write end")

      read_flags = input ? 0_u32 : LibC::FILE_FLAG_OVERLAPPED
      path_wide = path.to_utf16
      read = LibC.CreateFileW(path_wide, LibC::GENERIC_READ | LibC::FILE_WRITE_ATTRIBUTES, 0_u32, nil, LibC::OPEN_EXISTING, read_flags, nil)
      raise Windows.error("CreateFileW(pipe)") if read == LibC::INVALID_HANDLE_VALUE
      remember(read, "#{name} pipe read end")

      child_end, parent_end = input ? {read, write} : {write, read}
      io = adopt(parent_end)
      endpoint = Stream::Endpoint.new(io)
      @parents << {endpoint, name}
      @captures << {endpoint, name, spec.budget} if spec.is_a?(Stream::Capture)
      child_end
    end

    private def adopt(handle : LibC::HANDLE) : IO::FileDescriptor
      operation = "IO::FileDescriptor.new"
      io = {% if Crystal::System::FileDescriptor.has_constant?("Handle") %}
             adopted = IO::FileDescriptor.new(handle.address, close_on_finalize: false)
             forget(handle)
             adopted
           {% else %}
             operation = "CreateIoCompletionPort"
             Crystal::Scheduler.event_loop.create_completion_port(handle)
             operation = "_open_osfhandle"
             descriptor = LibC._open_osfhandle(handle, LibC::O_BINARY | LibC::O_NOINHERIT)
             raise IO::Error.from_errno("_open_osfhandle") if descriptor < 0
             forget(handle)
             operation = "IO::FileDescriptor.new"
             IO::FileDescriptor.new(descriptor, blocking: false, close_on_finalize: false)
           {% end %}
      io.close_on_finalize = true
      io.sync = true
      io
    rescue ex : IO::Error | RuntimeError
      raise Windows.setup_error(operation || "IO::FileDescriptor.new", "parent-pipe", ex)
    end

    private def remember(handle : LibC::HANDLE, name : String) : LibC::HANDLE
      @temporary << {handle, name}
      handle
    end

    private def forget(handle : LibC::HANDLE) : Nil
      @temporary.reject! { |entry| entry[0] == handle }
    end
  end
end
