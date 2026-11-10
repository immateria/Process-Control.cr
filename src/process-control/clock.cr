module ProcessControl::Clock
  {% if Time.has_constant?("Instant") %}
    alias Instant = Time::Instant
  {% else %}
    alias Instant = Time::Span
  {% end %}

  # Keep timestamps and deadlines on the same monotonic clock. Before Crystal
  # 1.19, the stdlib represents a monotonic instant with a Time::Span.
  def self.now : Instant
    {% if Time.has_constant?("Instant") %}
      Time.instant
    {% else %}
      Time.monotonic
    {% end %}
  end
end
