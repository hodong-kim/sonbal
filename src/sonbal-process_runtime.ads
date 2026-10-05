-- ============================================================================
-- sonbal-process_runtime.ads
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Clair.Event_Loop;
with Clair.IO;
with Clair.Process.Execution;
with Clair.Process.Execution.Event_Loop;
with Clair.Status;
with Sonbal.Process_Arguments;
with Sonbal.Configuration;
with Sonbal.Process_Admission;
with Sonbal.Process_Execution;
with Sonbal.Process_Jobs;
with Sonbal.Workspace_Tokens;

package Sonbal.Process_Runtime is

  type Context is limited private;

  --! summary Initialize one bounded server process runtime.
  --! ownership:
  --!   `event_loop` remains caller-owned and valid until successful finalize.
  --!   The runtime owns one workspace registry, one shared execution-admission
  --!   counter, one server-owned job registry, and at most `max_work_slots`
  --!   synchronous execution attributions.
  function initialize
    (self           : aliased in out Context;
     event_loop     : aliased in out Clair.Event_Loop.Context;
     max_work_slots : Sonbal.Configuration.Work_Slot_Count)
  return Clair.Status.Code;

  --! summary Prepare, rotate, or replay one generation-fenced workspace token.
  function rotate_workspace_token
    (self         : in out Context;
     root         : String;
     operation_id : String;
     result       : out Sonbal.Workspace_Tokens.Rotation_Result)
  return Clair.Status.Code;


  --! summary Start one synchronous request-owned process through shared policy.
  --! ownership:
  --!   `operation` and `handler` remain caller-owned. A running operation is
  --!   registered until its completion bridge has forwarded the settled result
  --!   and all external ownership has been released.
  function start_synchronous
    (self       : aliased in out Context;
     operation  : aliased in out Sonbal.Process_Execution.Operation;
     workspace_token : String;
     argv       : Sonbal.Process_Arguments.Arguments;
     resolution : Clair.Process.Execution.Executable_Resolution;
     cwd        : String;
     timeout_ms : Natural;
     handler    : Sonbal.Process_Execution.Completion_Handler_Access;
     state      : out Sonbal.Process_Execution.Workspace_Start_State)
  return Clair.Status.Code;

  --! summary Start one synchronous request-owned read helper.
  --! ownership:
  --!   The runtime retains one current-executable image descriptor for its
  --!   complete initialized lifetime. The helper borrows that descriptor only
  --!   during native launch and otherwise follows synchronous process ownership.
  function start_file_read
    (self              : aliased in out Context;
     operation         : aliased in out Sonbal.Process_Execution.Operation;
     workspace_token   : String;
     path              : String;
     offset            : Clair.IO.File_Offset;
     maximum_bytes     : Positive;
     expected_revision : String;
     handler           : Sonbal.Process_Execution.Completion_Handler_Access;
     state             : out Sonbal.Process_Execution.Workspace_Start_State)
  return Clair.Status.Code;

  --! summary Start one server-owned process job through shared policy.
  procedure start_job
    (self       : aliased in out Context;
     workspace_token : String;
     argv       : Sonbal.Process_Arguments.Arguments;
     resolution : Clair.Process.Execution.Executable_Resolution;
     cwd        : String;
     timeout_ms : Natural;
     result     : out Sonbal.Process_Jobs.Start_Result);

  procedure poll_job
    (self   : in out Context;
     job_id : String;
     cursor : String;
     result : out Sonbal.Process_Jobs.Poll_Result);

  procedure cancel_job
    (self   : aliased in out Context;
     job_id : String;
     result : out Sonbal.Process_Jobs.Cancel_Result);

  procedure mark_start_job_response_ready
    (self   : in out Context;
     result : Sonbal.Process_Jobs.Start_Result);

  procedure mark_poll_job_response_ready
    (self   : in out Context;
     result : Sonbal.Process_Jobs.Poll_Result);

  procedure mark_cancel_job_response_ready
    (self   : in out Context;
     result : Sonbal.Process_Jobs.Cancel_Result);

  --! summary Stop all new runtime admission and cancel every live execution.
  function begin_shutdown
    (self : aliased in out Context) return Clair.Status.Code;

  function is_initialized (self : Context) return Boolean;
  function is_idle (self : Context) return Boolean;
  function active_execution_count (self : Context) return Natural;
  function active_work_count (self : Context) return Natural;
  function workspace_token_count (self : Context) return Natural;

  --! summary Finalize one idle runtime and discard workspace-token state.
  function finalize
    (self : aliased in out Context) return Clair.Status.Code;

private

  MAXIMUM_SYNC_RECORDS : constant Positive :=
    Sonbal.Configuration.ABSOLUTE_MAX_WORK_SLOTS;

  type Context_Access is access all Context;

  type Completion_Bridge is limited new
    Sonbal.Process_Execution.Completion_Handler with record
      owner : Context_Access := null;
      index : Natural range 0 .. MAXIMUM_SYNC_RECORDS := 0;
    end record;

  overriding function on_complete
    (handler   : in out Completion_Bridge;
     operation : not null Sonbal.Process_Execution.Operation_Access;
     cause     : Clair.Process.Execution.Event_Loop.Operation_Cause;
     status    : Clair.Status.Code;
     outcome   : Clair.Process.Execution.Result)
  return Clair.Status.Code;

  type Sync_Record is limited record
    active          : Boolean := False;
    cancelling      : Boolean := False;
    completion_seen : Boolean := False;
    operation       : Sonbal.Process_Execution.Operation_Access := null;
    client          :
      Sonbal.Process_Execution.Completion_Handler_Access := null;
    bridge          : aliased Completion_Bridge;
  end record;

  type Sync_Record_Array is array (Positive range <>) of Sync_Record;

  type Context is limited record
    executable_image : Clair.IO.Descriptor := Clair.IO.INVALID_DESCRIPTOR;
    workspace_tokens : aliased Sonbal.Workspace_Tokens.Context;
    admission     : aliased Sonbal.Process_Admission.Context;
    jobs          : aliased Sonbal.Process_Jobs.Context;
    sync_records  : Sync_Record_Array (1 .. MAXIMUM_SYNC_RECORDS);
    sync_capacity : Natural range 0 .. MAXIMUM_SYNC_RECORDS := 0;
    initialized   : Boolean := False;
    shutting_down : Boolean := False;
  end record;

end Sonbal.Process_Runtime;
