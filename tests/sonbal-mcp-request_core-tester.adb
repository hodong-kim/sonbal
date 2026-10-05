-- ============================================================================
-- sonbal-mcp-request_core-tester.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Clair.Status;
with Sonbal.Process_Runtime;
with Sonbal.Workspace_Tokens;

package body Sonbal.MCP.Request_Core.Tester is

  use type Clair.Status.Code;
  use type Sonbal.Workspace_Tokens.Rotation_State;

  procedure enable_trace (self : in out Context) is
  begin
    self.trace_events := [others => <>];
    self.trace_count := 0;
    self.trace_next_index := 1;
    self.trace_overwrite_count := 0;
    self.trace_next_ordinal := 1;
    self.trace_next_correlation := 1;
    self.trace_epoch := Ada.Real_Time.Clock;
    self.trace_enabled := True;
    self.trace_log_enabled := False;
  end enable_trace;

  function trace_capacity return Positive is
    (MAXIMUM_TRACE_EVENTS);

  function trace_event_count (self : Context) return Natural is
    (self.trace_count);

  function trace_overwrite_count
    (self : Context) return Interfaces.Unsigned_64
  is
    (self.trace_overwrite_count);

  function physical_index
    (self     : Context;
     position : Positive) return Positive
  is
  begin
    if position > self.trace_count then
      raise Constraint_Error with "trace position is outside retained events";
    elsif self.trace_count < MAXIMUM_TRACE_EVENTS then
      return position;
    end if;

    return
      ((self.trace_next_index - 1 + position - 1) mod MAXIMUM_TRACE_EVENTS) + 1;
  end physical_index;

  function trace_event_kind
    (self     : Context;
     position : Positive) return String
  is
  begin
    case self.trace_events(physical_index (self, position)).kind is
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
  end trace_event_kind;

  function trace_event_action
    (self     : Context;
     position : Positive) return String
  is
  begin
    case self.trace_events(physical_index (self, position)).action is
      when Sonbal.MCP.Dispatcher.Invoke_Ping =>
        return "ping";
      when Sonbal.MCP.Dispatcher.Invoke_Rotate_Workspace_Token =>
        return "rotate_workspace_token";
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
  end trace_event_action;

  function trace_event_correlation
    (self     : Context;
     position : Positive) return Interfaces.Unsigned_64
  is
    (self.trace_events(physical_index (self, position)).correlation);

  function trace_event_ordinal
    (self     : Context;
     position : Positive) return Interfaces.Unsigned_64
  is
    (self.trace_events(physical_index (self, position)).ordinal);

  function trace_event_time
    (self     : Context;
     position : Positive) return Ada.Real_Time.Time
  is
    (self.trace_events(physical_index (self, position)).time_value);

  function rotate_workspace_token
    (self : in out Context;
     root : String) return String
  is
    prepared  : Sonbal.Workspace_Tokens.Rotation_Result;
    committed : Sonbal.Workspace_Tokens.Rotation_Result;
    status    : Clair.Status.Code;
  begin
    status := Sonbal.Process_Runtime.rotate_workspace_token
      (self.runtime, root, "", prepared);
    if status /= Clair.Status.OK or else
       prepared.state /= Sonbal.Workspace_Tokens.Rotation_Prepared
    then
      raise Program_Error with "failed to prepare workspace-token rotation";
    end if;

    status := Sonbal.Process_Runtime.rotate_workspace_token
      (self.runtime,
       root,
       Sonbal.Workspace_Tokens.image (prepared.operation_id),
       committed);
    if status /= Clair.Status.OK or else
       committed.state /= Sonbal.Workspace_Tokens.Rotation_Rotated
    then
      raise Program_Error with "failed to commit workspace-token rotation";
    end if;

    return Sonbal.Workspace_Tokens.image (committed.token);
  end rotate_workspace_token;

end Sonbal.MCP.Request_Core.Tester;
