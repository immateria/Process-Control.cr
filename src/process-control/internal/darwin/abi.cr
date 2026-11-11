module ProcessControl::Internal::Darwin
  # Mach names/counts are 32-bit on both supported Darwin architectures.
  lib ABI
    TASK_AUDIT_TOKEN        =    15
    MACH_PORT_RIGHT_SEND    = 0_u32
    KERN_PROTECTION_FAILURE =     2
    KERN_NO_ACCESS          =     8
  end

  # kevent64 uses the same layout on arm64 and x86-64. Use it without
  # redeclaring the stdlib's version-dependent kevent binding.
  lib Event
    EVFILT_PROC =         -5_i16
    EV_ADD      =     0x0001_u16
    EV_ONESHOT  =     0x0010_u16
    EV_ERROR    =     0x4000_u16
    NOTE_EXIT   = 0x80000000_u32
    IMMEDIATE   =   0x000001_u32

    struct Kevent64
      ident : UInt64
      filter : Int16
      flags : UInt16
      fflags : UInt32
      data : Int64
      udata : UInt64
      ext : UInt64[2]
    end
  end

  lib LibProc
    ALL_PIDS               = 1_u32
    PIDT_SHORTBSDINFO      =    13
    PIDUNIQIDENTIFIERINFO  =    17
    PIDT_BSDINFOWITHUNIQID =    18

    # SDK sys/proc_info.h: proc_bsdshortinfo.
    struct Short
      pid : UInt32
      ppid : UInt32
      pgid : UInt32
      status : UInt32
      comm : UInt8[16]
      flags : UInt32
      uid : UInt32
      gid : UInt32
      ruid : UInt32
      rgid : UInt32
      svuid : UInt32
      svgid : UInt32
      reserved : UInt32
    end

    # SDK sys/proc_info.h: proc_bsdinfo.
    struct Bsd
      flags : UInt32
      status : UInt32
      xstatus : UInt32
      pid : UInt32
      ppid : UInt32
      uid : UInt32
      gid : UInt32
      ruid : UInt32
      rgid : UInt32
      svuid : UInt32
      svgid : UInt32
      reserved : UInt32
      comm : UInt8[16]
      name : UInt8[32]
      files : UInt32
      pgid : UInt32
      job_control : UInt32
      terminal_device : UInt32
      terminal_pgid : UInt32
      nice : Int32
      start_seconds : UInt64
      start_microseconds : UInt64
    end

    # XNU sys/proc_info_private.h: proc_uniqidentifierinfo.
    struct Unique
      uuid : UInt8[16]
      unique_id : UInt64
      parent_unique_id : UInt64
      pid_version : Int32
      original_parent_pid_version : Int32
      reserved : UInt64[2]
    end

    # XNU sys/proc_info_private.h: proc_bsdinfowithuniqid.
    struct Record
      bsd : Bsd
      unique : Unique
    end
  end
end
