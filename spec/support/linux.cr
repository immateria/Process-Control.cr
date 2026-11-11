require "socket"
require "../../src/process-control/clock"

# Enter fixture mode before the spec runner interprets the helper's arguments.
if mode = ENV["PROCESS_CONTROL_LINUX_FIXTURE"]?
  directory = ENV["PROCESS_CONTROL_LINUX_DIRECTORY"]
  helper = ENV["PROCESS_CONTROL_REAL_HELPER"]

  case mode
  when "cgroup-gate"
    raise "missing cgroup birth arguments" unless ARGV.size >= 6 && ARGV[2] == "--cgroup"
    ready = File.join(directory, "ready")
    File.write("#{ready}.tmp", ARGV[3, 3].join(" "))
    File.rename("#{ready}.tmp", ready)
    deadline = ProcessControl::Clock.now + 5.seconds
    until File.exists?(File.join(directory, "proceed"))
      raise "cgroup replacement gate expired" if ProcessControl::Clock.now >= deadline
      sleep 5.milliseconds
    end
    Process.exec(helper, ARGV)
  when "drop-started"
    raise "missing native helper arguments" unless ARGV.size >= 2
    path, token = ARGV[0], ARGV[1]
    inner_path = File.join(directory, "inner")
    outer = UNIXSocket.new(path)
    outer.read_timeout = 5.seconds
    listener = UNIXServer.new(inner_path)
    listener.read_timeout = 5.seconds
    process = nil.as(Process?)
    inner = nil.as(UNIXSocket?)
    begin
      process = Process.new(helper, [inner_path, token] + ARGV[2..], input: STDIN, output: STDOUT, error: STDERR)
      inner = listener.accept
      inner.read_timeout = 5.seconds
      greeting = inner.gets(limit: 192, chomp: true).not_nil!
      raise "invalid native helper greeting" unless greeting.split[0, 3] == ["HELLO", "1", token]
      outer.puts(greeting)
      outer.flush
      start = outer.gets(limit: 192, chomp: true).not_nil!
      raise "invalid native start request" unless start.split == ["START", token]
      inner.puts(start)
      inner.flush
      response = inner.gets(limit: 192, chomp: true).not_nil!.split
      raise "native birth was not confirmed" unless response.size == 3 && response[0, 2] == ["STARTED", token]
      started = File.join(directory, "started")
      File.write("#{started}.tmp", response[2])
      File.rename("#{started}.tmp", started)
      outer.close
      inner.close

      completed = Channel(Process::Status).new(1)
      spawn { completed.send(process.not_nil!.wait) }
      select
      when status = completed.receive
        collected = File.join(directory, "collected")
        File.write("#{collected}.tmp", status.exit_code.to_s)
        File.rename("#{collected}.tmp", collected)
        exit status.exit_code
      when timeout(10.seconds)
        raise "native helper collection timed out"
      end
    ensure
      inner.try { |socket| socket.close unless socket.closed? }
      outer.close unless outer.closed?
      listener.close
      File.delete(inner_path) if File.exists?(inner_path)
    end
  else
    raise "unknown Linux fixture mode"
  end
end
