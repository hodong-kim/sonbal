-- ============================================================================
-- sonbal_clair_timer_churn_fixture.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Ada.Command_Line;
with Ada.Text_IO;
with Clair.Event_Loop;
with Clair.Status;
with Sonbal_Clair_Event_Loop_Fixture_Callbacks;

procedure Sonbal_Clair_Timer_Churn_Fixture is

  use type Clair.Status.Code;

  loop_context : aliased Clair.Event_Loop.Context;

  procedure wait_for_parent is
    acknowledgement : constant String := Ada.Text_IO.Get_Line;
    pragma Unreferenced (acknowledgement);
  begin
    null;
  end wait_for_parent;

  batches     : Positive;
  batch_size  : Positive;
  idle        : Clair.Event_Loop.Source_Handle := Clair.Event_Loop.NULL_SOURCE;
  status      : Clair.Status.Code := Clair.Status.OK;
  dispatched  : Boolean;
  initialized : Boolean := False;
  idle_owned  : Boolean := False;
  failed      : Boolean := False;
begin
  if Ada.Command_Line.Argument_Count /= 2 then
    Ada.Command_Line.Set_Exit_Status (64);
    return;
  end if;

  begin
    batches := Positive'Value (Ada.Command_Line.Argument (1));
    batch_size := Positive'Value (Ada.Command_Line.Argument (2));
  exception
    when Constraint_Error =>
      Ada.Command_Line.Set_Exit_Status (64);
      return;
  end;

  status := Clair.Event_Loop.initialize (loop_context);
  if status /= Clair.Status.OK then
    Ada.Command_Line.Set_Exit_Status (65);
    return;
  end if;
  initialized := True;

  status := Clair.Event_Loop.add_idle
    (self             => loop_context,
     callback         =>
  Sonbal_Clair_Event_Loop_Fixture_Callbacks.timer_churn_idle'access,
     callback_context => loop_context'address,
     source           => idle);
  if status /= Clair.Status.OK then
    failed := True;
  else
    idle_owned := True;
  end if;

  if not failed then
    Ada.Text_IO.Put_Line ("ready");
    Ada.Text_IO.Flush;
    wait_for_parent;

    for batch in 1 .. batches loop
      for iteration in 1 .. batch_size loop
        pragma Unreferenced (iteration);
        status := Clair.Event_Loop.iterate
          (self       => loop_context,
           timeout    => Clair.Event_Loop.IMMEDIATE,
           dispatched => dispatched);
        if status /= Clair.Status.OK or else not dispatched then
          failed := True;
          exit;
        end if;
      end loop;

      exit when failed;
      Ada.Text_IO.Put_Line (Positive'Image (batch));
      Ada.Text_IO.Flush;
      wait_for_parent;
    end loop;
  end if;

  if idle_owned then
    status := Clair.Event_Loop.remove (loop_context, idle);
    if status /= Clair.Status.OK then
      failed := True;
    end if;
  end if;

  if initialized then
    status := Clair.Event_Loop.finalize (loop_context);
    if status /= Clair.Status.OK then
      failed := True;
    end if;
  end if;

  Ada.Command_Line.Set_Exit_Status (if failed then 1 else 0);
exception
  when others =>
    Ada.Command_Line.Set_Exit_Status (1);
end Sonbal_Clair_Timer_Churn_Fixture;
