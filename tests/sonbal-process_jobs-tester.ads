-- ============================================================================
-- sonbal-process_jobs-tester.ads
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Ada.Real_Time;
with Interfaces;

package Sonbal.Process_Jobs.Tester is

  procedure enable_trace (self : in out Context);

  function trace_capacity return Positive;
  function trace_event_count (self : Context) return Natural;
  function trace_overwrite_count
    (self : Context) return Interfaces.Unsigned_64;

  function trace_event_kind
    (self     : Context;
     position : Positive) return String;

  function trace_event_outcome
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

end Sonbal.Process_Jobs.Tester;
