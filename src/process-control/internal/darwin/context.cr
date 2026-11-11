require "native-kernel/darwin"

module ProcessControl::Internal::Darwin::Context
  # Availability is cached by this managed consumer, never by the raw ABI.
  private RELEASE = ::Native::Kernel::Darwin::Process.release

  def self.major : Int32
    RELEASE
  end

  def self.messages? : Bool
    RELEASE >= 22
  end

  def self.signaling? : Bool
    RELEASE >= 24
  end

  def self.pid : Int64
    result = ::Native::Kernel::Darwin::Process.pid
    unless result.error == 0 && result.primary > 0
      detail = Diagnostic.new("handle.context", "Darwin process context could not be read",
        native_domain: "errno", native_code: result.error.to_i64, stage: "context")
      raise Error::Context::Mismatch.new(detail.message, detail)
    end
    result.primary
  end
end
