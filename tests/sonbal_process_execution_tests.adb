-- ============================================================================
-- sonbal_process_execution_tests.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Ada.Real_Time;
with Ada.Strings.Fixed;
with Clair.Event_Loop;
with Clair.Process;
with Clair.Process.Execution;
with Clair.Process.Execution.Event_Loop;
with Clair.Status;
with Sonbal.MCP.Dispatcher.Tester;
with Sonbal.Process_Arguments;
with Sonbal.Process_Execution;
with Sonbal_Test_Support;
with System.Storage_Elements;

package body Sonbal_Process_Execution_Tests is

  use type Ada.Real_Time.Time;
  use type Clair.Process.Execution.Completion_Kind;
  use type Clair.Process.Execution.Event_Loop.Operation_Cause;
  use type Clair.Process.Exit_Code;
  use type Clair.Status.Code;
  use type System.Storage_Elements.Storage_Offset;

  type Completion is limited new
    Sonbal.Process_Execution.Completion_Handler with record
      call_count    : Natural := 0;
      cause         : Clair.Process.Execution.Event_Loop.Operation_Cause :=
        Clair.Process.Execution.Event_Loop.Ordinary_Execution;
      status        : Clair.Status.Code := Clair.Status.INTERNAL_ERROR;
      completion    : Clair.Process.Execution.Completion_Kind :=
        Clair.Process.Execution.Exited;
      exit_code     : Clair.Process.Exit_Code := Clair.Process.EXIT_SUCCESS;
      stdout_length : Natural := 0;
      stderr_length : Natural := 0;
      stdout_text   : String (1 .. 32) := [others => Character'val (0)];
      response_length : Natural := 0;
      response_text   : String (1 .. 1_024) :=
        [others => Character'val (0)];
    end record;

  overriding function on_complete
    (handler   : in out Completion;
     operation : not null Sonbal.Process_Execution.Operation_Access;
     cause     : Clair.Process.Execution.Event_Loop.Operation_Cause;
     status    : Clair.Status.Code;
     outcome   : Clair.Process.Execution.Result)
  return Clair.Status.Code
  is
    pragma Unreferenced (operation);
    buffer : System.Storage_Elements.Storage_Array (1 .. 32) :=
      [others => 0];
    copied : Natural := 0;
    retval : Clair.Status.Code;
  begin
    handler.call_count := handler.call_count + 1;
    handler.cause := cause;
    handler.status := status;
    handler.stdout_length :=
      Clair.Process.Execution.standard_output_length (outcome);
    handler.stderr_length :=
      Clair.Process.Execution.standard_error_length (outcome);

    if Clair.Process.Execution.has_completion (outcome) then
      handler.completion := Clair.Process.Execution.completion_of (outcome);
      if handler.completion = Clair.Process.Execution.Exited then
        handler.exit_code := Clair.Process.Execution.exit_code_of (outcome);
      end if;
    end if;

    if handler.stdout_length > handler.stdout_text'length then
      return Clair.Status.RANGE_ERROR;
    end if;

    if handler.stdout_length > 0 then
      retval := Clair.Process.Execution.copy_standard_output
        (outcome => outcome,
         offset => 0,
         buffer => buffer
           (buffer'first ..
            buffer'first +
              System.Storage_Elements.Storage_Offset
                (handler.stdout_length) - 1),
         copied => copied);
      if retval /= Clair.Status.OK or else copied /= handler.stdout_length then
        return Clair.Status.INTERNAL_ERROR;
      end if;

      for index in 1 .. copied loop
        handler.stdout_text(index) := Character'val
          (Integer
             (buffer
                (buffer'first +
                 System.Storage_Elements.Storage_Offset(index - 1))));
      end loop;
    end if;

    declare
      response : constant String :=
        Sonbal.MCP.Dispatcher.Tester.run_process_result_image
          (status, outcome);
    begin
      if response'length = 0 or else
         response'length > handler.response_text'length
      then
        return Clair.Status.INTERNAL_ERROR;
      end if;

      handler.response_text(1 .. response'length) := response;
      handler.response_length := response'length;
    end;

    return Clair.Status.OK;
  end on_complete;

  procedure asynchronous_completion_bridge
    (reporter : in out Clair.Test.Reporter.Context)
  is
    loop_context : aliased Clair.Event_Loop.Context;
    operation    : aliased Sonbal.Process_Execution.Operation;
    callback     : aliased Completion;
    argv         : constant Sonbal.Process_Arguments.Arguments :=
      Sonbal_Test_Support.Process_Arguments ("/bin/echo", "sonbal");
    deadline     : Ada.Real_Time.Time;
    dispatched   : Boolean := False;
    saw_dispatch : Boolean := False;
    status       : Clair.Status.Code;
  begin
    status := Clair.Event_Loop.initialize (loop_context);
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK,
       "process execution test Event Loop initializes");
    if status /= Clair.Status.OK then
      return;
    end if;

    status := Sonbal.Process_Execution.initialize (operation, loop_context);
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK and then
         Sonbal.Process_Execution.is_initialized (operation),
       "process operation binds to the caller Event Loop");
    if status /= Clair.Status.OK then
      status := Clair.Event_Loop.finalize (loop_context);
      Sonbal_Test_Support.check
        (reporter,
         status = Clair.Status.OK,
         "failed process-operation setup releases Event Loop");
      return;
    end if;

    status := Sonbal.Process_Execution.start
      (self       => operation,
       argv       => argv,
       resolution => Clair.Process.Execution.Exact_Path,
       cwd        => "/",
       timeout_ms => 2_000,
       handler    => callback'unchecked_access);
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK and then
         Sonbal.Process_Execution.is_active (operation) and then
         callback.call_count = 0,
       "process execution starts asynchronously without inline completion");

    deadline := Ada.Real_Time.clock + Ada.Real_Time.Seconds (3);
    while callback.call_count = 0 and then
          status = Clair.Status.OK and then
          Ada.Real_Time.clock < deadline
    loop
      status := Clair.Event_Loop.iterate
        (self       => loop_context,
         timeout    => 100,
         dispatched => dispatched);
      saw_dispatch := saw_dispatch or else dispatched;
    end loop;

    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK and then saw_dispatch and then
         callback.call_count = 1 and then
         not Sonbal.Process_Execution.is_active (operation),
       "process completion settles the operation exactly once");
    Sonbal_Test_Support.check
      (reporter,
       callback.cause =
         Clair.Process.Execution.Event_Loop.Ordinary_Execution and then
         callback.status = Clair.Status.OK and then
         callback.completion = Clair.Process.Execution.Exited and then
         callback.exit_code = Clair.Process.EXIT_SUCCESS,
       "completion bridge preserves portable process completion");
    Sonbal_Test_Support.check
      (reporter,
       callback.stdout_length = 7 and then
         callback.stdout_text(1 .. 7) = "sonbal" & Character'val (10) and then
         callback.stderr_length = 0,
       "completion bridge consumes captured output while Result is valid");

    if callback.response_length = 0 then
      Sonbal_Test_Support.check
        (reporter, False, "portable process result is serialized");
    else
      declare
        response : constant String :=
          callback.response_text(1 .. callback.response_length);
      begin
        Sonbal_Test_Support.check
          (reporter,
           Ada.Strings.Fixed.index
             (response, "{""jsonrpc"":""2.0"",""id"":7,") = 1 and then
             Ada.Strings.Fixed.index
               (response,
                """stdout"":{""encoding"":""utf8"",""bytes"":7," &
                """data"":""sonbal\n"",""truncated"":false}") /= 0 and then
             Ada.Strings.Fixed.index
               (response,
                """stderr"":{""encoding"":""utf8"",""bytes"":0," &
                """data"":"""",""truncated"":false}") /= 0 and then
             Ada.Strings.Fixed.index (response, """exit_code"":0") /= 0 and then
             Ada.Strings.Fixed.index (response, """isError"":false") /= 0,
           "portable process result preserves frozen MCP fields");
      end;
    end if;

    if Sonbal.Process_Execution.is_active (operation) then
      status := Sonbal.Process_Execution.cancel (operation);
      Sonbal_Test_Support.check
        (reporter,
         status = Clair.Status.OK or else
           status = Clair.Status.INVALID_STATE,
         "failed process test cancellation remains bounded");
      deadline := Ada.Real_Time.clock + Ada.Real_Time.Seconds (3);
      while Sonbal.Process_Execution.is_active (operation) and then
            Ada.Real_Time.clock < deadline
      loop
        status := Clair.Event_Loop.iterate
          (self       => loop_context,
           timeout    => 100,
           dispatched => dispatched);
        exit when status /= Clair.Status.OK;
      end loop;
    end if;

    status := Sonbal.Process_Execution.finalize (operation);
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK,
       "settled process operation finalizes");
    status := Clair.Event_Loop.finalize (loop_context);
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK,
       "process execution test Event Loop finalizes");
  end asynchronous_completion_bridge;

  procedure cancellation_settles_before_finalize
    (reporter : in out Clair.Test.Reporter.Context)
  is
    loop_context : aliased Clair.Event_Loop.Context;
    operation    : aliased Sonbal.Process_Execution.Operation;
    callback     : aliased Completion;
    argv         : constant Sonbal.Process_Arguments.Arguments :=
      Sonbal_Test_Support.Process_Arguments ("/bin/sleep", "30");
    deadline     : Ada.Real_Time.Time;
    dispatched   : Boolean := False;
    status       : Clair.Status.Code;
    retry_status : Clair.Status.Code := Clair.Status.OK;
  begin
    status := Clair.Event_Loop.initialize (loop_context);
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK,
       "cancellation test Event Loop initializes");
    if status /= Clair.Status.OK then
      return;
    end if;

    status := Sonbal.Process_Execution.initialize (operation, loop_context);
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK,
       "cancellation test process operation initializes");
    if status /= Clair.Status.OK then
      status := Clair.Event_Loop.finalize (loop_context);
      Sonbal_Test_Support.check
        (reporter,
         status = Clair.Status.OK,
         "cancellation setup failure releases Event Loop");
      return;
    end if;

    status := Sonbal.Process_Execution.start
      (self       => operation,
       argv       => argv,
       resolution => Clair.Process.Execution.Exact_Path,
       cwd        => "/",
       timeout_ms => Sonbal.Process_Execution.MAXIMUM_OPERATION_TIMEOUT_MS,
       handler    => callback'unchecked_access);
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK and then
         Sonbal.Process_Execution.is_active (operation),
       "maximum internal process timeout starts before cancellation");

    if status = Clair.Status.OK then
      status := Sonbal.Process_Execution.cancel (operation);
      Sonbal_Test_Support.check
        (reporter,
         status = Clair.Status.OK,
         "shutdown-style process cancellation is accepted");
    end if;

    deadline := Ada.Real_Time.clock + Ada.Real_Time.Seconds (10);
    while Sonbal.Process_Execution.is_active (operation) and then
          Ada.Real_Time.clock < deadline and then
          status = Clair.Status.OK
    loop
      retry_status := Sonbal.Process_Execution.retry (operation);
      if retry_status /= Clair.Status.OK and then
         retry_status /= Clair.Status.INVALID_STATE
      then
        exit;
      end if;

      status := Clair.Event_Loop.iterate
        (self       => loop_context,
         timeout    => 100,
         dispatched => dispatched);
    end loop;

    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK and then
         (retry_status = Clair.Status.OK or else
          retry_status = Clair.Status.INVALID_STATE) and then
         not Sonbal.Process_Execution.is_active (operation) and then
         callback.call_count = 1 and then
         callback.cause =
           Clair.Process.Execution.Event_Loop.Caller_Cancellation,
       "cancellation settles exactly once on the Event Loop");

    status := Sonbal.Process_Execution.finalize (operation);
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK and then
         not Sonbal.Process_Execution.is_initialized (operation),
       "cancelled process binding finalizes after settlement");

    status := Clair.Event_Loop.finalize (loop_context);
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK,
       "cancellation test Event Loop finalizes after process binding");
  end cancellation_settles_before_finalize;

  procedure failure_projection_never_becomes_false_success
    (reporter : in out Clair.Test.Reporter.Context)
  is
    procedure check
      (status_failed         : Boolean;
       infrastructure_failed : Boolean;
       cleanup_failed        : Boolean;
       expected              : String;
       label                 : String)
    is
      actual : constant String :=
        Sonbal.MCP.Dispatcher.Tester.run_process_failure_classification
          (status_failed         => status_failed,
           infrastructure_failed => infrastructure_failed,
           cleanup_failed        => cleanup_failed);
    begin
      Sonbal_Test_Support.check
        (reporter,
         actual = expected,
         label);
    end check;
  begin
    check
      (False, False, False,
       "none",
       "clean process result remains nonfailure");
    check
      (True, False, False,
       "status",
       "non-OK execution status cannot become process success");
    check
      (False, True, False,
       "infrastructure",
       "infrastructure failure cannot become process success");
    check
      (False, False, True,
       "cleanup",
       "cleanup failure cannot become process success");
    check
      (True, True, True,
       "infrastructure",
       "infrastructure failure has deterministic precedence");
    check
      (True, False, True,
       "cleanup",
       "cleanup failure has precedence over generic status failure");
  end failure_projection_never_becomes_false_success;

  procedure relative_cwd_is_rejected
    (reporter : in out Clair.Test.Reporter.Context)
  is
    loop_context : aliased Clair.Event_Loop.Context;
    operation    : aliased Sonbal.Process_Execution.Operation;
    callback     : aliased Completion;
    argv         : constant Sonbal.Process_Arguments.Arguments :=
      Sonbal_Test_Support.Process_Arguments ("/bin/echo", "sonbal");
    status       : Clair.Status.Code;
  begin
    status := Clair.Event_Loop.initialize (loop_context);
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK,
       "relative-cwd test Event Loop initializes");
    if status /= Clair.Status.OK then
      return;
    end if;

    status := Sonbal.Process_Execution.initialize (operation, loop_context);
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK,
       "relative-cwd process operation initializes");
    if status /= Clair.Status.OK then
      status := Clair.Event_Loop.finalize (loop_context);
      Sonbal_Test_Support.check
        (reporter,
         status = Clair.Status.OK,
         "relative-cwd setup failure releases Event Loop");
      return;
    end if;

    status := Sonbal.Process_Execution.start
      (self       => operation,
       argv       => argv,
       resolution => Clair.Process.Execution.Exact_Path,
       cwd        => "tmp",
       timeout_ms => 2_000,
       handler    => callback'unchecked_access);
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.INVALID_ARGUMENT and then
         not Sonbal.Process_Execution.is_active (operation) and then
         callback.call_count = 0,
       "relative cwd is rejected before process creation");

    status := Sonbal.Process_Execution.start
      (self       => operation,
       argv       => argv,
       resolution => Clair.Process.Execution.Exact_Path,
       cwd        => "/",
       timeout_ms => Sonbal.Process_Execution.MAXIMUM_OPERATION_TIMEOUT_MS + 1,
       handler    => callback'unchecked_access);
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.INVALID_ARGUMENT and then
         not Sonbal.Process_Execution.is_active (operation) and then
         callback.call_count = 0,
       "internal process timeout rejects one unit above its ceiling");

    status := Sonbal.Process_Execution.finalize (operation);
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK,
       "rejected process operation finalizes cleanly");
    status := Clair.Event_Loop.finalize (loop_context);
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK,
       "relative-cwd test Event Loop finalizes");
  end relative_cwd_is_rejected;

  procedure run (reporter : in out Clair.Test.Reporter.Context) is
  begin
    Clair.Test.Reporter.run_scenario
      (reporter,
       "asynchronous completion bridge",
       asynchronous_completion_bridge'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "cancellation settles before finalize",
       cancellation_settles_before_finalize'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "failure projection never becomes false success",
       failure_projection_never_becomes_false_success'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "relative cwd is rejected",
       relative_cwd_is_rejected'access);
  end run;

end Sonbal_Process_Execution_Tests;
