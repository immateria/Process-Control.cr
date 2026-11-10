require "../internal/darwin/abi"
require "../internal/darwin/token"
require "../internal/darwin/driver"
require "../internal/darwin/native"
require "../internal/darwin/authority"

module ProcessControl::Platform::Darwin
  private NATIVE = Internal::Darwin::Native.new

  def self.available? : Bool
    NATIVE.available?
  end

  def self.open(pid : Int, *, required : Capability::Request = Capability::Request.control, expected : ProcessControl::Identity? = nil) : Handle
    Internal::Darwin::Authority.acquire(pid, required: required, expected: expected, driver: NATIVE)
  end
end
