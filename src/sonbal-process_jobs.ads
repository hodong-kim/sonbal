-- ============================================================================
-- sonbal-process_jobs.ads
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

private with Ada.Real_Time;
with Clair.Event_Loop;
with Clair.Process.Execution;
with Clair.Process.Execution.Event_Loop;
with Clair.Status;
with Interfaces;
with Sonbal.Process_Arguments;
with Sonbal.Configuration;
with Sonbal.Process_Admission;
with Sonbal.Process_Execution;
with Sonbal.Workspace_Tokens;
with System.Storage_Elements;

package Sonbal.Process_Jobs is

  -- Bounded server-owned process-job state. Transport/request lifetime does
  -- not own accepted jobs; Process_Runtime and strict process settlement do.

  MAXIMUM_JOB_ID_BYTES : constant Positive := 82;
  MAXIMUM_CURSOR_BYTES : constant Positive := 94;
  POLL_STREAM_BYTES    : constant Positive := 8_192;

  type Job_Identifier is private;
  type Job_Cursor is private;

  function image (value : Job_Identifier) return String;
  function image (value : Job_Cursor) return String;

  type Start_State is
    (Start_Running,
     Start_Execution_Busy,
     Start_Stale_Workspace_Token,
     Start_Outside_Workspace,
     Start_Execution_Failed);

  type Start_Result is record
    state  : Start_State := Start_Execution_Failed;
    job_id : Job_Identifier;
    cursor : Job_Cursor;
    diagnostic_correlation : Interfaces.Unsigned_64 := 0;
  end record;

  type Terminal_State is
    (Job_Exited,
     Job_Signaled,
     Job_Timed_Out,
     Job_Launch_Failed,
     Job_Cancelled,
     Job_Execution_Failed);

  type Poll_State is
    (Poll_Running,
     Poll_Terminal,
     Poll_Expired,
     Poll_Stale_Instance,
     Poll_Not_Found,
     Poll_Invalid_Cursor,
     Poll_Execution_Failed);

  subtype Poll_Storage is System.Storage_Elements.Storage_Array
    (1 .. System.Storage_Elements.Storage_Offset(POLL_STREAM_BYTES));

  type Poll_Stream is record
    data      : Poll_Storage := [others => 0];
    length    : Natural range 0 .. POLL_STREAM_BYTES := 0;
    truncated : Boolean := False;
  end record;

  type Poll_Result is record
    state          : Poll_State := Poll_Not_Found;
    job_id         : Job_Identifier;
    stdout         : Poll_Stream;
    stderr         : Poll_Stream;
    next_cursor    : Job_Cursor;
    terminal       : Terminal_State := Job_Execution_Failed;
    has_exit_code  : Boolean := False;
    exit_code      : Interfaces.Unsigned_32 := 0;
    has_launch_stage : Boolean := False;
    launch_stage   : Clair.Process.Execution.Launch_Stage :=
      Clair.Process.Execution.Program_Execution_Stage;
    has_infrastructure_stage : Boolean := False;
    infrastructure_stage : Clair.Process.Execution.Infrastructure_Stage :=
      Clair.Process.Execution.Execution_Preparation_Stage;
    diagnostic_correlation : Interfaces.Unsigned_64 := 0;
    has_ownership_stage : Boolean := False;
    ownership_stage : Clair.Process.Execution.Ownership_Failure_Stage :=
      Clair.Process.Execution.Ownership_Setup_Stage;
  end record;

  type Cancel_State is
    (Cancel_Cancelling,
     Cancel_Already_Terminal,
     Cancel_Expired,
     Cancel_Stale_Instance,
     Cancel_Not_Found,
     Cancel_Execution_Failed);

  type Cancel_Result is record
    state  : Cancel_State := Cancel_Not_Found;
    job_id : Job_Identifier;
    diagnostic_correlation : Interfaces.Unsigned_64 := 0;
  end record;

  type Context is limited private;

  --! summary Initialize one server-owned bounded process-job registry.
  --! ownership
  --!   `event_loop` remains caller-owned and valid until successful finalize.
  --!   At most `max_jobs` process executions can be active concurrently.
  function initialize
    (self       : aliased in out Context;
     event_loop : aliased in out Clair.Event_Loop.Context;
     workspace_tokens : aliased in out Sonbal.Workspace_Tokens.Context;
     admission  : aliased in out Sonbal.Process_Admission.Context;
     max_jobs   : Sonbal.Configuration.Work_Slot_Count)
  return Clair.Status.Code;

  --! summary Start one server-owned process job without queuing.
  --! notes
  --!   A successful start returns an opaque job ID and zero-offset cursor.
  --!   The job remains owned by this registry after the tool request returns.
  procedure start
    (self       : aliased in out Context;
     workspace_token : String;
     argv       : Sonbal.Process_Arguments.Arguments;
     resolution : Clair.Process.Execution.Executable_Resolution;
     cwd        : String;
     timeout_ms : Natural;
     result     : out Start_Result);

  --! summary Read one bounded output increment at `cursor`.
  --! contract
  --!   Registry calls are serialized on the owner Event Loop thread; a running
  --!   or cancelling poll therefore satisfies Clair's live-observation owner.
  --! notes
  --!   Running jobs read Clair's owner-thread append-only retained prefix
  --!   directly without advancing backend progress or a hidden server cursor.
  --!   Terminal jobs read the bounded copy retained at settlement. A caller may
  --!   retry the same cursor without losing bytes; later Event Loop progress
  --!   may
  --!   append more bytes after that cursor.
  procedure poll
    (self   : in out Context;
     job_id : String;
     cursor : String;
     result : out Poll_Result);

  --! summary Request bounded idempotent cancellation of one live job.
  --! notes
  --!   `Cancel_Cancelling` means cancellation is requested or already in
  --!   progress. Only a terminal `poll` result proves descendant settlement.
  procedure cancel
    (self   : aliased in out Context;
     job_id : String;
     result : out Cancel_Result);

  --! summary Record request-core response serialization completion.
  --! notes Diagnostic correlations are non-authority server-local serials and
  --!   are never serialized onto the MCP wire.
  procedure mark_start_response_ready
    (self   : in out Context;
     result : Start_Result);

  procedure mark_poll_response_ready
    (self   : in out Context;
     result : Poll_Result);

  procedure mark_cancel_response_ready
    (self   : in out Context;
     result : Cancel_Result);

  --! summary Stop job admission and request cancellation of every live job.
  function begin_shutdown
    (self : aliased in out Context) return Clair.Status.Code;

  --! summary Return true only when no process execution remains active.
  function is_idle (self : Context) return Boolean;

  function is_initialized (self : Context) return Boolean;

  --! summary Release an idle registry and all retained terminal output.
  function finalize
    (self : aliased in out Context) return Clair.Status.Code;

