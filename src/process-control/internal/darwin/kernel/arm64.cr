module ProcessControl::Internal::Darwin::Kernel
  @[AlwaysInline]
  private def self.trap(number : Int32, a0 : UInt64, a1 : UInt64,
                        a2 : UInt64, a3 : UInt64, a4 : UInt64, a5 : UInt64,
                        a6 : UInt64, a7 : UInt64) : Result
    primary = 0_i64
    secondary = 0_i64
    failed = 0_u64
    code = number.to_i64.to_u64!
    # The kernel preserves the argument registers except for the two results.
    # Capture carry in the same block as svc before any generated arithmetic.
    asm("mov x16, $3\nsvc #0x80\ncset $2, cs"
            : "={x0}"(primary), "={x1}"(secondary), "=r"(failed)
            : "r"(code), "{x0}"(a0), "{x1}"(a1), "{x2}"(a2), "{x3}"(a3),
              "{x4}"(a4), "{x5}"(a5), "{x6}"(a6), "{x7}"(a7)
            : "x16", "memory", "cc"
            : "volatile")
    error = number >= 0 && failed != 0 ? primary.to_i32! : 0
    Result.new(primary, secondary, error)
  end
end
