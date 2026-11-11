require "c/fcntl"
require "c/sys/stat"
require "c/unistd"

module ProcessControl::Internal::Linux
  class Cgroup < Containment::Controller
    module Native
      # Linux LP64 UAPI. openat/fstatfs are not declared by the compiler floor.
      private SYS_OPENAT  = {{ flag?(:aarch64) ? 56_i64 : 257_i64 }}
      private SYS_FSTATFS = {{ flag?(:aarch64) ? 44_i64 : 138_i64 }}
      private SYS_PWRITE  = {{ flag?(:aarch64) ? 68_i64 : 18_i64 }}
      private SYS_CLONE3  = 435_i64
      private DIRECTORY   = {{ flag?(:aarch64) ? 0o40000 : 0o200000 }}
      private CGROUP_V2   = 0x63677270_i64
      private OPEN_FLAGS  = LibC::O_CLOEXEC | LibC::O_NOFOLLOW

      private lib ABI
        struct Statfs
          kind : Int64
          block_size : Int64
          blocks : Int64
          free_blocks : Int64
          available_blocks : Int64
          files : Int64
          free_files : Int64
          filesystem_id : StaticArray(Int32, 2)
          name_length : Int64
          fragment_size : Int64
          flags : Int64
          spare : StaticArray(Int64, 4)
        end
      end

      def self.open_directory(path : String) : Int32
        fd = LibC.open(path, LibC::O_RDONLY | OPEN_FLAGS | DIRECTORY)
        raise error("group.open", "open-directory", Errno.value) if fd < 0
        fd
      end

      def self.directory_identity(fd : Int32) : Tuple(UInt64, UInt64)
        fs = ABI::Statfs.new
        if LibC.syscall(SYS_FSTATFS, fd, pointerof(fs)) < 0
          raise error("group.open", "fstatfs", Errno.value)
        end
        raise Error::Unsupported.new("directory is not on cgroup v2") unless fs.kind == CGROUP_V2

        info = LibC::Stat.new
        raise error("group.open", "fstat", Errno.value) if LibC.fstat(fd, pointerof(info)) < 0
        {info.st_dev.to_u64, info.st_ino.to_u64}
      end

      # Probe the cgroup-aware clone_args ABI using an out-of-range fd.
      # A supporting kernel rejects that fd with EINVAL before creating a child.
      # An older clone3 rejects the nonzero extension beyond its struct size.
      def self.clone_reachable? : Bool
        args = StaticArray(UInt64, 11).new(0_u64)
        args[0] = 1_u64 << 33 # CLONE_INTO_CGROUP
        args[4] = ::Signal::CHLD.value.to_u64
        args[10] = UInt64::MAX
        LibC.syscall(SYS_CLONE3, args.to_unsafe, sizeof(typeof(args)).to_u64) == -1 && Errno.value == Errno::EINVAL
      end

      def self.open_file(fd : Int32, name : String, flags : Int32, *, optional = false) : Int32?
        result = LibC.syscall(SYS_OPENAT, fd, name.to_unsafe, flags | OPEN_FLAGS, 0_u32).to_i32
        return result if result >= 0
        errno = Errno.value
        return nil if optional && errno.in?(Errno::ENOENT, Errno::EACCES, Errno::EPERM, Errno::EROFS)
        raise error("group.open", name, errno)
      end

      def self.read(fd : Int32, operation : String, stage : String) : String
        # Both cgroup.type and cgroup.events are short, kernel-owned records.
        bytes = Bytes.new(4096)
        count = LibC.pread(fd, bytes.to_unsafe, bytes.size.to_u64, 0_i64)
        raise error(operation, stage, Errno.value) if count < 0
        if count == bytes.size
          raise Error.new("cgroup record exceeds the supported size", Diagnostic.new(operation, "record too large", stage: stage))
        end
        String.new(bytes[0, count.to_i32])
      end

      def self.write(fd : Int32, value : String, operation : String, stage : String) : Control::Report::Success | Control::Report::Failure
        count = LibC.syscall(SYS_PWRITE, fd, value.to_unsafe, value.bytesize.to_u64, 0_i64)
        if count < 0
          Control::Report::Failure.new(diagnostic(operation, stage, Errno.value))
        elsif count != value.bytesize
          Control::Report::Failure.new(Diagnostic.new(operation, "short cgroup control write", stage: stage))
        else
          Control::Report::Success.new("#{stage} accepted #{value}")
        end
      end

      def self.diagnostic(operation : String, stage : String, errno : Errno) : Diagnostic
        Diagnostic.new(operation, errno.message, native_domain: "errno", native_code: errno.value.to_i64, stage: stage)
      end

      private def self.error(operation : String, stage : String, errno : Errno) : Error
        reason = diagnostic(operation, stage, errno)
        case errno
        when Errno::ENOENT
          Error::Missing.new("cgroup operation failed", reason)
        when Errno::EACCES, Errno::EPERM, Errno::EROFS
          Error::Access::Denied.new("cgroup operation denied", reason)
        else
          Error.new("cgroup operation failed", reason)
        end
      end
    end
  end
end
