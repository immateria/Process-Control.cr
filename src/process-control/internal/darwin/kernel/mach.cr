require "./process"

module ProcessControl::Internal::Darwin::Kernel::Mach
  private CONTEXT = Process.pid
  # The module owns this send right for its process lifetime, as the system's
  # cached task-self reference did. Inherited names are refused after raw fork.
  private TASK = Kernel.call(-28).primary.to_u32!

  private TYPE_ERROR       =                   -300
  private REPLY_MISMATCH   =                   -301
  private ARRAY_TOO_LARGE  =                   -307
  private SEND_INTERRUPTED =             0x10000007
  private RCV_INTERRUPTED  =             0x10004005
  private SEND_KOBJECT     = 0x0000000200000000_u64

  def self.open(pid : Int32) : Tuple(UInt32, Int32)
    name = 0_u32
    result = Kernel.call(-44, task.to_u64, pid.to_u64!, pointerof(name).address)
    {name, result.primary.to_i32!}
  end

  def self.retain(name : UInt32) : Int32
    Kernel.call(-19, task.to_u64, name.to_u64, 0_u64, 1_u64).primary.to_i32!
  end

  def self.release(name : UInt32) : Int32
    Kernel.call(-18, task.to_u64, name.to_u64).primary.to_i32!
  end

  def self.read(name : UInt32) : Tuple(StaticArray(UInt32, 8), UInt32, Int32)
    current_task = task
    words = StaticArray(UInt32, 8).new(0_u32)
    reply = Kernel.call(-26).primary.to_u32!
    return {words, 0_u32, 6} if reply == 0 || reply == UInt32::MAX

    # Only the request is initialized here. The kernel fills the reply, whose
    # declared size is validated before its payload is read.
    buffer = uninitialized UInt32[128]
    buffer[0] = 0x1513_u32 # COPY_SEND target, MAKE_SEND_ONCE reply
    buffer[1] = 40_u32
    buffer[2] = name
    buffer[3] = reply
    buffer[4] = 0_u32    # no voucher
    buffer[5] = 3405_u32 # task_info
    buffer[6] = 0_u32    # NDR protocol, encoding and reserved bytes
    buffer[7] = 1_u32    # NDR little-endian integer representation
    buffer[8] = 15_u32   # TASK_AUDIT_TOKEN
    buffer[9] = 8_u32

    cleanup = 0
    begin
      code = exchange(buffer.to_unsafe, name, reply)
    ensure
      # A dedicated receive right avoids sharing a runtime/TLS reply port.
      cleanup = Kernel.call(-19, current_task.to_u64, reply.to_u64, 1_u64, UInt64::MAX).primary.to_i32!
    end
    return {words, 0_u32, code} unless code == 0
    return {words, 0_u32, cleanup} unless cleanup == 0
    return {words, 0_u32, REPLY_MISMATCH} unless buffer[5] == 3505
    size = buffer[1]
    unless buffer[0] & 0x80000000_u32 == 0 && size >= 36 && size <= 512 && buffer[6] == 0 && buffer[7] == 1
      return {words, 0_u32, TYPE_ERROR}
    end
    returned = buffer[8].to_i32!
    return {words, 0_u32, returned} unless returned == 0
    return {words, 0_u32, TYPE_ERROR} unless size >= 40
    count = buffer[9]
    return {words, count, ARRAY_TOO_LARGE} if count > 8
    return {words, count, TYPE_ERROR} unless size == 40 + count * 4
    offset = 0
    while offset < count
      words[offset] = buffer[10 + offset]
      offset += 1
    end
    {words, count, 0}
  end

  private def self.task : UInt32
    unless Process.pid == CONTEXT && TASK != 0 && TASK != UInt32::MAX
      raise Error::Context::Mismatch.new("Mach task reference belongs to another process context")
    end
    TASK
  end

  private def self.exchange(buffer : Pointer(UInt32), target : UInt32, reply : UInt32) : Int32
    options = SEND_KOBJECT | 3_u64
    send_size = 40_u64
    loop do
      code = Kernel.call(-47, buffer.address, options,
        0x1513_u64 | (send_size << 32),
        target.to_u64 | (reply.to_u64 << 32),
        3405_u64 << 32, reply.to_u64 << 32, 512_u64).primary.to_i32!
      if code == SEND_INTERRUPTED
        next
      elsif code == RCV_INTERRUPTED
        # Sending has completed. An interrupted receive retries only receive.
        options = SEND_KOBJECT | 2_u64
        send_size = 0_u64
      else
        return code
      end
    end
  end
end
