module ProcessControl::Control
  # A trusted provider owns the target binding. Implementations must preserve
  # authority through all work retained by their pending operations.
  abstract class Authority
    abstract def identity : ProcessControl::Identity
    abstract def capabilities : Capability::Snapshot
    abstract def observe : ProcessControl::Observation
    abstract def perform(request : Request, *, deadline : Wait::Deadline, cancel : Wait::Cancellation?) : Result
    abstract def duplicate : Authority
    abstract def release(*, deadline : Wait::Deadline, cancel : Wait::Cancellation?) : Release::Result

    def wait_failure : Wait::Failure?
      nil
    end
  end
end
