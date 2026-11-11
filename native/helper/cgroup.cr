{% if flag?(:linux) %}
  require "c/sys/stat"

  module ProcessControl::Internal::Unix::Owner
    lib Native
      struct Clone
        flags : UInt64
        pidfd : UInt64
        child_tid : UInt64
        parent_tid : UInt64
        exit_signal : UInt64
        stack : UInt64
        stack_size : UInt64
        tls : UInt64
        set_tid : UInt64
        set_tid_size : UInt64
        cgroup : UInt64
      end
    end

    # Linux UAPI on x86-64 and ARM64.
    DIRECTORY = {{ flag?(:aarch64) ? 0o40000 : 0o200000 }}
    CLONE_INTO_CGROUP = 1_u64 << 33
    SYS_CLONE3 = 435_i64

    def self.open_cgroup(path : UInt8*, device : UInt8*, inode : UInt8*) : Int32
      dev = uninitialized UInt64
      ino = uninitialized UInt64
      unless number(pointerof(device), pointerof(dev)) && device.value == 0 &&
             number(pointerof(inode), pointerof(ino)) && inode.value == 0
        Errno.value = Errno::EINVAL
        return -1
      end

      fd = LibC.open(path, DIRECTORY | LibC::O_NOFOLLOW | LibC::O_CLOEXEC)
      return fd if fd < 0
      stat = uninitialized LibC::Stat
      error = if LibC.fstat(fd, pointerof(stat)) < 0
                Errno.value
              elsif stat.st_dev.to_u64! != dev || stat.st_ino.to_u64! != ino
                Errno::ESTALE
              else
                return fd
              end
      LibC.close(fd)
      Errno.value = error
      -1
    end

    def self.clone_into_cgroup(fd : Int32) : Int32
      args = Native::Clone.new(flags: CLONE_INTO_CGROUP, exit_signal: LibC::SIGCHLD.to_u64!, cgroup: fd.to_u64!)
      target = LibC.syscall(SYS_CLONE3, pointerof(args), sizeof(Native::Clone).to_u64!)
      error = Errno.value
      LibC.close(fd)
      Errno.value = error
      target.to_i32!
    end
  end
{% end %}
