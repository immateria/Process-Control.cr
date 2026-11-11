require "c/sys/resource"

module ProcessControl::Internal::Unix::Owner
  lib Native
    {% if LibC.has_constant?("Rlimit") %}
      alias Limit = LibC::Rlimit
    {% else %}
      struct Limit
        rlim_cur : UInt64
        rlim_max : UInt64
      end

      fun getrlimit(resource : Int32, limit : Limit*) : Int32
    {% end %}

    fun setsid : Int32
    fun setrlimit(resource : Int32, limit : Limit*) : Int32
  end

  def self.command_layout(argc : Int32, argv : UInt8**) : {Int32, Int32}
    index = 3
    cgroup = 0
    while index < argc &- 1
      option = argv[index]
      return {index &+ 1, cgroup} if Text.equal(option, "--".to_unsafe)
      if Text.equal(option, "--session".to_unsafe)
        index &+= 1
      elsif Text.equal(option, "--limit".to_unsafe) && index < argc &- 4
        index &+= 4
      elsif {{ flag?(:linux) }} && cgroup == 0 && Text.equal(option, "--cgroup".to_unsafe) && index < argc &- 4
        cgroup = index
        index &+= 4
      else
        break
      end
    end
    {-1, 0}
  end

  def self.setup(argv : UInt8**, command : Int32) : Int32
    index = 3
    while index < command &- 1
      if Text.equal(argv[index], "--session".to_unsafe)
        return -1 if Native.setsid < 0
        index &+= 1
      elsif {{ flag?(:linux) }} && Text.equal(argv[index], "--cgroup".to_unsafe)
        # The helper used the directory descriptor at creation.
        index &+= 4
      else
        return -1 if set_limit(argv[index &+ 1], argv[index &+ 2], argv[index &+ 3]) < 0
        index &+= 4
      end
    end
    0
  end

  def self.set_limit(name : UInt8*, soft : UInt8*, hard : UInt8*) : Int32
    resource = if Text.equal(name, "cpu".to_unsafe)
                 0 # RLIMIT_CPU
               elsif Text.equal(name, "file".to_unsafe)
                 1 # RLIMIT_FSIZE
               elsif Text.equal(name, "core".to_unsafe)
                 4 # RLIMIT_CORE
               elsif Text.equal(name, "descriptors".to_unsafe)
                 {{ flag?(:darwin) ? 8 : 7 }} # RLIMIT_NOFILE
               else
                 -1
               end
    lower = uninitialized UInt64
    upper = uninitialized UInt64
    unless resource >= 0 &&
           number(pointerof(soft), pointerof(lower)) && soft.value == 0 &&
           number(pointerof(hard), pointerof(upper)) && hard.value == 0 &&
           lower <= upper && upper < 9223372036854775807_u64
      Errno.value = Errno::EINVAL
      return -1
    end
    limits = Native::Limit.new(rlim_cur: lower, rlim_max: upper)
    return -1 if Native.setrlimit(resource, pointerof(limits)) < 0
    # Require the exact requested bounds before allowing exec.
    {% if LibC.has_constant?("Rlimit") %}
      return -1 if LibC.getrlimit(resource, pointerof(limits)) < 0
    {% else %}
      return -1 if Native.getrlimit(resource, pointerof(limits)) < 0
    {% end %}
    unless limits.rlim_cur == lower && limits.rlim_max == upper
      Errno.value = Errno::ERANGE
      return -1
    end
    0
  end
end
