module ProcessControl::Internal::Unix::Owner::Text
  def self.size(value : UInt8*, limit : Int32) : Int32
    count = 0
    while count < limit
      return count if value[count] == 0
      count &+= 1
    end
    -1
  end

  def self.equal(left : UInt8*, right : UInt8*) : Bool
    offset = 0
    loop do
      byte = left[offset]
      return false unless byte == right[offset]
      return true if byte == 0
      offset &+= 1
    end
  end
end
