-- ============================================================================
-- sonbal-mcp-request_core.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Ada.Strings;
with Ada.Strings.Fixed;
with Clair.Log;
with Sonbal.Process_Jobs;
with Sonbal.Workspace_Tokens;

package body Sonbal.MCP.Request_Core is

  use type Ada.Real_Time.Time;
  use type Clair.Status.Code;
  use type Interfaces.Unsigned_64;
  use type Sonbal.MCP.Dispatcher.Action_Kind;
  use type Sonbal.Process_Execution.Workspace_Start_State;

  function compact_image (value : Interfaces.Unsigned_64) return String is
    (Ada.Strings.Fixed.Trim
       (Interfaces.Unsigned_64'image (value), Ada.Strings.Both));

  function trace_kind_image (value : Trace_Event_Kind) return String is
  begin
    case value is
      when Trace_Request_Admitted =>
        return "request_admitted";
      when Trace_Run_Execution_Started =>
        return "run_execution_started";
      when Trace_Run_Execution_Completed =>
        return "run_execution_completed";
      when Trace_Read_Execution_Started =>
        return "read_execution_started";
      when Trace_Read_Execution_Completed =>
        return "read_execution_completed";
      when Trace_Response_Ready =>
        return "response_ready";
      when Trace_Transport_Response_Handoff =>
        return "transport_response_handoff";
      when Trace_Transport_Response_Abandoned =>
        return "transport_response_abandoned";
    end case;
  end trace_kind_image;

  function trace_action_image
    (value : Sonbal.MCP.Dispatcher.Action_Kind) return String
  is
  begin
    case value is
      when Sonbal.MCP.Dispatcher.Invoke_Ping =>
        return "ping";
      when Sonbal.MCP.Dispatcher.Invoke_Rotate_Workspace_Token =>
        return "rotate_workspace_token";
      when Sonbal.MCP.Dispatcher.Invoke_Read_File =>
        return "read_file";
      when Sonbal.MCP.Dispatcher.Invoke_Run_Process =>
        return "run_process";
      when Sonbal.MCP.Dispatcher.Invoke_Start_Process =>
        return "start_process";
      when Sonbal.MCP.Dispatcher.Invoke_Poll_Process =>
        return "poll_process";
      when Sonbal.MCP.Dispatcher.Invoke_Cancel_Process =>
        return "cancel_process";
      when others =>
        return "none";
    end case;
  end trace_action_image;

  function action_is_traceable
    (value : Sonbal.MCP.Dispatcher.Action_Kind) return Boolean
  is
    (value in
       Sonbal.MCP.Dispatcher.Invoke_Ping |
       Sonbal.MCP.Dispatcher.Invoke_Rotate_Workspace_Token |
       Sonbal.MCP.Dispatcher.Invoke_Read_File |
       Sonbal.MCP.Dispatcher.Invoke_Run_Process |
       Sonbal.MCP.Dispatcher.Invoke_Start_Process |
       Sonbal.MCP.Dispatcher.Invoke_Poll_Process |
       Sonbal.MCP.Dispatcher.Invoke_Cancel_Process);

  procedure clear_trace (self : in out Context) is
  begin
    self.trace_events := [others => <>];
    self.trace_count := 0;
    self.trace_next_index := 1;
    self.trace_overwrite_count := 0;
    self.trace_next_ordinal := 1;
    self.trace_next_correlation := 1;
    self.trace_epoch := Ada.Real_Time.Time_First;
    self.trace_enabled := False;
    self.trace_log_enabled := False;
  end clear_trace;

  procedure configure_trace
    (self        : in out Context;
     enabled     : Boolean;
     log_enabled : Boolean)
  is
  begin
    clear_trace (self);
    if not enabled then
      return;
    end if;

    begin
      self.trace_epoch := Ada.Real_Time.Clock;
      self.trace_enabled := True;
      self.trace_log_enabled := log_enabled;
    exception
      when others =>
        clear_trace (self);
    end;
  end configure_trace;

  function allocate_trace_correlation
    (self : in out Context) return Interfaces.Unsigned_64
  is
    result : Interfaces.Unsigned_64;
  begin
    if not self.trace_enabled or else self.trace_next_correlation = 0 then
      return 0;
    end if;

    result := self.trace_next_correlation;
    if self.trace_next_correlation = Interfaces.Unsigned_64'Last then
      self.trace_next_correlation := 0;
    else
      self.trace_next_correlation := self.trace_next_correlation + 1;
    end if;
    return result;
  exception
    when others =>
      return 0;
  end allocate_trace_correlation;

  procedure record_trace
    (self        : in out Context;
     kind        : Trace_Event_Kind;
     action      : Sonbal.MCP.Dispatcher.Action_Kind;
     correlation : Interfaces.Unsigned_64)
  is
    now     : Ada.Real_Time.Time;
    ordinal : Interfaces.Unsigned_64;
  begin
    if not self.trace_enabled or else self.trace_next_ordinal = 0 then
      return;
    end if;

    now := Ada.Real_Time.Clock;
    ordinal := self.trace_next_ordinal;
    if self.trace_next_ordinal = Interfaces.Unsigned_64'Last then
      self.trace_next_ordinal := 0;
    else
      self.trace_next_ordinal := self.trace_next_ordinal + 1;
    end if;

    self.trace_events(self.trace_next_index) :=
      (ordinal     => ordinal,
       correlation => correlation,
       action      => action,
       kind        => kind,
       time_value  => now);

    if self.trace_count < MAXIMUM_TRACE_EVENTS then
      self.trace_count := self.trace_count + 1;
    elsif self.trace_overwrite_count < Interfaces.Unsigned_64'Last then
      self.trace_overwrite_count := self.trace_overwrite_count + 1;
    end if;

    if self.trace_next_index = MAXIMUM_TRACE_EVENTS then
      self.trace_next_index := 1;
    else
      self.trace_next_index := self.trace_next_index + 1;
    end if;

    if self.trace_log_enabled then
      declare
        elapsed : constant Duration :=
          (if self.trace_epoch = Ada.Real_Time.Time_First or else
              now < self.trace_epoch
           then 0.0
           else Ada.Real_Time.To_Duration (now - self.trace_epoch));
      begin
        Clair.Log.write
          (severity => Clair.Log.Info,
           message  =>
             "sonbal: trace scope=request event=" &
             trace_kind_image (kind) &
             " tool=" & trace_action_image (action) &
             " ordinal=" & compact_image (ordinal) &
             " correlation=" & compact_image (correlation) &
             " monotonic_s=" &
               Ada.Strings.Fixed.Trim
                 (Duration'image (elapsed), Ada.Strings.Both),
           destinations => Clair.Log.Native_Diagnostic);
      exception
        when others =>
          null;
      end;
    end if;
  exception
    when others =>
      null;
  end record_trace;

  procedure begin_request_trace
    (self   : in out Context;
     result : in out Sonbal.MCP.Dispatcher.Dispatch_Result)
  is
  begin
    if not self.trace_enabled or else
       not action_is_traceable (result.action)
    then
      return;
    end if;

    result.diagnostic_action := result.action;
    result.diagnostic_correlation := allocate_trace_correlation (self);
    record_trace
      (self,
       Trace_Request_Admitted,
       result.diagnostic_action,
       result.diagnostic_correlation);
  end begin_request_trace;

  procedure mark_response_ready
    (self   : in out Context;
     result : Sonbal.MCP.Dispatcher.Dispatch_Result)
  is
  begin
    if result.diagnostic_correlation = 0 then
      return;
    end if;

    record_trace
      (self,
       Trace_Response_Ready,
       result.diagnostic_action,
       result.diagnostic_correlation);
  end mark_response_ready;

  procedure write_diagnostic (message : String) is
  begin
    Clair.Log.write
      (severity     => Clair.Log.Error,
       message      => message,
       destinations => Clair.Log.Native_Diagnostic);
  exception
    when others =>
      null;
  end write_diagnostic;

  function native_resolution
    (value : Sonbal.MCP.Dispatcher.Run_Process_Resolution)
  return Clair.Process.Execution.Executable_Resolution
  is
    (case value is
       when Sonbal.MCP.Dispatcher.Exact_Path =>
         Clair.Process.Execution.Exact_Path,
       when Sonbal.MCP.Dispatcher.Search_Path =>
         Clair.Process.Execution.Search_Path);

  function initialize
    (self           : in out Context;
     event_loop     : aliased in out Clair.Event_Loop.Context;
     max_work_slots : Sonbal.Configuration.Work_Slot_Count)
  return Clair.Status.Code
  is
    status : Clair.Status.Code;
    trace_requested : constant Boolean :=
      Sonbal.Configuration.diagnostic_trace_enabled;
  begin
    if self.initialized then
      return Clair.Status.INVALID_STATE;
    end if;

    configure_trace (self, trace_requested, trace_requested);
    status := Sonbal.Process_Runtime.initialize
      (self.runtime, event_loop, max_work_slots);
    if status /= Clair.Status.OK then
      clear_trace (self);
      return status;
    end if;

    self.initialized := True;
    return Clair.Status.OK;
  end initialize;

  function is_initialized (self : Context) return Boolean is
    (self.initialized);

  function is_idle (self : Context) return Boolean is
    (self.initialized and then Sonbal.Process_Runtime.is_idle(self.runtime));

  function active_execution_count (self : Context) return Natural is
  begin
    if not self.initialized then
      return 0;
    end if;
    return Sonbal.Process_Runtime.active_execution_count(self.runtime);
  end active_execution_count;

  procedure handle
    (self   : in out Context;
     input  : String;
     result : out Sonbal.MCP.Dispatcher.Dispatch_Result)
  is
  begin
    if not self.initialized then
      result.action := Sonbal.MCP.Dispatcher.Fatal_Error;
      return;
    end if;
    Sonbal.MCP.Dispatcher.handle(self.dispatcher, input, result);
    begin_request_trace (self, result);
  end handle;

  procedure handle_parsed
    (self    : in out Context;
     message : Sonbal.MCP.JSON.Message;
     status  : Sonbal.MCP.JSON.Parse_Status;
     result  : out Sonbal.MCP.Dispatcher.Dispatch_Result)
  is
  begin
    if not self.initialized then
      result.action := Sonbal.MCP.Dispatcher.Fatal_Error;
      return;
    end if;
    Sonbal.MCP.Dispatcher.handle_parsed
      (self.dispatcher, message, status, result);
    begin_request_trace (self, result);
  end handle_parsed;

  function process_result
    (self            : in out Context;
     result          : in out Sonbal.MCP.Dispatcher.Dispatch_Result;
     process         : aliased in out Sonbal.Process_Execution.Operation;
     process_handler : Sonbal.Process_Execution.Completion_Handler_Access)
  return Boolean
  is
    status       : Clair.Status.Code := Clair.Status.OK;
    rotation      : Sonbal.Workspace_Tokens.Rotation_Result;
    start_state   : Sonbal.Process_Execution.Workspace_Start_State;
    start_result : Sonbal.Process_Jobs.Start_Result;
    poll_result  : Sonbal.Process_Jobs.Poll_Result;
    cancel_result : Sonbal.Process_Jobs.Cancel_Result;
  begin
    if not self.initialized then
      return False;
    end if;

    case result.action is
      when Sonbal.MCP.Dispatcher.Invoke_Ping =>
        Sonbal.MCP.Dispatcher.complete_ping(self.dispatcher, result);
        mark_response_ready (self, result);

      when Sonbal.MCP.Dispatcher.Invoke_Rotate_Workspace_Token =>
        status := Sonbal.Process_Runtime.rotate_workspace_token
          (self.runtime,
           Sonbal.MCP.JSON.image (result.rotate_workspace_token.root),
           Sonbal.MCP.JSON.image
             (result.rotate_workspace_token.operation_id),
           rotation);
        Sonbal.MCP.Dispatcher.complete_rotate_workspace_token
          (self.dispatcher, result, status, rotation);
        mark_response_ready (self, result);

      when Sonbal.MCP.Dispatcher.Invoke_Read_File =>
        status := Sonbal.Process_Runtime.start_file_read
          (self              => self.runtime,
           operation         => process,
           workspace_token   =>
             Sonbal.MCP.JSON.image (result.read_file.workspace_token),
           path              => Sonbal.MCP.JSON.image (result.read_file.path),
           offset            => result.read_file.offset,
           maximum_bytes     => result.read_file.maximum_bytes,
           expected_revision =>
             Sonbal.MCP.JSON.image (result.read_file.expected_revision),
           handler           => process_handler,
           state             => start_state);

        if Sonbal.Process_Execution.is_active (process) then
          if status /= Clair.Status.OK then
            write_diagnostic
              ("sonbal: workspace read start integration failure");
            return False;
          end if;
          record_trace
            (self,
             Trace_Read_Execution_Started,
             result.diagnostic_action,
             result.diagnostic_correlation);
          return True;
        end if;

        case start_state is
          when Sonbal.Process_Execution.Workspace_Start_Execution_Busy =>
            Sonbal.MCP.Dispatcher.complete_read_file_execution_busy
              (self.dispatcher, result);
          when Sonbal.Process_Execution.Workspace_Start_Stale_Token =>
            Sonbal.MCP.Dispatcher.complete_read_file_stale_workspace_token
              (self.dispatcher, result);
          when Sonbal.Process_Execution.Workspace_Start_Outside_Workspace =>
            write_diagnostic ("sonbal: read helper reported cwd containment");
            return False;
          when Sonbal.Process_Execution.Workspace_Start_Failed =>
            if status = Clair.Status.OK then
              write_diagnostic ("sonbal: workspace read start state failure");
              return False;
            end if;
            declare
              outcome : constant Clair.Process.Execution.Result :=
                Clair.Process.Execution.empty_result;
            begin
              Sonbal.MCP.Dispatcher.complete_read_file
                (self.dispatcher, result, status, outcome);
            end;
          when Sonbal.Process_Execution.Workspace_Start_Running =>
            write_diagnostic ("sonbal: workspace read lost active state");
            return False;
        end case;
        mark_response_ready (self, result);

      when Sonbal.MCP.Dispatcher.Invoke_Run_Process =>
        status := Sonbal.Process_Runtime.start_synchronous
          (self       => self.runtime,
           operation  => process,
           workspace_token =>
             Sonbal.MCP.JSON.image (result.run_process.workspace_token),
           argv       => result.run_process.argv,
           resolution => native_resolution(result.run_process.resolution),
           cwd        => Sonbal.MCP.JSON.image(result.run_process.cwd),
           timeout_ms => result.run_process.timeout_ms,
           handler    => process_handler,
           state      => start_state);

        if Sonbal.Process_Execution.is_active(process) then
          if status /= Clair.Status.OK then
            write_diagnostic
              ("sonbal: workspace process start integration failure");
            return False;
          end if;
          record_trace
            (self,
             Trace_Run_Execution_Started,
             result.diagnostic_action,
             result.diagnostic_correlation);
          return True;
        end if;

        case start_state is
          when Sonbal.Process_Execution.Workspace_Start_Execution_Busy =>
            Sonbal.MCP.Dispatcher.complete_run_process_execution_busy
              (self.dispatcher, result);
          when Sonbal.Process_Execution.Workspace_Start_Stale_Token =>
            Sonbal.MCP.Dispatcher.complete_run_process_stale_workspace_token
              (self.dispatcher, result);
          when Sonbal.Process_Execution.Workspace_Start_Outside_Workspace =>
            Sonbal.MCP.Dispatcher.complete_run_process_outside_workspace
              (self.dispatcher, result);
          when Sonbal.Process_Execution.Workspace_Start_Failed =>
            if status = Clair.Status.OK then
              write_diagnostic ("sonbal: workspace process start state failure");
              return False;
            end if;
            declare
              outcome : constant Clair.Process.Execution.Result :=
                Clair.Process.Execution.empty_result;
            begin
              Sonbal.MCP.Dispatcher.complete_run_process
                (self.dispatcher, result, status, outcome);
            end;
          when Sonbal.Process_Execution.Workspace_Start_Running =>
            write_diagnostic ("sonbal: workspace process lost active state");
            return False;
        end case;
        mark_response_ready (self, result);

      when Sonbal.MCP.Dispatcher.Invoke_Start_Process =>
        Sonbal.Process_Runtime.start_job
          (self.runtime,
           Sonbal.MCP.JSON.image
             (result.start_process.workspace_token),
           result.start_process.argv,
           native_resolution(result.start_process.resolution),
           Sonbal.MCP.JSON.image(result.start_process.cwd),
           result.start_process.timeout_ms,
           start_result);
        Sonbal.MCP.Dispatcher.complete_start_process
          (self.dispatcher, result, start_result);
        Sonbal.Process_Runtime.mark_start_job_response_ready
          (self.runtime, start_result);
        mark_response_ready (self, result);

      when Sonbal.MCP.Dispatcher.Invoke_Poll_Process =>
        Sonbal.Process_Runtime.poll_job
          (self.runtime,
           Sonbal.MCP.JSON.image(result.poll_process.job_id),
           Sonbal.MCP.JSON.image(result.poll_process.cursor),
           poll_result);
        Sonbal.MCP.Dispatcher.complete_poll_process
          (self.dispatcher, result, poll_result);
        Sonbal.Process_Runtime.mark_poll_job_response_ready
          (self.runtime, poll_result);
        mark_response_ready (self, result);

      when Sonbal.MCP.Dispatcher.Invoke_Cancel_Process =>
        Sonbal.Process_Runtime.cancel_job
          (self.runtime,
           Sonbal.MCP.JSON.image(result.cancel_process.job_id),
           cancel_result);
        Sonbal.MCP.Dispatcher.complete_cancel_process
          (self.dispatcher, result, cancel_result);
        Sonbal.Process_Runtime.mark_cancel_job_response_ready
          (self.runtime, cancel_result);
        mark_response_ready (self, result);

      when Sonbal.MCP.Dispatcher.No_Action |
           Sonbal.MCP.Dispatcher.Write_Response =>
        null;

      when Sonbal.MCP.Dispatcher.Fatal_Error =>
        return False;
    end case;

    return result.action in Sonbal.MCP.Dispatcher.No_Action |
      Sonbal.MCP.Dispatcher.Write_Response;
  exception
    when others =>
      write_diagnostic("sonbal: request-core processing failure");
      return False;
  end process_result;

  procedure complete_request_execution
    (self    : in out Context;
     result  : in out Sonbal.MCP.Dispatcher.Dispatch_Result;
     status  : Clair.Status.Code;
     outcome : Clair.Process.Execution.Result)
  is
  begin
    case result.action is
      when Sonbal.MCP.Dispatcher.Invoke_Run_Process =>
        record_trace
          (self,
           Trace_Run_Execution_Completed,
           result.diagnostic_action,
           result.diagnostic_correlation);
        Sonbal.MCP.Dispatcher.complete_run_process
          (self.dispatcher, result, status, outcome);

      when Sonbal.MCP.Dispatcher.Invoke_Read_File =>
        record_trace
          (self,
           Trace_Read_Execution_Completed,
           result.diagnostic_action,
           result.diagnostic_correlation);
        Sonbal.MCP.Dispatcher.complete_read_file
          (self.dispatcher, result, status, outcome);

      when others =>
        write_diagnostic ("sonbal: unexpected request execution completion");
        return;
    end case;

    mark_response_ready (self, result);
  end complete_request_execution;

  procedure complete_run_process
    (self    : in out Context;
     result  : in out Sonbal.MCP.Dispatcher.Dispatch_Result;
     status  : Clair.Status.Code;
     outcome : Clair.Process.Execution.Result)
  is
  begin
    if result.action /= Sonbal.MCP.Dispatcher.Invoke_Run_Process then
      write_diagnostic ("sonbal: non-run completion on run-only boundary");
      return;
    end if;
    complete_request_execution (self, result, status, outcome);
  end complete_run_process;

  procedure complete_run_process_execution_busy
    (self   : in out Context;
     result : in out Sonbal.MCP.Dispatcher.Dispatch_Result)
  is
  begin
    Sonbal.MCP.Dispatcher.complete_run_process_execution_busy
      (self.dispatcher, result);
    mark_response_ready (self, result);
  end complete_run_process_execution_busy;

  procedure mark_transport_response_handoff
    (self   : in out Context;
     result : Sonbal.MCP.Dispatcher.Dispatch_Result)
  is
  begin
    if result.diagnostic_correlation = 0 then
      return;
    end if;

    record_trace
      (self,
       Trace_Transport_Response_Handoff,
       result.diagnostic_action,
       result.diagnostic_correlation);
  end mark_transport_response_handoff;

  procedure mark_transport_response_abandoned
    (self   : in out Context;
     result : Sonbal.MCP.Dispatcher.Dispatch_Result)
  is
  begin
    if result.diagnostic_correlation = 0 then
      return;
    end if;

    record_trace
      (self,
       Trace_Transport_Response_Abandoned,
       result.diagnostic_action,
       result.diagnostic_correlation);
  end mark_transport_response_abandoned;

  function stop (self : in out Context) return Boolean is
    status : Clair.Status.Code := Clair.Status.OK;
  begin
    Sonbal.MCP.Dispatcher.stop(self.dispatcher);
    if self.initialized then
      status := Sonbal.Process_Runtime.begin_shutdown(self.runtime);
    end if;
    return status = Clair.Status.OK;
  exception
    when others =>
      return False;
  end stop;

  function finalize
    (self : in out Context) return Clair.Status.Code
  is
    status : Clair.Status.Code;
  begin
    if not self.initialized then
      return Clair.Status.INVALID_STATE;
    end if;

    status := Sonbal.Process_Runtime.finalize(self.runtime);
    if status /= Clair.Status.OK then
      return status;
    end if;
    clear_trace (self);
    self.initialized := False;
    return Clair.Status.OK;
  end finalize;

end Sonbal.MCP.Request_Core;