private
  MAXIMUM_JOB_RECORDS : constant Positive :=
    2 * Sonbal.Configuration.ABSOLUTE_MAX_WORK_SLOTS;

  type Job_Instance_Identifier is record
    data   : String (1 .. 32) := [others => Character'val(0)];
    length : Natural range 0 .. 32 := 0;
  end record;

  type Job_Identifier is record
    data   : String (1 .. MAXIMUM_JOB_ID_BYTES) :=
      [others => Character'val(0)];
    length : Natural range 0 .. MAXIMUM_JOB_ID_BYTES := 0;
  end record;

  type Job_Cursor is record
    data   : String (1 .. MAXIMUM_CURSOR_BYTES) :=
      [others => Character'val(0)];
    length : Natural range 0 .. MAXIMUM_CURSOR_BYTES := 0;
  end record;

  subtype Retained_Buffer is System.Storage_Elements.Storage_Array
    (1 .. System.Storage_Elements.Storage_Offset(32_768));
  type Retained_Buffer_Access is access Retained_Buffer;

  type Job_Slot_State is
    (Slot_Empty,
     Slot_Running,
     Slot_Cancelling,
     Slot_Terminal);

  MAXIMUM_TRACE_EVENTS : constant Positive := 256;

  type Trace_Event_Kind is
    (Trace_Start_Request,
     Trace_Launch_Accepted,
     Trace_Start_Response,
     Trace_Start_Response_Ready,
     Trace_Poll_Request,
     Trace_Poll_Response,
     Trace_Poll_Response_Ready,
     Trace_Terminal_Observed,
     Trace_Cancellation_Settled,
     Trace_Terminal_Published,
     Trace_Terminal_Evicted,
     Trace_Cancel_Request,
     Trace_Cancel_Response,
     Trace_Cancel_Response_Ready);

  type Trace_Outcome is
    (Trace_None,
     Trace_Running,
     Trace_Terminal,
     Trace_Execution_Busy,
     Trace_Stale_Workspace_Token,
     Trace_Outside_Workspace,
     Trace_Expired,
     Trace_Stale_Instance,
     Trace_Not_Found,
     Trace_Invalid_Cursor,
     Trace_Cancelling,
     Trace_Already_Terminal,
     Trace_Exited,
     Trace_Signaled,
     Trace_Timed_Out,
     Trace_Launch_Failed,
     Trace_Cancelled,
     Trace_Execution_Failed);

  type Trace_Event is record
    ordinal     : Interfaces.Unsigned_64 := 0;
    correlation : Interfaces.Unsigned_64 := 0;
    kind        : Trace_Event_Kind := Trace_Start_Request;
    outcome     : Trace_Outcome := Trace_None;
    time_value  : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
  end record;

  type Trace_Event_Array is array (Positive range <>) of Trace_Event;

  type Job_Slot is limited record
    state       : Job_Slot_State := Slot_Empty;
    job_id      : Job_Identifier;
    sequence    : Interfaces.Unsigned_64 := 0;
    trace_correlation : Interfaces.Unsigned_64 := 0;
    process     : aliased Sonbal.Process_Execution.Operation;
    stdout_data : Retained_Buffer_Access := null;
    stdout_length : Natural range 0 .. 32_768 := 0;
    stdout_truncated : Boolean := False;
    stderr_data : Retained_Buffer_Access := null;
    stderr_length : Natural range 0 .. 32_768 := 0;
    stderr_truncated : Boolean := False;
    terminal    : Terminal_State := Job_Execution_Failed;
    has_exit_code : Boolean := False;
    exit_code     : Interfaces.Unsigned_32 := 0;
    has_launch_stage : Boolean := False;
    launch_stage : Clair.Process.Execution.Launch_Stage :=
      Clair.Process.Execution.Program_Execution_Stage;
    has_infrastructure_stage : Boolean := False;
    infrastructure_stage : Clair.Process.Execution.Infrastructure_Stage :=
      Clair.Process.Execution.Execution_Preparation_Stage;
    has_ownership_stage : Boolean := False;
    ownership_stage : Clair.Process.Execution.Ownership_Failure_Stage :=
      Clair.Process.Execution.Ownership_Setup_Stage;
  end record;

  type Job_Slot_Array is array (Positive range <>) of Job_Slot;
  type Job_Slot_Array_Access is access Job_Slot_Array;

  type Completion_Bridge is limited new
    Sonbal.Process_Execution.Completion_Handler with record
      owner : access Context := null;
  end record;

  overriding function on_complete
    (handler   : in out Completion_Bridge;
     operation : not null Sonbal.Process_Execution.Operation_Access;
     cause     : Clair.Process.Execution.Event_Loop.Operation_Cause;
     status    : Clair.Status.Code;
     outcome   : Clair.Process.Execution.Result)
  return Clair.Status.Code;

  type Context is limited record
    loop_context : Clair.Event_Loop.Context_Access := null;
    workspace_tokens  : Sonbal.Workspace_Tokens.Context_Access := null;
    admission    : Sonbal.Process_Admission.Context_Access := null;
    slots        : Job_Slot_Array_Access := null;
    capacity     : Natural range 0 .. MAXIMUM_JOB_RECORDS := 0;
    terminal_limit : Natural range
      0 .. Sonbal.Configuration.ABSOLUTE_MAX_WORK_SLOTS := 0;
    initialized_count : Natural range 0 .. MAXIMUM_JOB_RECORDS := 0;
    instance_id   : Job_Instance_Identifier;
    next_sequence : Interfaces.Unsigned_64 := 1;
    trace_events : Trace_Event_Array (1 .. MAXIMUM_TRACE_EVENTS);
    trace_count : Natural range 0 .. MAXIMUM_TRACE_EVENTS := 0;
    trace_next_index : Positive range 1 .. MAXIMUM_TRACE_EVENTS := 1;
    trace_overwrite_count : Interfaces.Unsigned_64 := 0;
    trace_next_ordinal : Interfaces.Unsigned_64 := 1;
    trace_next_correlation : Interfaces.Unsigned_64 := 1;
    trace_epoch : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
    trace_enabled : Boolean := False;
    trace_log_enabled : Boolean := False;
    handler       : aliased Completion_Bridge;
    initialized   : Boolean := False;
    shutting_down : Boolean := False;
  end record;

end Sonbal.Process_Jobs;
