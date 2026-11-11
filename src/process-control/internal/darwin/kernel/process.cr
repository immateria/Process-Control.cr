require "../kernel"

module ProcessControl::Internal::Darwin::Kernel::Process
  # mach_msg2 first shipped in macOS 13. Audited-token signaling first shipped
  # in macOS 15. These are availability floors for the direct kernel protocol.
  private RELEASE = release

  def self.major : Int32
    RELEASE
  end

  def self.messages? : Bool
    RELEASE >= 22
  end

  def self.signaling? : Bool
    RELEASE >= 24
  end

  def self.pid : Int64
    result = Kernel.call(20)
    unless result.error == 0 && result.primary > 0
      detail = Diagnostic.new("handle.context", "Darwin process context could not be read",
        native_domain: "errno", native_code: result.error.to_i64, stage: "context")
      raise Error::Context::Mismatch.new(detail.message, detail)
    end
    result.primary
  end

  def self.list(buffer : Void*, size : Int32) : Kernel::Result
    Kernel.call(336, 1_u64, 1_u64, 0_u64, 0_u64, buffer.address, size.to_u64!)
  end

  def self.info(pid : Int32, flavor : Int32, argument : UInt64, buffer : Void*, size : Int32) : Kernel::Result
    Kernel.call(336, 2_u64, pid.to_u64!, flavor.to_u64!, argument, buffer.address, size.to_u64!)
  end

  def self.signal(words : Pointer(UInt32), number : Int32) : Int32
    Kernel.call(336, 17_u64, 0_u64, number.to_u64!, 0_u64, words.address, 32_u64).error
  end

  private def self.release : Int32
    name = StaticArray(Int32, 2).new(0)
    name[0] = 1 # CTL_KERN
    name[1] = 2 # KERN_OSRELEASE
    bytes = uninitialized UInt8[256]
    size = 256_u64
    result = Kernel.call(202, name.to_unsafe.address, 2_u64, bytes.to_unsafe.address, pointerof(size).address)
    return 0 unless result.error == 0 && size > 0 && size <= 256
    major = 0
    offset = 0
    while offset < size && bytes[offset] >= 48 && bytes[offset] <= 57
      return 0 if major > 1000
      major = major * 10 + bytes[offset] - 48
      offset += 1
    end
    return 0 if offset == 0 || offset >= size || bytes[offset] != 46
    major
  end
end
