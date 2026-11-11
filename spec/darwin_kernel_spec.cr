require "./spec_helper"

{% if flag?(:darwin) %}
  describe PC::Internal::Darwin::Kernel do
    it "separates successful BSD values from kernel errors" do
      result = PC::Internal::Darwin::Kernel.call(20)
      result.error.should eq(0)
      result.primary.should eq(Process.pid)
      failed = PC::Internal::Darwin::Kernel.call(3, UInt64::MAX, 0_u64, 1_u64)
      failed.primary.should eq(-1)
      failed.error.should eq(Errno::EBADF.value)
    end

    it "preserves Mach native return codes and releases its acquired self right" do
      task = PC::Internal::Darwin::Kernel.call(-28)
      task.error.should eq(0)
      task.primary.should be > 0
      begin
        failed = PC::Internal::Darwin::Kernel.call(-18, task.primary.to_u64!, 0xfffffffe_u64)
        failed.error.should eq(0)
        failed.primary.should_not eq(0)
      ensure
        PC::Internal::Darwin::Kernel.call(-18, task.primary.to_u64!, task.primary.to_u64!).primary.should eq(0)
      end
    end

    it "passes distinct seventh and eighth BSD arguments" do
      plain = PC::Internal::Darwin::Kernel.call(374, UInt64::MAX)
      plain.error.should eq(Errno::EBADF.value)
      seventh = PC::Internal::Darwin::Kernel.call(374,
        UInt64::MAX, 0_u64, 0_u64, 0_u64, 0_u64, 1_u64, 1_u64, 0_u64)
      seventh.primary.should eq(-1)
      seventh.error.should eq(Errno::EFAULT.value)
      eighth = PC::Internal::Darwin::Kernel.call(374,
        UInt64::MAX, 0_u64, 0_u64, 0_u64, 0_u64, 0_u64, 0_u64, 0x400_u64)
      eighth.primary.should eq(-1)
      eighth.error.should eq(Errno::EINVAL.value)
    end
  end
{% end %}
