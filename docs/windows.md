# Windows process handles, launch, and Jobs

`Handle.open` acquires a non-inheritable process handle with query and
synchronization rights. Request the `control.kill` operation explicitly to
also acquire termination rights. A request for graceful stop, POSIX signals,
suspend or resume is refused. Native access errors identify the failed
operation and preserve the Win32 error code.

Identity evidence is the unsigned creation FILETIME from the acquired handle in
the `windows.creation.filetime` domain. It has local scope. Compare expected
identity against that handle's evidence. Duplicate and wait through the
retained process object. A duplicate owns its own local lifetime.

A process object can remain present after termination. The backend checks the
handle's signal state before collecting its unsigned 32-bit status. This
distinguishes a running process from a completed process with status 259.
`Observation#exit_info` contains the Windows status after successful
collection. The status alone does not identify the cause of termination.
`kill` uses `TerminateProcess` with the caller's unsigned exit code, or 1 when
omitted. Native acceptance and later termination are separate observations.

`Command#spawn` selects a Windows launcher. An explicit executable path or a
caller-PATH lookup resolves to an `.exe`. Windows validates that path as a
binary, and the launcher supplies it as the application name separately from
the UTF-16 argument string. The working directory and case-insensitive
environment edits are sent separately. Batch files and shell interpolation
are outside this profile.

The launcher creates the target suspended, captures its identity and
establishes separate control and status ownership before resuming the primary
thread. The status collector remains active after child close and keeps one
result for all child waiters. Finite waits and cancellation apply to
individual waits. Failed startup after creation retains cleanup ownership
until native termination and handle release can be accounted for.

Standard streams use a creation-time handle list. Each entry is a temporary
inheritable duplicate. A closed stream, or an inherited stream with no
standard handle, uses the Windows null device. Explicit descriptors must
remain open during setup and use synchronous handles. Pipe and capture
streams use synchronous child ends and overlapped parent ends. A descendant
can hold output open after the logical child exits. The allowlist controls
handles inherited by this launch. Other launchers that inherit every
inheritable handle in the parent can inherit a temporary duplicate during
setup.

`Platform::Windows::Job.create` explicitly creates an unnamed,
non-inheritable Job with kill-on-close and without breakaway flags. Its
`Group#spawn` admits the exact launch plan once and supplies the Job to the
native process-creation attribute list. The child enters the Job at creation
before its thread is resumed. A host that rejects the creation-time attribute
or the resulting Job nesting returns a typed error. Existing process attach,
graceful group stop, freeze, resource limits and Job notifications are outside
this profile.

The Job reports population from native accounting. `Group#kill` requests
`TerminateJobObject` with the exact unsigned code, and the aggregate effect
reports native acceptance or failure. Wait for empty separately. Closing the
last Job handle requests termination of its members through the kernel's
kill-on-close policy. Population, exit status, and stream settlement have
separate lifetimes. Waits use bounded polling. Registered callbacks and
completion ports for process or Job waits are outside this profile.

The platform contracts are based on Microsoft's documentation for
[process-creation attributes](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-updateprocthreadattribute)
and [Job objects](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects).

Run the native suite from the shard directory on Windows.

```powershell
crystal spec --no-color --error-on-warnings
```

The combined suite passed 51 examples under CrossOver 25.0.1 using an
x86-64 Windows GNU build. Native Windows runtime qualification remains open.
