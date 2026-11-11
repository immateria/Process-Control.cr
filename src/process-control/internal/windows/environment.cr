module ProcessControl::Internal::Windows
  module Environment
    def self.resolve(edits : Hash(String, String?), inherit : Bool) : Hash(String, String)
      result = {} of String => String
      if inherit
        ENV.each { |key, value| set(result, key, value) }
      end
      edits.each { |key, value| set(result, key, value) }
      result
    end

    def self.lookup(environment : Hash(String, String), key : String) : String?
      environment.find { |name, _| compare(name, key) == 0 }.try(&.[1])
    end

    def self.block(environment : Hash(String, String)) : Slice(UInt16)
      String.build do |io|
        environment.keys.sort { |left, right| compare(left, right) }.each do |key|
          io << key << '=' << environment[key] << '\0'
        end
        io << '\0'
      end.to_utf16
    end

    private def self.set(environment, key, value)
      if existing = environment.keys.find { |name| compare(name, key) == 0 }
        environment.delete(existing)
      end
      environment[key] = value if value
    end

    private def self.compare(left : String, right : String) : Int32
      first = left.to_utf16
      second = right.to_utf16
      result = ABI.CompareStringOrdinal(first, first.size, second, second.size, 1)
      raise Windows.error("CompareStringOrdinal") if result == 0
      result - 2
    end
  end
end
