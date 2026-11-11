require "../internal/linux/pidfd"
require "../internal/linux/authority"

module ProcessControl::Platform::Linux
  def self.open(pid : Int, *, required : Capability::Request = Capability::Request.wait, expected : ProcessControl::Identity? = nil) : Handle
    Internal::Linux::Authority.acquire(pid, required: required, expected: expected)
  end
end

require "./linux/cgroup"
