-- ============================================================================
-- sonbal_configuration_tests.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Ada.Characters.Latin_1;
with Ada.Environment_Variables;
with Sonbal.Configuration;
with Sonbal.Configuration.Tester;
with Sonbal.Platform_Config;
with Sonbal_Test_Support;

package body Sonbal_Configuration_Tests is

  LF : constant Character := Ada.Characters.Latin_1.LF;

  function parses_as
    (source   : String;
     expected : Sonbal.Configuration.Work_Slot_Count)
  return Boolean
  is
    values : Sonbal.Configuration.Values;
  begin
    return Sonbal.Configuration.Tester.parse_source (source, values) and then
      values.max_work_slots = expected;
  end parses_as;

  function rejects (source : String) return Boolean is
    values : Sonbal.Configuration.Values;
  begin
    return not Sonbal.Configuration.Tester.parse_source (source, values);
  end rejects;

  procedure defaults_and_boundaries
    (reporter : in out Clair.Test.Reporter.Context)
  is
  begin
    Sonbal_Test_Support.check
      (reporter,
       parses_as
         ("{}" & LF, Sonbal.Configuration.DEFAULT_MAX_WORK_SLOTS),
       "omitted maximum work slot setting selects sixteen slots");
    Sonbal_Test_Support.check
      (reporter,
       parses_as
         ("execution: {}" & LF, Sonbal.Configuration.DEFAULT_MAX_WORK_SLOTS),
       "empty execution mapping selects sixteen maximum slots");
    Sonbal_Test_Support.check
      (reporter,
       parses_as ("execution:" & LF & "  max_work_slots: 1" & LF, 1),
       "one work slot is accepted");
    Sonbal_Test_Support.check
      (reporter,
       parses_as ("execution:" & LF & "  max_work_slots: 16" & LF, 16),
       "default maximum work slot value is accepted explicitly");
    Sonbal_Test_Support.check
      (reporter,
       parses_as ("execution:" & LF & "  max_work_slots: 64" & LF, 64),
       "hard maximum work slot value is accepted");
  end defaults_and_boundaries;

  procedure invalid_values_fail_closed
    (reporter : in out Clair.Test.Reporter.Context)
  is
    oversized : constant String
      (1 .. Sonbal.Configuration.MAXIMUM_CONFIG_BYTES + 1) := [others => 'x'];
  begin
    Sonbal_Test_Support.check
      (reporter,
       rejects ("execution:" & LF & "  max_work_slots: 0" & LF),
       "zero work slots are rejected");
    Sonbal_Test_Support.check
      (reporter,
       rejects ("execution:" & LF & "  max_work_slots: 65" & LF),
       "work slots above the hard maximum are rejected");
    Sonbal_Test_Support.check
      (reporter,
       rejects ("execution:" & LF & "  max_work_slots: eight" & LF),
       "nonnumeric work slots are rejected");
    Sonbal_Test_Support.check
      (reporter,
       rejects ("execution:" & LF & "  max_work_slots:" & LF & "    - 8" & LF),
       "wrong-type work slots are rejected");
    Sonbal_Test_Support.check
      (reporter,
       rejects ("execution:" & LF & "  work_slots: 16" & LF),
       "retired work_slots key is rejected");
    Sonbal_Test_Support.check
      (reporter,
       rejects ("execution:" & LF & "  work_slot: 8" & LF),
       "unknown configuration keys are rejected");
    Sonbal_Test_Support.check
      (reporter,
       rejects ("other: 8" & LF),
       "unknown root configuration keys are rejected");
    Sonbal_Test_Support.check
      (reporter,
       rejects ("execution.max_work_slots: 8" & LF),
       "flat dotted work slot syntax is rejected");
    Sonbal_Test_Support.check
      (reporter,
       rejects
         ("execution:" & LF &
          "  max_work_slots: 8" & LF &
          "  max_work_slots: 8" & LF),
       "duplicate work slot keys are rejected");
    Sonbal_Test_Support.check
      (reporter,
       rejects ("") and then rejects (oversized),
       "empty and oversized configuration documents are rejected");
  end invalid_values_fail_closed;

  procedure platform_configuration_path
    (reporter : in out Clair.Test.Reporter.Context)
  is
    actual : String (Sonbal.Configuration.CONFIG_FILE_PATH'Range);
    expected : constant String :=
      (case Sonbal.Platform_Config.TARGET_OS is
         when Sonbal.Platform_Config.Linux => "/etc/sonbal/sonbal.yaml",
         when Sonbal.Platform_Config.FreeBSD =>
           "/usr/local/etc/sonbal/sonbal.yaml");
  begin
    actual := Sonbal.Configuration.CONFIG_FILE_PATH;
    Sonbal_Test_Support.check
      (reporter,
       actual = expected,
       "platform target selects its native configuration path");
  end platform_configuration_path;

  procedure diagnostic_trace_switch_is_exact
    (reporter : in out Clair.Test.Reporter.Context)
  is
    name : constant String := "SONBAL_DIAGNOSTIC_TRACE";
    had_value : constant Boolean := Ada.Environment_Variables.Exists (name);
    old_value : constant String :=
      (if had_value then Ada.Environment_Variables.Value (name) else "");

    procedure restore is
    begin
      if had_value then
        Ada.Environment_Variables.Set (name, old_value);
      else
        Ada.Environment_Variables.Clear (name);
      end if;
    exception
      when others =>
        null;
    end restore;
  begin
    if had_value then
      Ada.Environment_Variables.Clear (name);
    end if;
    Sonbal_Test_Support.check
      (reporter,
       not Sonbal.Configuration.diagnostic_trace_enabled,
       "missing diagnostic trace switch stays disabled");

    Ada.Environment_Variables.Set (name, "0");
    Sonbal_Test_Support.check
      (reporter,
       not Sonbal.Configuration.diagnostic_trace_enabled,
       "non-enabling diagnostic trace value stays disabled");

    Ada.Environment_Variables.Set (name, "1");
    Sonbal_Test_Support.check
      (reporter,
       Sonbal.Configuration.diagnostic_trace_enabled,
       "exact diagnostic trace value enables bounded tracing");

    restore;
  exception
    when others =>
      restore;
      Sonbal_Test_Support.check
        (reporter, False, "diagnostic trace switch policy");
  end diagnostic_trace_switch_is_exact;

  procedure run (reporter : in out Clair.Test.Reporter.Context) is
  begin
    Clair.Test.Reporter.run_scenario
      (reporter,
       "defaults and work slot boundaries",
       defaults_and_boundaries'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "invalid work slot configuration fails closed",
       invalid_values_fail_closed'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "platform configuration path",
       platform_configuration_path'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "diagnostic trace switch policy",
       diagnostic_trace_switch_is_exact'access);
  end run;

end Sonbal_Configuration_Tests;
