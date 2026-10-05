-- ============================================================================
-- sonbal_ada_protected_context_churn_fixture.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Ada.Command_Line;
with Ada.Text_IO;
with System;

procedure Sonbal_Ada_Protected_Context_Churn_Fixture is
  WARMUP_REQUESTS : constant Positive := 50;

  type Workload_Kind is (Plain_Eight, Protected_One, Protected_Eight);

  function parse_workload (text : String) return Workload_Kind is
  begin
    if text = "plain_eight" then
      return Plain_Eight;
    elsif text = "protected_one" then
      return Protected_One;
    elsif text = "protected_eight" then
      return Protected_Eight;
    end if;
    raise Constraint_Error with "unknown protected-context workload";
  end parse_workload;

  protected type Cancellation_State is
    procedure signal (cause : Natural);
    function reason return Natural;
  private
    current_reason : Natural := 0;
  end Cancellation_State;

  protected body Cancellation_State is
    procedure signal (cause : Natural) is
    begin
      current_reason := cause;
    end signal;

    function reason return Natural is
    begin
      return current_reason;
    end reason;
  end Cancellation_State;

  type Plain_Context is limited record
    request_value   : Natural := 0;
    role_value      : Natural := 1;
    cancellation    : Natural := 0;
    deferred_target : System.Address := System.Null_Address;
    defer_allowed   : Boolean := False;
  end record;

  type Protected_Context is limited record
    request_value   : Natural := 0;
    role_value      : Natural := 1;
    cancellation    : Cancellation_State;
    deferred_target : System.Address := System.Null_Address;
    defer_allowed   : Boolean := False;
  end record;

  workload   : Workload_Kind;
  batches    : Positive;
  batch_size : Positive;
  sequence   : Natural := 0;
  failed     : Boolean := False;

  procedure set_exit (success : Boolean) is
  begin
    Ada.Command_Line.Set_Exit_Status
      (if success then Ada.Command_Line.Success else Ada.Command_Line.Failure);
  end set_exit;

  procedure wait_for_parent is
    acknowledgement : constant String := Ada.Text_IO.Get_Line;
    pragma Unreferenced (acknowledgement);
  begin
    null;
  end wait_for_parent;

  procedure touch_plain is
  begin
    declare
      context : Plain_Context;
    begin
      context.request_value := sequence;
      context.cancellation := sequence;
      if context.request_value /= sequence or else
         context.cancellation /= sequence
      then
        failed := True;
      end if;
    end;
  end touch_plain;

  procedure touch_protected is
  begin
    declare
      context : Protected_Context;
    begin
      context.request_value := sequence;
      context.cancellation.signal (sequence);
      if context.request_value /= sequence or else
         context.cancellation.reason /= sequence
      then
        failed := True;
      end if;
    end;
  end touch_protected;

  procedure run_one is
    count : constant Positive :=
      (if workload = Protected_One then 1 else 8);
  begin
    sequence := sequence + 1;
    for index in 1 .. count loop
      pragma Unreferenced (index);
      if workload = Plain_Eight then
        touch_plain;
      else
        touch_protected;
      end if;
      exit when failed;
    end loop;
  end run_one;

  procedure run_many (count : Positive) is
  begin
    for iteration in 1 .. count loop
      pragma Unreferenced (iteration);
      run_one;
      exit when failed;
    end loop;
  end run_many;

begin
  if Ada.Command_Line.Argument_Count /= 3 then
    set_exit (False);
    return;
  end if;

  begin
    workload := parse_workload (Ada.Command_Line.Argument (1));
    batches := Positive'Value (Ada.Command_Line.Argument (2));
    batch_size := Positive'Value (Ada.Command_Line.Argument (3));
  exception
    when Constraint_Error =>
      set_exit (False);
      return;
  end;

  run_many (WARMUP_REQUESTS);
  if not failed then
    Ada.Text_IO.Put_Line ("ready");
    Ada.Text_IO.Flush;
    wait_for_parent;

    for batch in 1 .. batches loop
      run_many (batch_size);
      exit when failed;
      Ada.Text_IO.Put_Line (Positive'Image(batch));
      Ada.Text_IO.Flush;
      wait_for_parent;
    end loop;
  end if;

  set_exit (not failed);
exception
  when others =>
    set_exit (False);
end Sonbal_Ada_Protected_Context_Churn_Fixture;
