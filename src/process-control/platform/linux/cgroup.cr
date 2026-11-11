require "../../internal/linux/cgroup"

module ProcessControl::Platform::Linux::Cgroup
  # The caller owns the directory lifecycle and the choice of subtree.
  # Acquisition retains an existing cgroup v2 domain.
  def self.open(path : String, request : Containment::Request = Containment::Request.new) : Group
    if path.empty? || path.includes?('\0')
      raise ArgumentError.new("invalid cgroup directory path")
    end
    path = File.realpath(path)
    controller = Internal::Linux::Cgroup.new(path)
    begin
      controller.capture
      Group.new(controller, request)
    rescue ex
      cleanup = controller.release(deadline: Wait::Deadline.none, cancel: nil)
      raise Acquisition::Failed.new(ex, cleanup) unless cleanup.complete?
      raise ex
    end
  rescue ex : File::Error
    errno = ex.os_error.as?(Errno)
    diagnostic = errno.try { |code| Internal::Linux::Cgroup::Native.diagnostic("group.open", "resolve-directory", code) }
    raise Error.new("could not resolve the cgroup directory", diagnostic)
  end

  module Acquisition
    class Failed < ProcessControl::Error::Ownership
      getter failure : Exception
      getter cleanup : Control::Release::Result

      def initialize(@failure, @cleanup)
        super("cgroup acquisition refused with incomplete cleanup: #{@failure.message}")
      end
    end
  end
end
