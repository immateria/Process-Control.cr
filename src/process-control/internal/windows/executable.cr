module ProcessControl::Internal::Windows
  def self.executable(name : String, caller_directory : String, environment : Hash(String, String)) : String?
    if name.includes?('\\') || name.includes?('/') || name.includes?(':')
      path = File.expand_path(name, caller_directory)
      return path unless File.extname(path).empty?
      return "#{path}.exe"
    end

    search = Environment.lookup(environment, "PATH") || ENV["PATH"]? || ""
    name = "#{name}.exe" if File.extname(name).empty?
    search.split(::Process::PATH_DELIMITER).each do |entry|
      path = File.expand_path(File.join(entry, name), caller_directory)
      return path if File.file?(path)
    end
    nil
  end
end
