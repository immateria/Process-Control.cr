module ProcessControl::Wait
  class Cancellation
    @mutex = Mutex.new
    @cancelled = false

    def cancel : Nil
      @mutex.synchronize { @cancelled = true }
    end

    def cancelled? : Bool
      @mutex.synchronize { @cancelled }
    end
  end
end
