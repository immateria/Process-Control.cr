module ProcessControl::Internal::Unix::Owner
  def self.command_layout(argc : Int32, argv : UInt8**) : Int32
    index = 3
    while index < argc &- 1
      option = argv[index]
      return index &+ 1 if Text.equal(option, "--".to_unsafe)
      if Text.equal(option, "--session".to_unsafe)
        index &+= 1
      elsif Text.equal(option, "--limit".to_unsafe) && index < argc &- 4
        index &+= 4
      else
        break
      end
    end
    -1
  end

  def self.setup(argv : UInt8**, command : Int32) : Int32
    index = 3
    while index < command &- 1
      if Text.equal(argv[index], "--session".to_unsafe)
        result = System.setsid
        return result if result < 0
        index &+= 1
      else
        result = set_limit(argv[index &+ 1], argv[index &+ 2], argv[index &+ 3])
        return result if result < 0
        index &+= 4
      end
    end
    0
  end

  def self.set_limit(name : UInt8*, soft : UInt8*, hard : UInt8*) : Int32
    resource = if Text.equal(name, "cpu".to_unsafe)
                 0
               elsif Text.equal(name, "file".to_unsafe)
                 1
               elsif Text.equal(name, "core".to_unsafe)
                 4
               elsif Text.equal(name, "descriptors".to_unsafe)
                 8
               else
                 -1
               end
    lower = 0_u64
    upper = 0_u64
    unless resource >= 0 && number(pointerof(soft), pointerof(lower)) && soft.value == 0 &&
           number(pointerof(hard), pointerof(upper)) && hard.value == 0 &&
           lower <= upper && upper < 9223372036854775807_u64
      return -22
    end
    limits = ::Native::Kernel::Darwin::Resource::Limit.new(lower, upper)
    result = System.set_limit(resource, pointerof(limits))
    return result if result < 0
    result = System.get_limit(resource, pointerof(limits))
    return result if result < 0
    return -34 unless limits.soft == lower && limits.hard == upper
    0
  end
end
