module ProcessControl::Internal::Darwin::Kernel
  @[AlwaysInline]
  private def self.trap(number : Int32, a0 : UInt64, a1 : UInt64,
                        a2 : UInt64, a3 : UInt64, a4 : UInt64, a5 : UInt64,
                        a6 : UInt64, a7 : UInt64) : Result
    primary = 0_i64
    secondary = 0_i64
    failed = 0_u8
    code = if number < 0
             0x01000000_u64 | (0_i64 &- number.to_i64).to_u64!
           else
             0x02000000_u64 | number.to_u64!
           end
    # Preserve the compiler's 128-byte red zone, then reserve the dummy return
    # slot and stack arguments expected by the kernel's eight-argument path.
    # Capture carry before restoring rsp because add changes the flags.
    asm("subq $$160, %rsp\nmovq $10, 8(%rsp)\nmovq $11, 16(%rsp)\nsyscall\nsetc ${2:b}\naddq $$160, %rsp"
            : "={rax}"(primary), "={rdx}"(secondary), "=r"(failed)
            : "{rax}"(code), "{rdi}"(a0), "{rsi}"(a1), "{rdx}"(a2), "{r10}"(a3),
              "{r8}"(a4), "{r9}"(a5), "r"(a6), "r"(a7)
            : "rcx", "r11", "memory", "cc"
            : "volatile")
    error = number >= 0 && failed != 0 ? primary.to_i32! : 0
    Result.new(primary, secondary, error)
  end
end
