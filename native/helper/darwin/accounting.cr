module ProcessControl::Internal::Unix::Owner
  def self.report_exit(fd : Int32, token : UInt8*, status : Int32, usage : System::Native::Resource::Usage*) : Int32
    bytes = uninitialized UInt8[512]
    frame = Frame.new(bytes.to_unsafe, 512)
    return -1 unless frame.text("EXIT ".to_unsafe) && frame.text(token) && frame.text(" ".to_unsafe) &&
                     frame.integer(status.to_u32!.to_u64) && frame.text(" DARWIN ".to_unsafe) &&
                     frame.signed(usage.value.user.seconds) && frame.text(" ".to_unsafe) &&
                     frame.signed(usage.value.user.microseconds.to_i64) && frame.text(" ".to_unsafe) &&
                     frame.signed(usage.value.system.seconds) && frame.text(" ".to_unsafe) &&
                     frame.signed(usage.value.system.microseconds.to_i64)
    {% for name in %w(max_rss shared_memory data_memory stack_memory reclaims faults swaps input_blocks output_blocks sent received signals voluntary_switches involuntary_switches) %}
      return -1 unless frame.text(" ".to_unsafe) && frame.signed(usage.value.{{name.id}})
    {% end %}
    return -1 unless frame.text("\n".to_unsafe)
    send_line(fd, bytes.to_unsafe)
  end
end
