-- ============================================================================
-- sonbal_mcp_request_core_tests.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Ada.Directories;
with Ada.Real_Time;
with Clair.Event_Loop;
with Clair.Process.Execution;
with Clair.Process.Execution.Event_Loop;
with Clair.Status;
with Interfaces;
with Sonbal.Configuration;
with Sonbal.MCP.Dispatcher;
with Sonbal.MCP.Request_Core;
with Sonbal.MCP.Request_Core.Tester;
with Sonbal.Process_Execution;
with Sonbal_Test_Support;

package body Sonbal_MCP_Request_Core_Tests is

  use type Ada.Real_Time.Time;
  use type Clair.Process.Execution.Event_Loop.Operation_Cause;
  use type Clair.Status.Code;
  use type Interfaces.Unsigned_64;
  use type Sonbal.MCP.Dispatcher.Action_Kind;

  type Core_Access is access all Sonbal.MCP.Request_Core.Context;
  type Result_Access is access all Sonbal.MCP.Dispatcher.Dispatch_Result;

  type Completion_Bridge is limited new
    Sonbal.Process_Execution.Completion_Handler with record
      core   : Core_Access := null;
      result : Result_Access := null;
      called : Boolean := False;
      cause  : Clair.Process.Execution.Event_Loop.Operation_Cause :=
        Clair.Process.Execution.Event_Loop.Ordinary_Execution;
    end record;

  overriding function on_complete
    (handler   : in out Completion_Bridge;
     operation : not null Sonbal.Process_Execution.Operation_Access;
     cause     : Clair.Process.Execution.Event_Loop.Operation_Cause;
     status    : Clair.Status.Code;
     outcome   : Clair.Process.Execution.Result)
  return Clair.Status.Code
  is
    pragma Unreferenced (operation);
  begin
    if handler.core = null or else handler.result = null then
      return Clair.Status.INTERNAL_ERROR;
    end if;

    handler.cause := cause;
    Sonbal.MCP.Request_Core.complete_run_process
      (handler.core.all, handler.result.all, status, outcome);
    handler.called := True;
    return Clair.Status.OK;
  exception
    when others =>
      return Clair.Status.INTERNAL_ERROR;
  end on_complete;

  function request_meta return String is
  begin
    return
      """_meta"":{""" &
      "io.modelcontextprotocol/protocolVersion"":""" &
      Sonbal.MCP.Dispatcher.Protocol_Version &
      """,""io.modelcontextprotocol/clientCapabilities"":{}," &
      """io.modelcontextprotocol/clientInfo"":{" &
      """name"":""client"",""version"":""1""}}";
  end request_meta;

  function tools_call_request
    (id        : String;
     name      : String;
     arguments : String := "")
  return String
  is
    arguments_field : constant String :=
      (if arguments'length = 0
       then ""
       else ",""arguments"":" & arguments);
  begin
    return
      "{""jsonrpc"":""2.0"",""id"":" & id &
      ",""method"":""tools/call"",""params"":{" &
      request_meta & ",""name"":""" & name & """" &
      arguments_field & "}}";
  end tools_call_request;

  function prepare_workspace (name : String) return String is
    root : constant String :=
      Ada.Directories.Full_Name ("build/tmp") &
      "/sonbal-request-core-" & name;
  begin
    Ada.Directories.Create_Path ("build/tmp");
    if Ada.Directories.Exists (root) then
      Ada.Directories.Delete_Tree (root);
    end if;
    Ada.Directories.Create_Path (root);
    return root;
  end prepare_workspace;

  procedure cleanup_workspace (root : String) is
  begin
    if Ada.Directories.Exists (root) then
      Ada.Directories.Delete_Tree (root);
    end if;
  exception
    when others =>
      null;
  end cleanup_workspace;

  procedure finalize_core
    (reporter     : in out Clair.Test.Reporter.Context;
     core         : in out Sonbal.MCP.Request_Core.Context;
     loop_context : in out Clair.Event_Loop.Context)
  is
    status : Clair.Status.Code;
  begin
    Sonbal_Test_Support.check
      (reporter,
       Sonbal.MCP.Request_Core.stop (core),
       "request core trace fixture stops");

    status := Sonbal.MCP.Request_Core.finalize (core);
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK,
       "request core trace fixture finalizes");

    status := Clair.Event_Loop.finalize (loop_context);
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK,
       "request core trace Event Loop finalizes");
  end finalize_core;

  procedure request_trace_is_bounded_and_correlated
    (reporter : in out Clair.Test.Reporter.Context)
  is
    loop_context : aliased Clair.Event_Loop.Context;
    core         : Sonbal.MCP.Request_Core.Context;
    process      : aliased Sonbal.Process_Execution.Operation;
    result       : Sonbal.MCP.Dispatcher.Dispatch_Result;
    status       : Clair.Status.Code;
    first_correlation  : Interfaces.Unsigned_64;
    second_correlation : Interfaces.Unsigned_64;
    ordered      : Boolean := True;

    procedure emit_ping (handoff : Boolean) is
      accepted : Boolean;
    begin
      Sonbal.MCP.Request_Core.handle
        (core, tools_call_request ("1", "ping", "{}"), result);
      accepted :=
        Sonbal.MCP.Request_Core.process_result
          (core, result, process, null);
      if not accepted then
        raise Program_Error with "ping request-core processing failed";
      end if;

      if handoff then
        Sonbal.MCP.Request_Core.mark_transport_response_handoff
          (core, result);
      else
        Sonbal.MCP.Request_Core.mark_transport_response_abandoned
          (core, result);
      end if;
    end emit_ping;
  begin
    status := Clair.Event_Loop.initialize (loop_context);
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK,
       "request core trace Event Loop initializes");
    if status /= Clair.Status.OK then
      return;
    end if;

    status := Sonbal.MCP.Request_Core.initialize
      (core,
       loop_context,
       Sonbal.Configuration.Work_Slot_Count (1));
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK,
       "request core trace fixture initializes");
    if status /= Clair.Status.OK then
      status := Clair.Event_Loop.finalize (loop_context);
      return;
    end if;

    Sonbal.MCP.Request_Core.Tester.enable_trace (core);
    emit_ping (True);
    emit_ping (False);

    Sonbal_Test_Support.check
      (reporter,
       Sonbal.MCP.Request_Core.Tester.trace_event_count (core) = 6 and then
       Sonbal.MCP.Request_Core.Tester.trace_event_kind (core, 1) =
         "request_admitted" and then
       Sonbal.MCP.Request_Core.Tester.trace_event_kind (core, 2) =
         "response_ready" and then
       Sonbal.MCP.Request_Core.Tester.trace_event_kind (core, 3) =
         "transport_response_handoff" and then
       Sonbal.MCP.Request_Core.Tester.trace_event_kind (core, 6) =
         "transport_response_abandoned",
       "request trace records response handoff and abandonment");

    first_correlation :=
      Sonbal.MCP.Request_Core.Tester.trace_event_correlation (core, 1);
    second_correlation :=
      Sonbal.MCP.Request_Core.Tester.trace_event_correlation (core, 4);
    Sonbal_Test_Support.check
      (reporter,
       first_correlation /= 0 and then
       first_correlation =
         Sonbal.MCP.Request_Core.Tester.trace_event_correlation (core, 2) and then
       first_correlation =
         Sonbal.MCP.Request_Core.Tester.trace_event_correlation (core, 3) and then
       second_correlation /= 0 and then
       second_correlation /= first_correlation and then
       second_correlation =
         Sonbal.MCP.Request_Core.Tester.trace_event_correlation (core, 5) and then
       second_correlation =
         Sonbal.MCP.Request_Core.Tester.trace_event_correlation (core, 6),
       "request trace preserves one non-authority correlation per request");

    for iteration in 1 .. 100 loop
      emit_ping (True);
    end loop;

    Sonbal_Test_Support.check
      (reporter,
       Sonbal.MCP.Request_Core.Tester.trace_event_count (core) =
         Sonbal.MCP.Request_Core.Tester.trace_capacity and then
       Sonbal.MCP.Request_Core.Tester.trace_overwrite_count (core) > 0,
       "request trace remains fixed-capacity under repeated requests");

    for position in 2 ..
      Sonbal.MCP.Request_Core.Tester.trace_event_count (core)
    loop
      if Sonbal.MCP.Request_Core.Tester.trace_event_ordinal
           (core, position) <=
         Sonbal.MCP.Request_Core.Tester.trace_event_ordinal
           (core, position - 1)
      then
        ordered := False;
        exit;
      end if;
    end loop;
    Sonbal_Test_Support.check
      (reporter,
       ordered,
       "request trace retained ordinals stay strictly increasing");

    finalize_core (reporter, core, loop_context);
  exception
    when others =>
      Sonbal_Test_Support.check
        (reporter, False, "request trace bounded-correlation scenario");
  end request_trace_is_bounded_and_correlated;

  procedure run_process_trace_follows_lifecycle
    (reporter : in out Clair.Test.Reporter.Context)
  is
    root         : constant String := prepare_workspace ("run");
    loop_context : aliased Clair.Event_Loop.Context;
    core         : aliased Sonbal.MCP.Request_Core.Context;
    process      : aliased Sonbal.Process_Execution.Operation;
    result       : aliased Sonbal.MCP.Dispatcher.Dispatch_Result;
    handler      : aliased Completion_Bridge;
    status       : Clair.Status.Code;
    accepted     : Boolean;
    dispatched   : Boolean := False;
    deadline     : Ada.Real_Time.Time;
    token        : String (1 .. 66) := [others => Character'Val (0)];
  begin
    status := Clair.Event_Loop.initialize (loop_context);
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK,
       "run trace Event Loop initializes");
    if status /= Clair.Status.OK then
      cleanup_workspace (root);
      return;
    end if;

    status := Sonbal.MCP.Request_Core.initialize
      (core,
       loop_context,
       Sonbal.Configuration.Work_Slot_Count (1));
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK,
       "run trace request core initializes");
    if status /= Clair.Status.OK then
      status := Clair.Event_Loop.finalize (loop_context);
      cleanup_workspace (root);
      return;
    end if;

    Sonbal.MCP.Request_Core.Tester.enable_trace (core);
    token := Sonbal.MCP.Request_Core.Tester.rotate_workspace_token (core, root);

    status := Sonbal.Process_Execution.initialize (process, loop_context);
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK,
       "run trace process slot initializes");
    if status /= Clair.Status.OK then
      finalize_core (reporter, core, loop_context);
      cleanup_workspace (root);
      return;
    end if;

    handler.core := core'unchecked_access;
    handler.result := result'unchecked_access;

    Sonbal.MCP.Request_Core.handle
      (core,
       tools_call_request
         ("2",
          "run_process",
          "{""workspace_token"":""" & token &
          """,""argv"":[""/usr/bin/true""]," &
          """resolution"":""exact_path""," &
          """cwd"":""" & root &
          """,""timeout_ms"":5000}"),
       result);
    Sonbal_Test_Support.check
      (reporter,
       result.action = Sonbal.MCP.Dispatcher.Invoke_Run_Process,
       "run trace dispatches synchronous execution");

    accepted :=
      Sonbal.MCP.Request_Core.process_result
        (core, result, process, handler'unchecked_access);
    Sonbal_Test_Support.check
      (reporter,
       accepted and then Sonbal.Process_Execution.is_active (process),
       "run trace records one active synchronous execution");

    deadline := Ada.Real_Time.Clock + Ada.Real_Time.Seconds (5);
    while not handler.called and then Ada.Real_Time.Clock < deadline loop
      status := Clair.Event_Loop.iterate
        (self       => loop_context,
         timeout    => 50,
         dispatched => dispatched);
      exit when status /= Clair.Status.OK;
    end loop;

    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK and then
       handler.called and then
       handler.cause =
         Clair.Process.Execution.Event_Loop.Ordinary_Execution and then
       result.action = Sonbal.MCP.Dispatcher.Write_Response,
       "run trace completion publishes one response");

    Sonbal.MCP.Request_Core.mark_transport_response_handoff (core, result);

    Sonbal_Test_Support.check
      (reporter,
       Sonbal.MCP.Request_Core.Tester.trace_event_count (core) = 5 and then
       Sonbal.MCP.Request_Core.Tester.trace_event_kind (core, 1) =
         "request_admitted" and then
       Sonbal.MCP.Request_Core.Tester.trace_event_kind (core, 2) =
         "run_execution_started" and then
       Sonbal.MCP.Request_Core.Tester.trace_event_kind (core, 3) =
         "run_execution_completed" and then
       Sonbal.MCP.Request_Core.Tester.trace_event_kind (core, 4) =
         "response_ready" and then
       Sonbal.MCP.Request_Core.Tester.trace_event_kind (core, 5) =
         "transport_response_handoff",
       "run trace preserves execution and response lifecycle order");

    declare
      correlation : constant Interfaces.Unsigned_64 :=
        Sonbal.MCP.Request_Core.Tester.trace_event_correlation (core, 1);
      consistent  : Boolean := correlation /= 0;
    begin
      for position in 1 ..
        Sonbal.MCP.Request_Core.Tester.trace_event_count (core)
      loop
        consistent :=
          consistent and then
          Sonbal.MCP.Request_Core.Tester.trace_event_correlation
            (core, position) = correlation and then
          Sonbal.MCP.Request_Core.Tester.trace_event_action
            (core, position) = "run_process";
      end loop;
      Sonbal_Test_Support.check
        (reporter,
         consistent,
         "run trace keeps one request correlation through transport handoff");
    end;

    status := Sonbal.Process_Execution.finalize (process);
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK,
       "run trace process slot finalizes");

    finalize_core (reporter, core, loop_context);
    cleanup_workspace (root);
  exception
    when others =>
      cleanup_workspace (root);
      Sonbal_Test_Support.check
        (reporter, False, "run trace lifecycle scenario");
  end run_process_trace_follows_lifecycle;

  procedure run (reporter : in out Clair.Test.Reporter.Context) is
  begin
    Clair.Test.Reporter.run_scenario
      (reporter,
       "bounded request and transport trace",
       request_trace_is_bounded_and_correlated'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "synchronous run request trace lifecycle",
       run_process_trace_follows_lifecycle'access);
  end run;

end Sonbal_MCP_Request_Core_Tests;
