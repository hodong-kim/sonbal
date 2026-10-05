-- ============================================================================
-- sonbal_clair_event_loop_fixture_callbacks.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Ada.Unchecked_Conversion;

package body Sonbal_Clair_Event_Loop_Fixture_Callbacks is

  use type Clair.Event_Loop.Context_Access;
  use type Clair.Status.Code;

  function address_to_loop is new Ada.Unchecked_Conversion
    (System.Address, Clair.Event_Loop.Context_Access);

  function failing_io
    (source           : access constant Clair.Event_Loop.Source_Handle;
     fd               : Clair.IO.Descriptor;
     events           : Clair.Event_Loop.Event_Mask;
     callback_context : System.Address)
  return Clair.Status.Code
  is
    pragma Unreferenced (source, fd, events, callback_context);
  begin
    return Clair.Status.CALLBACK_FAILED;
  end failing_io;

  function failing_timer
    (source           : access constant Clair.Event_Loop.Source_Handle;
     callback_context : System.Address)
  return Clair.Status.Code
  is
    pragma Unreferenced (source, callback_context);
  begin
    return Clair.Status.CALLBACK_FAILED;
  end failing_timer;

  function timer_churn_idle
    (source           : access constant Clair.Event_Loop.Source_Handle;
     callback_context : System.Address)
  return Clair.Status.Code
  is
    pragma Unreferenced (source);
    owner  : constant Clair.Event_Loop.Context_Access :=
      address_to_loop (callback_context);
    timer  : Clair.Event_Loop.Source_Handle := Clair.Event_Loop.NULL_SOURCE;
    status : Clair.Status.Code;
  begin
    if owner = null then
      return Clair.Status.INVALID_STATE;
    end if;

    status := Clair.Event_Loop.add_timer
      (self             => owner.all,
       interval         => 60_000,
       callback         => failing_timer'access,
       callback_context => System.Null_Address,
       source           => timer);
    if status /= Clair.Status.OK then
      return status;
    end if;

    return Clair.Event_Loop.remove (owner.all, timer);
  end timer_churn_idle;

end Sonbal_Clair_Event_Loop_Fixture_Callbacks;
