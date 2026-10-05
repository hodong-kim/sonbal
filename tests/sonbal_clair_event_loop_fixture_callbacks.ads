-- ============================================================================
-- sonbal_clair_event_loop_fixture_callbacks.ads
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Clair.Event_Loop;
with Clair.IO;
with Clair.Status;
with System;

package Sonbal_Clair_Event_Loop_Fixture_Callbacks is

  function failing_io
    (source           : access constant Clair.Event_Loop.Source_Handle;
     fd               : Clair.IO.Descriptor;
     events           : Clair.Event_Loop.Event_Mask;
     callback_context : System.Address)
  return Clair.Status.Code
  with Convention => C;

  function failing_timer
    (source           : access constant Clair.Event_Loop.Source_Handle;
     callback_context : System.Address)
  return Clair.Status.Code
  with Convention => C;

  function timer_churn_idle
    (source           : access constant Clair.Event_Loop.Source_Handle;
     callback_context : System.Address)
  return Clair.Status.Code
  with Convention => C;

end Sonbal_Clair_Event_Loop_Fixture_Callbacks;
