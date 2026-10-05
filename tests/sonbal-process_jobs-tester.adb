-- ============================================================================
-- sonbal-process_jobs-tester.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

package body Sonbal.Process_Jobs.Tester is

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
      when Trace_Start_Request =>
        return "start_request";
      when Trace_Launch_Accepted =>
        return "launch_accepted";
      when Trace_Start_Response =>
        return "start_result";
      when Trace_Start_Response_Ready =>
        return "start_response_ready";
      when Trace_Poll_Request =>
        return "poll_request";
      when Trace_Poll_Response =>
        return "poll_result";
      when Trace_Poll_Response_Ready =>
        return "poll_response_ready";
      when Trace_Terminal_Observed =>
        return "terminal_observed";
      when Trace_Cancellation_Settled =>
        return "cancellation_settled";
      when Trace_Terminal_Published =>
        return "terminal_published";
      when Trace_Terminal_Evicted =>
        return "terminal_evicted";
      when Trace_Cancel_Request =>
        return "cancel_request";
      when Trace_Cancel_Response =>
        return "cancel_result";
      when Trace_Cancel_Response_Ready =>
        return "cancel_response_ready";
    end case;
  end trace_event_kind;

  function trace_event_outcome
    (self     : Context;
     position : Positive) return String
  is
  begin
    case self.trace_events(physical_index (self, position)).outcome is
      when Trace_None =>
        return "none";
      when Trace_Running =>
        return "running";
      when Trace_Terminal =>
        return "terminal";
      when Trace_Execution_Busy =>
        return "execution_busy";
      when Trace_Stale_Workspace_Token =>
        return "stale_workspace_token";
      when Trace_Outside_Workspace =>
        return "outside_workspace";
      when Trace_Expired =>
        return "expired";
      when Trace_Stale_Instance =>
        return "stale_instance";
      when Trace_Not_Found =>
        return "not_found";
      when Trace_Invalid_Cursor =>
        return "invalid_cursor";
      when Trace_Cancelling =>
        return "cancelling";
      when Trace_Already_Terminal =>
        return "already_terminal";
      when Trace_Exited =>
        return "exited";
      when Trace_Signaled =>
        return "signaled";
      when Trace_Timed_Out =>
        return "timed_out";
      when Trace_Launch_Failed =>
        return "launch_failed";
      when Trace_Cancelled =>
        return "cancelled";
      when Trace_Execution_Failed =>
        return "execution_failed";
    end case;
  end trace_event_outcome;

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

end Sonbal.Process_Jobs.Tester;
