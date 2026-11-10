require "set"

module ProcessControl
  VERSION = "0.1.0-preview.1"
end

require "./process-control/diagnostic"
require "./process-control/error"
require "./process-control/identity"
require "./process-control/observation"
require "./process-control/capability"
require "./process-control/wait/deadline"
require "./process-control/wait/cancellation"
require "./process-control/wait/result"
require "./process-control/control/request"
require "./process-control/control/result"
require "./process-control/control/pending"
require "./process-control/control/release"
require "./process-control/spawn/status/source"
require "./process-control/control/authority"
require "./process-control/handle"
require "./process-control/stream/stdio"
require "./process-control/stream/endpoints"
require "./process-control/stream/capture"
require "./process-control/wait/completion/result"
require "./process-control/child"
require "./process-control/spawn/result"
require "./process-control/spawn/registration"
require "./process-control/spawn/environment"
require "./process-control/containment"
require "./process-control/control/shutdown"
require "./process-control/group"
require "./process-control/spawn/launcher"
require "./process-control/command"

{% if flag?(:darwin) || (flag?(:linux) && !flag?(:android)) %}
  require "./process-control/platform/unix"
{% end %}
