module ProcessControl::Platform::Unix::Helper::Runtime
  def self.kernel_assembly : Set(String)
    [
      "\0~{memory}",
      "mov x16, $3\\0Asvc #0x80\\0Acset $2, cs\0={x0},={x1},=r,r,{x0},{x1},{x2},{x3},{x4},{x5},{x6},{x7},~{x16},~{memory},~{cc}",
      "subq $$160, %rsp\\0Amovq $10, 8(%rsp)\\0Amovq $11, 16(%rsp)\\0Asyscall\\0Asetc ${2:b}\\0Aaddq $$160, %rsp\0={rax},={rdx},=r,{rax},{rdi},{rsi},{rdx},{r10},{r8},{r9},r,r,~{rcx},~{r11},~{memory},~{cc}",
    ].to_set
  end
end
