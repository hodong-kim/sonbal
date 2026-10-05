-- ============================================================================
-- sonbal-mcp-request_core.ads
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

private with Ada.Real_Time;
with Clair.Event_Loop;
with Clair.Process.Execution;
with Clair.Status;
with Interfaces;
with Sonbal.MCP.Dispatcher;
with Sonbal.Configuration;
with Sonbal.MCP.JSON;
with Sonbal.Process_Execution;
with Sonbal.Process_Runtime;

package Sonbal.MCP.Request_Core is

  -- Transport-independent owner of MCP dispatch and process start/completion.
  -- Transport adapters retain framing, request slots, and output I/O.
  type Context is limited private;

  --! summary Initialize transport-independent dispatch and process runtime.
  function initialize
    (self           : in out Context;
     event_loop     : aliased in out Clair.Event_Loop.Context;
     max_work_slots : Sonbal.Configuration.Work_Slot_Count)
  return Clair.Status.Code;

  function is_initialized (self : Context) return Boolean;
  function is_idle (self : Context) return Boolean;
  function active_execution_count (self : Context) return Natural;

  procedure handle
    (self   : in out Context;
     input  : String;
     result : out Sonbal.MCP.Dispatcher.Dispatch_Result);

  procedure handle_parsed
    (self    : in out Context;
     message : Sonbal.MCP.JSON.Message;
     status  : Sonbal.MCP.JSON.Parse_Status;
     result  : out Sonbal.MCP.Dispatcher.Dispatch_Result);

  -- Execute one dispatcher action. A started run_process remains owned by the
  -- caller-provided process operation until completion/output settlement.
  -- False reports an internal dispatcher or process-ownership failure.
  function process_result
    (self            : in out Context;
     result          : in out Sonbal.MCP.Dispatcher.Dispatch_Result;
     process         : aliased in out Sonbal.Process_Execution.Operation;
     process_handler : Sonbal.Process_Execution.Completion_Handler_Access)
  return Boolean;

  procedure complete_request_execution
    (self    : in out Context;
     result  : in out Sonbal.MCP.Dispatcher.Dispatch_Result;
     status  : Clair.Status.Code;
     outcome : Clair.Process.Execution.Result);

  procedure complete_run_process
    (self    : in out Context;
     result  : in out Sonbal.MCP.Dispatcher.Dispatch_Result;
     status  : Clair.Status.Code;
     outcome : Clair.Process.Execution.Result);

  procedure complete_run_process_execution_busy
    (self   : in out Context;
     result : in out Sonbal.MCP.Dispatcher.Dispatch_Result);

  --! summary Record that Sonbal handed the final response to its transport owner.
  --! notes
  --!   This boundary does not imply external peer or UI receipt. It means
  --!   only that the owning transport accepted the terminal response.
  --!   Diagnostic correlation is server-local and never serialized.
  procedure mark_transport_response_handoff
    (self   : in out Context;
     result : Sonbal.MCP.Dispatcher.Dispatch_Result);

  --! summary Record that the transport abandoned a correlated response.
  procedure mark_transport_response_abandoned
    (self   : in out Context;
     result : Sonbal.MCP.Dispatcher.Dispatch_Result);

  --! summary Stop new dispatch and request bounded runtime settlement.
  function stop (self : in out Context) return Boolean;

  --! summary Finalize one idle dispatch/runtime owner.
  function finalize
    (self : in out Context) return Clair.Status.Code;

private
  MAXIMUM_TRACE_EVENTS : constant Positive := 256;

  type Trace_Event_Kind is
    (Trace_Request_Admitted,
     Trace_Run_Execution_Started,
     Trace_Run_Execution_Completed,
     Trace_Read_Execution_Started,
     Trace_Read_Execution_Completed,
     Trace_Response_Ready,
     Trace_Transport_Response_Handoff,
     Trace_Transport_Response_Abandoned);

  type Trace_Event is record
    ordinal     : Interfaces.Unsigned_64 := 0;
    correlation : Interfaces.Unsigned_64 := 0;
    action      : Sonbal.MCP.Dispatcher.Action_Kind :=
      Sonbal.MCP.Dispatcher.No_Action;
    kind        : Trace_Event_Kind := Trace_Request_Admitted;
    time_value  : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
  end record;

  type Trace_Event_Array is array (Positive range <>) of Trace_Event;

  type Context is limited record
    dispatcher  : Sonbal.MCP.Dispatcher.Context;
    runtime     : aliased Sonbal.Process_Runtime.Context;
    trace_events : Trace_Event_Array (1 .. MAXIMUM_TRACE_EVENTS);
    trace_count : Natural range 0 .. MAXIMUM_TRACE_EVENTS := 0;
    trace_next_index : Positive range 1 .. MAXIMUM_TRACE_EVENTS := 1;
    trace_overwrite_count : Interfaces.Unsigned_64 := 0;
    trace_next_ordinal : Interfaces.Unsigned_64 := 1;
    trace_next_correlation : Interfaces.Unsigned_64 := 1;
    trace_epoch : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
    trace_enabled : Boolean := False;
    trace_log_enabled : Boolean := False;
    initialized : Boolean := False;
  end record;
end Sonbal.MCP.Request_Core;
