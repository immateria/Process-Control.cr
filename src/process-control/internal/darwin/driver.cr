module ProcessControl::Internal::Darwin
  abstract class Driver
    def context : Int64
      ::Process.pid.to_i64
    end

    abstract def available? : Bool
    abstract def open(pid : Int32) : Tuple(UInt32, Int32)
    abstract def read(port : UInt32) : Tuple(StaticArray(UInt32, 8), UInt32, Int32)
    abstract def retain(port : UInt32) : Int32
    abstract def release(port : UInt32) : Int32
    abstract def signal(token : Token, number : Int32) : Int32
  end
end
