module ProcessControl::Internal::Callbacks
  # Settlement is already committed when subscribers run. Each subscriber must
  # be notified even if another fails, including subscribers retaining owners.
  def self.run(operation : String, callbacks : Array(Proc(Nil))) : Array(Diagnostic)
    failures = [] of Diagnostic
    callbacks.each do |callback|
      begin
        callback.call
      rescue ex
        failures << Diagnostic.new(operation, ex.message || ex.class.name, stage: "callback")
      end
    end
    failures
  end
end
