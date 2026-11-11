{% unless flag?(:darwin) && (flag?(:aarch64) || flag?(:x86_64)) %}
  {% raise "Darwin kernel calls require ARM64 or x86-64." %}
{% end %}

module ProcessControl::Internal::Darwin::Kernel
  struct Result
    getter primary : Int64
    getter secondary : Int64
    getter error : Int32

    def initialize(@primary : Int64, @secondary : Int64, @error : Int32)
    end
  end

  # Positive numbers select BSD syscalls. Negative numbers select Mach traps,
  # whose native return code remains in primary instead of using errno.
  def self.call(number : Int32, a0 : UInt64 = 0_u64, a1 : UInt64 = 0_u64,
                a2 : UInt64 = 0_u64, a3 : UInt64 = 0_u64,
                a4 : UInt64 = 0_u64, a5 : UInt64 = 0_u64,
                a6 : UInt64 = 0_u64, a7 : UInt64 = 0_u64) : Result
    result = trap(number, a0, a1, a2, a3, a4, a5, a6, a7)
    return Result.new(-1_i64, result.secondary, result.error) unless result.error == 0
    # Darwin's fork trap returns the child's PID to both processes and marks
    # the child in the secondary register. Normalize its primary result here.
    if number == 2 && result.secondary != 0
      return Result.new(0_i64, result.secondary, 0)
    end
    result
  end
end

{% if flag?(:aarch64) %}
  require "./kernel/arm64"
{% elsif flag?(:x86_64) %}
  require "./kernel/x86_64"
{% end %}
