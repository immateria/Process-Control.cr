module ProcessControl::Internal::Darwin
  # Mach names/counts are 32-bit on both supported Darwin architectures.
  lib ABI
    TASK_AUDIT_TOKEN        =    15
    MACH_PORT_RIGHT_SEND    = 0_u32
    KERN_PROTECTION_FAILURE =     2
    KERN_NO_ACCESS          =     8

    $mach_task_self_ : UInt32
    fun task_name_for_pid(task : UInt32, pid : Int32, name : UInt32*) : Int32
    fun task_info(task : UInt32, flavor : Int32, info : Int32*, count : UInt32*) : Int32
    fun mach_port_mod_refs(task : UInt32, name : UInt32, right : UInt32, delta : Int32) : Int32
    fun mach_port_deallocate(task : UInt32, name : UInt32) : Int32
  end
end
