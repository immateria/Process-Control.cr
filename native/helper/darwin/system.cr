module ProcessControl::Internal::Unix::Owner::System
  alias Native = ::Native::Kernel::Darwin

  struct Address
    @length = 106_u8
    @family = 1_u8
    @path = StaticArray(UInt8, 104).new(0_u8)
  end

  private def self.value(result : Native::Result) : Int64
    result.error == 0 ? result.primary : 0_i64 &- result.error.to_i64
  end

  def self.read(fd : Int32, buffer : Pointer(T), count : UInt64) : Int64 forall T
    value(Native::Descriptor.read(fd, buffer, count))
  end

  def self.write(fd : Int32, buffer : Pointer(T), count : UInt64) : Int64 forall T
    value(Native::Descriptor.write(fd, buffer, count))
  end

  def self.close(fd : Int32) : Int32
    value(Native::Descriptor.close(fd)).to_i32!
  end

  def self.open(path : UInt8*, flags : Int32) : Int32
    value(Native::Descriptor.open(path, flags)).to_i32!
  end

  def self.fcntl(fd : Int32, command : Int32, argument : Int32 = 0) : Int32
    value(Native::Descriptor.fcntl(fd, command, argument)).to_i32!
  end

  def self.fork : Int32
    value(Native::Process.fork).to_i32!
  end

  def self.pid : Int32
    value(Native::Process.pid).to_i32!
  end

  def self.parent : Int32
    value(Native::Process.parent).to_i32!
  end

  def self.waitpid(pid : Int32, status : Int32*, options : Int32) : Int32
    value(Native::Process.waitpid(pid, status, options)).to_i32!
  end

  def self.wait4(pid : Int32, status : Int32*, options : Int32, usage : Native::Resource::Usage*) : Int32
    value(Native::Process.wait4(pid, status, options, usage)).to_i32!
  end

  def self.kill(pid : Int32, signal : Int32) : Int32
    value(Native::Signal.kill(pid, signal)).to_i32!
  end

  def self.pipe(descriptors : Int32*) : Int32
    result = Native::Descriptor.pipe
    return (0_i32 &- result.error) unless result.error == 0
    descriptors[0] = result.primary.to_i32!
    descriptors[1] = result.secondary.to_i32!
    0
  end

  def self.socket : Int32
    value(Native::Descriptor.socket(1, 1, 0)).to_i32!
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
    value(Native::Descriptor.connect(fd, pointerof(address).as(Void*), sizeof(Address).to_u32!)).to_i32!
  end

  def self.poll(fd : Int32, milliseconds : Int32) : Int32
    event = Native::Event::Poll.new(fd)
    value(Native::Event.poll(pointerof(event), 1_u32, milliseconds)).to_i32!
  end

  def self.entries(fd : Int32, bytes : UInt8*, capacity : Int32, base : Int64*) : Int64
    value(Native::Descriptor.entries(fd, bytes, capacity, base))
  end

  def self.seek(fd : Int32, offset : Int64, whence : Int32) : Int64
    value(Native::Descriptor.seek(fd, offset, whence))
  end

  def self.sleep(microseconds : UInt32) : Int32
    value(Native::Event.sleep(microseconds)).to_i32!
  end

  def self.setsid : Int32
    value(Native::Process.setsid).to_i32!
  end

  def self.set_limit(resource : Int32, limits : Native::Resource::Limit*) : Int32
    value(Native::Resource.set(resource, limits)).to_i32!
  end

  def self.get_limit(resource : Int32, limits : Native::Resource::Limit*) : Int32
    value(Native::Resource.get(resource, limits)).to_i32!
  end

  def self.execve(path : UInt8*, arguments : UInt8**, environment : UInt8**) : Int32
    value(Native::Process.execve(path, arguments, environment)).to_i32!
  end

  def self.exit(code : Int32) : NoReturn
    Native::Process.exit(code)
  end
end
