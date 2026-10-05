-- ============================================================================
-- sonbal-mcp-request_core-tester.ads
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Ada.Real_Time;
with Interfaces;

package Sonbal.MCP.Request_Core.Tester is

  procedure enable_trace (self : in out Context);

  function trace_capacity return Positive;
  function trace_event_count (self : Context) return Natural;
  function trace_overwrite_count
    (self : Context) return Interfaces.Unsigned_64;

  function trace_event_kind
    (self     : Context;
     position : Positive) return String;

  function trace_event_action
    (self     : Context;
     position : Positive) return String;

  function trace_event_correlation
    (self     : Context;
     position : Positive) return Interfaces.Unsigned_64;

  function trace_event_ordinal
    (self     : Context;
     position : Positive) return Interfaces.Unsigned_64;

  function trace_event_time
    (self     : Context;
     position : Positive) return Ada.Real_Time.Time;

  function rotate_workspace_token
    (self : in out Context;
     root : String) return String;

end Sonbal.MCP.Request_Core.Tester;
