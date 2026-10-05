-- ============================================================================
-- sonbal_diagnostics_tests.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Clair.Event_Loop;
with Clair.Status;
with Interfaces;
with Sonbal.Configuration;
with Sonbal.Diagnostics;
with Sonbal.Process_Runtime;
with Sonbal_Test_Support;

package body Sonbal_Diagnostics_Tests is

  use type Clair.Status.Code;
  use type Interfaces.Unsigned_64;
  use type Sonbal.Diagnostics.Observation_State;

  procedure memory_observation_is_available
    (reporter : in out Clair.Test.Reporter.Context)
  is
    snapshot : constant Sonbal.Diagnostics.Memory_Snapshot :=
      Sonbal.Diagnostics.observe_memory;
  begin
    Sonbal_Test_Support.check
      (reporter,
       snapshot.state = Sonbal.Diagnostics.Observation_Available and then
         snapshot.resident_bytes > 0 and then
         snapshot.virtual_bytes >= snapshot.resident_bytes,
       "memory observation reports current RSS and virtual size");
  end memory_observation_is_available;

  procedure repeated_memory_observation_is_stable
    (reporter : in out Clair.Test.Reporter.Context)
  is
    valid : Boolean := True;
  begin
    for iteration in 1 .. 1_000 loop
      declare
        snapshot : constant Sonbal.Diagnostics.Memory_Snapshot :=
          Sonbal.Diagnostics.observe_memory;
      begin
        valid := valid and then
          snapshot.state = Sonbal.Diagnostics.Observation_Available and then
          snapshot.resident_bytes > 0 and then
          snapshot.virtual_bytes >= snapshot.resident_bytes;
      end;
    end loop;

    Sonbal_Test_Support.check
      (reporter, valid, "repeated memory observation remains readable and bounded");
  end repeated_memory_observation_is_stable;

  procedure runtime_snapshot_reuses_runtime_state
    (reporter : in out Clair.Test.Reporter.Context)
  is
    loop_context : aliased Clair.Event_Loop.Context;
    runtime      : aliased Sonbal.Process_Runtime.Context;
    status       : Clair.Status.Code;
  begin
    declare
      snapshot : constant Sonbal.Diagnostics.Runtime_Snapshot :=
        Sonbal.Diagnostics.observe_runtime (runtime);
    begin
      Sonbal_Test_Support.check
        (reporter,
         not snapshot.initialized and then
           snapshot.active_execution_count = 0 and then
           snapshot.active_work_count = 0 and then
           snapshot.workspace_token_count = 0,
         "uninitialized runtime snapshot is explicit and empty");
    end;

    status := Clair.Event_Loop.initialize (loop_context);
    Sonbal_Test_Support.check
      (reporter, status = Clair.Status.OK, "diagnostic Event Loop initializes");
    if status /= Clair.Status.OK then
      return;
    end if;

    status := Sonbal.Process_Runtime.initialize
      (runtime, loop_context, Sonbal.Configuration.Work_Slot_Count (1));
    Sonbal_Test_Support.check
      (reporter, status = Clair.Status.OK, "diagnostic runtime initializes");
    if status = Clair.Status.OK then
      declare
        snapshot : constant Sonbal.Diagnostics.Runtime_Snapshot :=
          Sonbal.Diagnostics.observe_runtime (runtime);
      begin
        Sonbal_Test_Support.check
          (reporter,
           snapshot.initialized and then
             snapshot.active_execution_count =
               Sonbal.Process_Runtime.active_execution_count (runtime) and then
             snapshot.active_work_count =
               Sonbal.Process_Runtime.active_work_count (runtime) and then
             snapshot.workspace_token_count =
               Sonbal.Process_Runtime.workspace_token_count (runtime),
           "runtime snapshot reuses existing rotation/runtime counters");
      end;

      status := Sonbal.Process_Runtime.finalize (runtime);
      Sonbal_Test_Support.check
        (reporter, status = Clair.Status.OK, "diagnostic runtime finalizes");
    end if;

    status := Clair.Event_Loop.finalize (loop_context);
    Sonbal_Test_Support.check
      (reporter, status = Clair.Status.OK, "diagnostic Event Loop finalizes");
  end runtime_snapshot_reuses_runtime_state;

  procedure run (reporter : in out Clair.Test.Reporter.Context) is
  begin
    Clair.Test.Reporter.run_scenario
      (reporter,
       "memory observation is available",
       memory_observation_is_available'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "repeated memory observation is stable",
       repeated_memory_observation_is_stable'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "runtime snapshot reuses runtime state",
       runtime_snapshot_reuses_runtime_state'access);
  end run;

end Sonbal_Diagnostics_Tests;
