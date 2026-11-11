require "native-kernel/audit"

module ProcessControl::Platform::Unix::Helper::Runtime
  def self.kernel_assembly : Set(String)
    Native::Kernel::Audit::ASSEMBLY.to_set
  end
end
