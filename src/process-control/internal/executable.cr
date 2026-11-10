module ProcessControl::Internal
  def self.executable?(path : String) : Bool
    return false unless File.file?(path)
    {% if File::Info.class.has_method?("executable?") %}
      File::Info.executable?(path)
    {% else %}
      File.executable?(path)
    {% end %}
  end
end
