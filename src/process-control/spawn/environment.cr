module ProcessControl::Spawn
  class Environment
    getter inherit : Bool
    @edits : Hash(String, String?)

    def initialize(edits = {} of String => String?, @inherit = true)
      @edits = {} of String => String?
      edits.each do |key, value|
        if key.empty? || key.includes?('=') || key.includes?('\0') || value.try(&.includes?('\0'))
          raise ArgumentError.new("invalid environment edit")
        end
        @edits[key] = value
      end
    end

    def resolve : Hash(String, String)
      {% if flag?(:windows) %}
        return Internal::Windows::Environment.resolve(@edits, @inherit)
      {% end %}
      result = @inherit ? ENV.to_h : {} of String => String
      @edits.each do |key, value|
        if value
          result[key] = value
        else
          result.delete(key)
        end
      end
      result
    end
  end
end
