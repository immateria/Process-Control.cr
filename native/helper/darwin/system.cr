module ProcessControl::Internal::Unix::Owner::System
  alias Kernel = ProcessControl::Internal::Darwin::Kernel

  struct Address
    @length = 106_u8
    @family = 1_u8
    @path = StaticArray(UInt8, 104).new(0_u8)
  end

  struct Event
    @fd : Int32
    @events = 1_i16
    @revents = 0_i16

    def initialize(@fd)
    end
  end

  struct Limit
    property soft : UInt64
    property hard : UInt64

    def initialize(@soft = 0_u64, @hard = 0_u64)
    end
  end

  struct Timeout
    @seconds : Int64
    @microseconds : Int32

    def initialize(microseconds : UInt32)
      @seconds = microseconds.unsafe_div(1_000_000_u32).to_i64
      @microseconds = microseconds.unsafe_mod(1_000_000_u32).to_i32!
    end
  end

  private def self.value(result : Kernel::Result) : Int64
    result.error == 0 ? result.primary : 0_i64 &- result.error.to_i64
  end

  def self.read(fd : Int32, buffer : Pointer(T), count : UInt64) : Int64 forall T
    value(Kernel.call(3, fd.to_u64!, buffer.address, count))
  end

  def self.write(fd : Int32, buffer : Pointer(T), count : UInt64) : Int64 forall T
    value(Kernel.call(4, fd.to_u64!, buffer.address, count))
  end

  def self.close(fd : Int32) : Int32
    value(Kernel.call(6, fd.to_u64!)).to_i32!
  end

  def self.open(path : UInt8*, flags : Int32) : Int32
    value(Kernel.call(5, path.address, flags.to_u64!, 0_u64)).to_i32!
  end

  def self.fcntl(fd : Int32, command : Int32, argument : Int32 = 0) : Int32
    value(Kernel.call(92, fd.to_u64!, command.to_u64!, argument.to_u64!)).to_i32!
  end

  def self.fork : Int32
    value(Kernel.call(2)).to_i32!
  end

  def self.pid : Int32
    value(Kernel.call(20)).to_i32!
  end

  def self.parent : Int32
    value(Kernel.call(39)).to_i32!
  end

  def self.waitpid(pid : Int32, status : Int32*, options : Int32) : Int32
    value(Kernel.call(7, pid.to_u64!, status.address, options.to_u64!, 0_u64)).to_i32!
  end

  def self.kill(pid : Int32, signal : Int32) : Int32
    value(Kernel.call(37, pid.to_u64!, signal.to_u64!)).to_i32!
  end

  def self.pipe(descriptors : Int32*) : Int32
    result = Kernel.call(42)
    return (0_i32 &- result.error) unless result.error == 0
    descriptors[0] = result.primary.to_i32!
    descriptors[1] = result.secondary.to_i32!
    0
  end

  def self.socket : Int32
    value(Kernel.call(97, 1_u64, 1_u64, 0_u64)).to_i32!
  end

  def self.connect(fd : Int32, path : UInt8*) : Int32
    length = Text.size(path, 104)
    return -63 if length < 0
    address = Address.new
    bytes = pointerof(address).as(UInt8*)
    offset = 0
    while offset < length
      bytes[offset &+ 2] = path[offset]
      asm("" ::: "memory" : "volatile")
      offset &+= 1
    end
    value(Kernel.call(98, fd.to_u64!, bytes.address, sizeof(Address).to_u64!)).to_i32!
  end

  def self.poll(fd : Int32, milliseconds : Int32) : Int32
    event = Event.new(fd)
    value(Kernel.call(230, pointerof(event).address, 1_u64, milliseconds.to_u64!)).to_i32!
  end

  def self.entries(fd : Int32, bytes : UInt8*, capacity : Int32, base : Int64*) : Int64
    value(Kernel.call(344, fd.to_u64!, bytes.address, capacity.to_u64!, base.address))
  end

  def self.seek(fd : Int32, offset : Int64, whence : Int32) : Int64
    value(Kernel.call(199, fd.to_u64!, offset.to_u64!, whence.to_u64!))
  end

  def self.sleep(microseconds : UInt32) : Int32
    timeout = Timeout.new(microseconds)
    value(Kernel.call(93, 0_u64, 0_u64, 0_u64, 0_u64, pointerof(timeout).address)).to_i32!
  end

  def self.setsid : Int32
    value(Kernel.call(147)).to_i32!
  end

  def self.set_limit(resource : Int32, limits : Limit*) : Int32
    value(Kernel.call(195, resource.to_u64!, limits.address)).to_i32!
  end

  def self.get_limit(resource : Int32, limits : Limit*) : Int32
    value(Kernel.call(194, resource.to_u64!, limits.address)).to_i32!
  end

  def self.execve(path : UInt8*, arguments : UInt8**, environment : UInt8**) : Int32
    value(Kernel.call(59, path.address, arguments.address, environment.address)).to_i32!
  end

  def self.exit(code : Int32) : NoReturn
    loop do
      Kernel.call(1, code.to_u64!)
    end
  end
end
