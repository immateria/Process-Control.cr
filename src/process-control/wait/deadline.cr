module ProcessControl::Wait
  struct Deadline
    getter at : Time::Instant?
    getter? immediate : Bool

    def initialize(@at : Time::Instant?, @immediate = false)
    end

    def self.none : self
      new(nil)
    end

    def self.after(span : Time::Span) : self
      raise ArgumentError.new("negative deadline duration") if span < Time::Span.zero
      new(Time.instant + span, span == Time::Span.zero)
    end

    def remaining : Time::Span?
      @at.try { |at| {at - Time.instant, Time::Span.zero}.max }
    end

    def expired? : Bool
      @at.try { |at| Time.instant >= at } || false
    end

    # Bounded polling is the portable baseline; native event providers can use
    # their own wake mechanisms without changing deadline semantics.
    def pause : Nil
      sleep remaining.try { |left| {left, 5.milliseconds}.min } || 5.milliseconds
    end
  end
end
