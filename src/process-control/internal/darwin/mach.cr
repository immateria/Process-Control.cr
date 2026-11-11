require "./context"

module ProcessControl::Internal::Darwin::Mach
  private CONTEXT = Context.pid
  # This consumer owns its process-lifetime cached send right. Native-Kernel
  # receives it explicitly and owns no implicit caller context.
  private TASK = ::Native::Kernel::Darwin::Mach.task

  def self.open(pid : Int32) : Tuple(UInt32, Int32)
    ::Native::Kernel::Darwin::Mach.open(task, pid)
  end

  def self.retain(name : UInt32) : Int32
    ::Native::Kernel::Darwin::Mach.retain(task, name)
  end

  def self.release(name : UInt32) : Int32
    ::Native::Kernel::Darwin::Mach.release(task, name)
  end

  def self.read(name : UInt32) : Tuple(StaticArray(UInt32, 8), UInt32, Int32)
    ::Native::Kernel::Darwin::Mach.read(task, name)
  end

  private def self.task : UInt32
    unless Context.pid == CONTEXT && TASK != 0 && TASK != UInt32::MAX
      raise Error::Context::Mismatch.new("Mach task reference belongs to another process context")
    end
    TASK
  end
end
