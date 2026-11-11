require "c/processthreadsapi"
require "json"

lib WindowsSpec
  fun CreateEventW(attributes : LibC::SECURITY_ATTRIBUTES*, manual_reset : LibC::BOOL, initial_state : LibC::BOOL, name : UInt16*) : LibC::HANDLE
  fun SetEvent(event : LibC::HANDLE) : LibC::BOOL
  fun GetProcessHandleCount(process : LibC::HANDLE, count : LibC::DWORD*) : LibC::BOOL
end

if mode = ENV["PROCESS_CONTROL_WINDOWS_FIXTURE"]?
  case mode
  when "exit"
    LibC.ExitProcess(ARGV[0].to_u32)
  when "sleep"
    sleep 30.seconds
    LibC.ExitProcess(0_u32)
  when "echo"
    IO.copy(STDIN, STDOUT)
    STDOUT.flush
    STDERR.puts("separate")
    STDERR.flush
    LibC.ExitProcess(0_u32)
  when "describe"
    puts({args: ARGV, value: ENV["PrOcEsS_CoNtRoL_TeSt"]?, cwd: Dir.current}.to_json)
    STDOUT.flush
    LibC.ExitProcess(0_u32)
  when "tree"
    spawned = Process.new(Process.executable_path.not_nil!, env: {"PROCESS_CONTROL_WINDOWS_FIXTURE" => "sleep"})
    puts spawned.pid
    STDOUT.flush
    LibC.ExitProcess(0_u32)
  when "inheritance"
    WindowsSpec.SetEvent(LibC::HANDLE.new(ARGV[0].to_u64))
    LibC.ExitProcess(42_u32)
  when "startup-marker"
    File.write(ARGV[0], "started")
    sleep 30.seconds
    LibC.ExitProcess(0_u32)
  end
end
