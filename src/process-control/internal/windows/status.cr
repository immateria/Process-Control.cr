module ProcessControl::Internal::Windows
  module Status
    def self.collect(handle : LibC::HANDLE, source : Spawn::Status::Source) : Nil
      observation = loop do
        sample = Windows.observe(handle, source.identity)
        break sample if sample.termination.terminated? || sample.diagnostic
        sleep 5.milliseconds
      end
      cleanup = Windows.close(handle, "Windows status handle")
      if detail = observation.diagnostic || cleanup.diagnostic
        error = Wait::Collection::Failed.new("Windows child status collection failed", detail)
        source.fail(error, termination: observation.termination, info: observation.exit_info)
      else
        source.publish(observation.exit_info.not_nil!)
      end
    end
  end
end
