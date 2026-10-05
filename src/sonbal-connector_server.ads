-- ============================================================================
-- sonbal-connector_server.ads
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Clair.Event_Loop;
with Clair.IO;
with Clair.Status;
with Sonbal.Configuration;
private with Clair.Process.Execution;
private with Clair.Process.Execution.Event_Loop;
private with Sonbal.Connector_ABI;
private with Sonbal.Connector_Host;
private with Sonbal.MCP.Dispatcher;
private with Sonbal.MCP.JSON;
private with Sonbal.MCP.Request_Core;
private with Sonbal.Process_Execution;

package Sonbal.Connector_Server is

  type Context is limited private;

  --! summary Initialize one connector transport adapter and shared MCP core.
  --! ownership
  --!   Startup descriptor ownership is transferred to the connector host once
  --!   host initialization begins; successful and host-level rollback paths
  --!   close those descriptors before returning.
  function initialize
    (self             : aliased in out Context;
     event_loop       : aliased in out Clair.Event_Loop.Context;
     plugin_path      : String;
     configuration_fd : in out Clair.IO.Descriptor;
     credential_fd    : in out Clair.IO.Descriptor;
     max_work_slots   : Sonbal.Configuration.Work_Slot_Count)
  return Clair.Status.Code;

  --! summary Start provider ingress after all bounded request slots are ready.
  function start (self : in out Context) return Clair.Status.Code;

  --! summary Stop provider ingress and begin bounded transport/runtime settlement.
  function begin_shutdown (self : in out Context) return Clair.Status.Code;

  function is_initialized (self : Context) return Boolean;
  function active_request_count (self : Context) return Natural;
  function active_execution_count (self : Context) return Natural;
  function is_settled (self : Context) return Boolean;
  function has_failed (self : Context) return Boolean;

  --! summary Finalize one never-started or fully settled connector server.
  function finalize (self : in out Context) return Clair.Status.Code;

private

  type Slot_State is
    (Slot_Free,
     Slot_Unresolved,
     Slot_Ready,
     Slot_Abandoned_Unresolved);

  type Request_Slot is limited record
    state   : Slot_State := Slot_Free;
    token   : Sonbal.Connector_ABI.Request_Token :=
      Sonbal.Connector_ABI.NO_REQUEST_TOKEN;
    result  : Sonbal.MCP.Dispatcher.Dispatch_Result;
    process : aliased Sonbal.Process_Execution.Operation;
  end record;

  type Request_Slot_Array is array (Positive range <>) of Request_Slot;
  type Request_Slot_Array_Access is access Request_Slot_Array;

  type Context_Access is access all Context;

  type Progress_Bridge is limited new
    Sonbal.Connector_Host.Progress_Handler with record
      owner : Context_Access := null;
    end record;

  overriding function on_connector_progress
    (handler : in out Progress_Bridge)
  return Clair.Status.Code;

  type Process_Completion_Bridge is limited new
    Sonbal.Process_Execution.Completion_Handler with record
      owner : Context_Access := null;
    end record;

  overriding function on_complete
    (handler   : in out Process_Completion_Bridge;
     operation : not null Sonbal.Process_Execution.Operation_Access;
     cause     : Clair.Process.Execution.Event_Loop.Operation_Cause;
     status    : Clair.Status.Code;
     outcome   : Clair.Process.Execution.Result)
  return Clair.Status.Code;

  type Server_Failure is
    (No_Failure,
     Connector_Failure,
     Connector_Contract_Failure,
     Dispatcher_Failure,
     Process_Binding_Failure,
     Process_Cancellation_Failure,
     Runtime_Failure,
     Internal_Failure);

  type Context is limited record
    event_loop       : Clair.Event_Loop.Context_Access := null;
    host             : aliased Sonbal.Connector_Host.Context;
    core             : Sonbal.MCP.Request_Core.Context;
    slots            : Request_Slot_Array_Access := null;
    request_slot_count : Positive range
      2 .. Sonbal.Configuration.ABSOLUTE_MAX_WORK_SLOTS + 1 :=
        Sonbal.Configuration.DEFAULT_MAX_WORK_SLOTS + 1;
    progress_handler : aliased Progress_Bridge;
    process_handler  : aliased Process_Completion_Bridge;
    request_buffer : aliased String
      (1 .. Sonbal.MCP.JSON.Max_Input_Bytes);
    correlation_buffer : aliased String
      (1 .. Sonbal.Connector_ABI.MAXIMUM_DIAGNOSTIC_CORRELATION_BYTES);
    response_buffer : aliased String
      (1 .. Sonbal.MCP.Dispatcher.MAXIMUM_MCP_RESPONSE_BYTES);
    initialized    : Boolean := False;
    started        : Boolean := False;
    stopping       : Boolean := False;
    core_stopping  : Boolean := False;
    host_finalized : Boolean := False;
    failure     : Server_Failure := No_Failure;
  end record;

end Sonbal.Connector_Server;
