-- ============================================================================
-- sonbal_clair_watch_churn_fixture.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Ada.Command_Line;
with Ada.Text_IO;
with Clair.Event_Loop;
with Clair.IO;
with Clair.Status;
with Sonbal_Clair_Event_Loop_Fixture_Callbacks;
with System;

procedure Sonbal_Clair_Watch_Churn_Fixture is

  use type Clair.Event_Loop.Event_Mask;
  use type Clair.Status.Code;

  type Workload_Kind is (Modify_Watch, Remove_Add_Watch);

  function parse_workload (text : String) return Workload_Kind is
  begin
    if text = "modify_watch" then
      return Modify_Watch;
    elsif text = "remove_add_watch" then
      return Remove_Add_Watch;
    end if;
    raise Constraint_Error with "unknown watch-churn workload";
  end parse_workload;

  WATCH_FD : constant Clair.IO.Descriptor := Clair.IO.Descriptor (3);

  loop_context  : aliased Clair.Event_Loop.Context;
  watch : Clair.Event_Loop.Source_Handle
        := Clair.Event_Loop.NULL_SOURCE;
  workload      : Workload_Kind;
  batches       : Positive;
  batch_size    : Positive;
  status        : Clair.Status.Code := Clair.Status.OK;
  initialized   : Boolean := False;
  watch_owned   : Boolean := False;
  failed        : Boolean := False;

  procedure wait_for_parent is
    acknowledgement : constant String := Ada.Text_IO.Get_Line;
    pragma Unreferenced (acknowledgement);
  begin
    null;
  end wait_for_parent;

  procedure add_input_watch is
  begin
    status := Clair.Event_Loop.add_watch
      (self    => loop_context,
       fd      => WATCH_FD,
       events           => Clair.Event_Loop.EVENT_INPUT,
       callback         =>
  Sonbal_Clair_Event_Loop_Fixture_Callbacks.failing_io'access,
       callback_context => System.Null_Address,
       source           => watch);
    if status /= Clair.Status.OK then
      failed := True;
    else
      watch_owned := True;
    end if;
  end add_input_watch;

  procedure run_one is
  begin
    case workload is
      when Modify_Watch =>
        status := Clair.Event_Loop.modify_watch
          (self   => loop_context,
           watch  => watch,
           events =>
             Clair.Event_Loop.EVENT_INPUT or Clair.Event_Loop.EVENT_OUTPUT);
        if status /= Clair.Status.OK then
          failed := True;
          return;
        end if;

        status := Clair.Event_Loop.modify_watch
          (self   => loop_context,
           watch  => watch,
           events => Clair.Event_Loop.EVENT_INPUT);
        if status /= Clair.Status.OK then
          failed := True;
        end if;

      when Remove_Add_Watch =>
        status := Clair.Event_Loop.remove (loop_context, watch);
        if status /= Clair.Status.OK then
          failed := True;
          return;
        end if;
        watch_owned := False;
        add_input_watch;
    end case;
  end run_one;

begin
  if Ada.Command_Line.Argument_Count /= 3 then
    Ada.Command_Line.Set_Exit_Status (64);
    return;
  end if;

  begin
    workload := parse_workload (Ada.Command_Line.Argument (1));
    batches := Positive'Value (Ada.Command_Line.Argument (2));
    batch_size := Positive'Value (Ada.Command_Line.Argument (3));
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

  add_input_watch;

  if not failed then
    Ada.Text_IO.Put_Line ("ready");
    Ada.Text_IO.Flush;
    wait_for_parent;

    for batch in 1 .. batches loop
      for iteration in 1 .. batch_size loop
        pragma Unreferenced (iteration);
        run_one;
        exit when failed;
      end loop;

      exit when failed;
      Ada.Text_IO.Put_Line (Positive'Image (batch));
      Ada.Text_IO.Flush;
      wait_for_parent;
    end loop;
  end if;

  if watch_owned then
    status := Clair.Event_Loop.remove (loop_context, watch);
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
end Sonbal_Clair_Watch_Churn_Fixture;
