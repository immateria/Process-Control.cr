module ProcessControl::Internal::Unix::Protocol
  # EXIT token raw NONE
  # EXIT token raw DARWIN user_sec user_usec system_sec system_usec <14 counters>
  # Each native writer includes the newline within this bound.
  FRAME_LIMIT = 512

  def self.exit(parts : Array(String)) : Wait::Exit::Info
    raise Observation::Failed.new("malformed exit receipt") unless parts.size >= 4
    raw = unsigned(parts[2]).to_u32
    usage = case parts[3]
            when "NONE"
              raise Observation::Failed.new("unexpected exit accounting fields") unless parts.size == 4
              nil
            when "DARWIN"
              raise Observation::Failed.new("malformed Darwin accounting receipt") unless parts.size == 22
              user = Resource::Usage::Time.new(unsigned(parts[4]).to_i64, unsigned(parts[5]).to_i32)
              system = Resource::Usage::Time.new(unsigned(parts[6]).to_i64, unsigned(parts[7]).to_i32)
              counters = StaticArray(Int64, 14).new { |index| unsigned(parts[index + 8]).to_i64 }
              Resource::Usage.new(user, system, counters[0], counters[1], counters[2], counters[3],
                counters[4], counters[5], counters[6], counters[7], counters[8], counters[9],
                counters[10], counters[11], counters[12], counters[13])
            else
              raise Observation::Failed.new("unknown exit accounting profile")
            end
    info = Wait::Exit::Info.posix(raw.to_i32!, usage: usage)
    raise Observation::Failed.new("nonterminal child status") if info.reason.unknown?
    info
  end

  private def self.unsigned(value : String) : UInt64
    unless !value.empty? && value.each_byte.all? { |byte| 48 <= byte <= 57 }
      raise Observation::Failed.new("invalid exit accounting integer")
    end
    value.to_u64
  end
end
