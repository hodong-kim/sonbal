-- ============================================================================
-- sonbal-process_execution.ads
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Clair.Event_Loop;
with Clair.IO;
with Clair.Process.Execution;
with Clair.Process.Execution.Event_Loop;
with Clair.Status;
with Sonbal.Process_Arguments;
with Sonbal.Process_Admission;
with Sonbal.Workspace_Tokens;
with System;
with System.Storage_Elements;

package Sonbal.Process_Execution is

  -- Internal ceiling for server-owned process operations. Public tools may
  -- impose a smaller request-level timeout.
  MAXIMUM_OPERATION_TIMEOUT_MS : constant Positive := 3_600_000;

  type Operation is limited private;
  type Operation_Access is access all Operation;

  type Completion_Handler is limited interface;
  type Completion_Handler_Access is access all Completion_Handler'Class;

  --! summary Receive one settled Sonbal process operation on the Event Loop.
  --! contract:
  --!   The `outcome` value is valid only for this callback. The callback must
  --!   perform bounded work and must not restart or finalize `operation`.
  function on_complete
    (handler   : in out Completion_Handler;
     operation : not null Operation_Access;
     cause     : Clair.Process.Execution.Event_Loop.Operation_Cause;
     status    : Clair.Status.Code;
     outcome   : Clair.Process.Execution.Result)
  return Clair.Status.Code is abstract;

  --! summary Bind caller-owned operation storage to one Event Loop context.
  function initialize
    (self         : aliased in out Operation;
     loop_context : aliased in out Clair.Event_Loop.Context)
  return Clair.Status.Code;

  --! summary Release one idle initialized operation.
  --! returns `INVALID_STATE` while execution ownership remains active.
  function finalize
    (self : aliased in out Operation)
  return Clair.Status.Code;

  function is_initialized (self : Operation) return Boolean;
  function is_active (self : Operation) return Boolean;
  function has_runtime_resources (self : Operation) return Boolean;

  type Workspace_Start_State is
    (Workspace_Start_Running,
     Workspace_Start_Execution_Busy,
     Workspace_Start_Stale_Token,
     Workspace_Start_Outside_Workspace,
     Workspace_Start_Failed);

  --! summary Start one execution under current workspace-token freshness and
  --!   shared process admission.
  --! contract:
  --!   Workspace work is registered before shared process admission. A successful
  --!   current-token check supplies the canonical working directory used for
  --!   the child. Stale-token, containment, or capacity refusal does not
  --!   create a process. The workspace work ticket and shared admission count
  --!   remain attached until strict process settlement and are then released
  --!   exactly once before completion is published to `handler`. Activating or
  --!   deactivating a later workspace token does not cancel an already accepted
  --!   process.
  function start_workspace
    (self              : aliased in out Operation;
     workspace_tokens       : aliased in out Sonbal.Workspace_Tokens.Context;
     admission         : aliased in out Sonbal.Process_Admission.Context;
     workspace_token : String;
     argv              : Sonbal.Process_Arguments.Arguments;
     resolution        : Clair.Process.Execution.Executable_Resolution;
     cwd               : String;
     timeout_ms        : Natural;
     handler           : Completion_Handler_Access;
     state             : out Workspace_Start_State)
  return Clair.Status.Code;

  --! summary Start one same-image read helper under current workspace
  --!   freshness and shared process admission.
  --! contract:
  --!   Token-only workspace work is admitted before shared process admission.
  --!   The helper receives the canonical root captured by that token and runs
  --!   through `executable_descriptor` under the ordinary strict process
  --!   lifecycle. No filesystem lookup is performed on the owner thread.
  function start_workspace_read
    (self                  : aliased in out Operation;
     workspace_tokens      : aliased in out Sonbal.Workspace_Tokens.Context;
     admission             : aliased in out Sonbal.Process_Admission.Context;
     executable_descriptor : Clair.IO.Descriptor;
     argument_zero         : String;
     workspace_token       : String;
     path                  : String;
     offset                : Clair.IO.File_Offset;
     maximum_bytes         : Positive;
     expected_revision     : String;
     handler               : Completion_Handler_Access;
     state                 : out Workspace_Start_State)
  return Clair.Status.Code;

  --! summary Retry release of attached runtime resources for an inactive
  --!   operation.
  --! notes:
  --!   This is a fail-closed cleanup path for start rollback or completion
  --!   accounting failure. It never cancels or detaches an active process.
  function settle_idle_resources
    (self : aliased in out Operation)
  return Clair.Status.Code;

  --! summary Observe the stdout prefix retained for one active operation.
  --! contract:
  --!   The operation must be active and the call must run on the owner Event
  --!   Loop thread. `offset` is zero-based and must not exceed the retained
  --!   length. Observation never advances process progress.
  --! outputs:
  --!   On success, `length` is the current retained length, `copied` is the
  --!   bounded number of bytes copied at `offset`, and `truncated` reports
  --!   whether later bytes were discarded by the capture limit. On failure,
  --!   all outputs are reset and `buffer` is unchanged.
  function observe_standard_output
    (self      : Operation;
     offset    : Natural;
     buffer    : in out System.Storage_Elements.Storage_Array;
     length    : out Natural;
     copied    : out Natural;
     truncated : out Boolean)
  return Clair.Status.Code;

  --! summary Observe the stderr prefix retained for one active operation.
  --! contract:
  --!   The operation and offset rules match `observe_standard_output`.
  function observe_standard_error
    (self      : Operation;
     offset    : Natural;
     buffer    : in out System.Storage_Elements.Storage_Array;
     length    : out Natural;
     copied    : out Natural;
     truncated : out Boolean)
  return Clair.Status.Code;

  --! summary Start one bounded noninteractive process operation.
  --! contract:
  --!   `argv` must be a validated bounded process-argument projection. The
  --!   request dispatch enforces each tool's timeout ceiling; this operation
  --!   accepts up to `MAXIMUM_OPERATION_TIMEOUT_MS`. `cwd` must be POSIX
  --!   absolute.
  --! ownership:
  --!   `handler` remains caller-owned and valid until `on_complete` returns.
  --! notes:
  --!   A non-OK return can still retain execution ownership when Clair needs
  --!   another integration retry. Callers must check `is_active` before
  --!   releasing the operation.
  function start
    (self       : aliased in out Operation;
     argv       : Sonbal.Process_Arguments.Arguments;
     resolution : Clair.Process.Execution.Executable_Resolution;
     cwd        : String;
     timeout_ms : Natural;
     handler    : Completion_Handler_Access)
  return Clair.Status.Code;

  --! summary Retry one retained Clair Event Loop integration action.
  function retry
    (self : aliased in out Operation)
  return Clair.Status.Code;

  --! summary Cancel active execution using the bounded shutdown policy.
  --! notes:
  --!   Repeating cancellation while the same operation is settling is
  --!   idempotent and retries retained Event Loop integration instead of
  --!   issuing a second cancellation transition.
  function cancel
    (self : aliased in out Operation)
  return Clair.Status.Code;

private

  type Completion_Bridge is limited record
    owner : Operation_Access := null;
  end record;
  function completion_callback
    (process_binding : not null
       Clair.Process.Execution.Event_Loop.Binding_Access;
     cause           : Clair.Process.Execution.Event_Loop.Operation_Cause;
     status          : Clair.Status.Code;
     outcome         : Clair.Process.Execution.Result;
     context         : System.Address)
  return Clair.Status.Code;

  type Operation is limited record
    binding            : aliased Clair.Process.Execution.Event_Loop.Binding;
    bridge             : aliased Completion_Bridge;
    client             : Completion_Handler_Access := null;
    workspace_tokens        : Sonbal.Workspace_Tokens.Context_Access := null;
    admission          : Sonbal.Process_Admission.Context_Access := null;
    work_ticket        : Sonbal.Workspace_Tokens.Work_Ticket;
    admission_owned    : Boolean := False;
    initialized        : Boolean := False;
    active             : Boolean := False;
    cancelling         : Boolean := False;
  end record;

end Sonbal.Process_Execution;
