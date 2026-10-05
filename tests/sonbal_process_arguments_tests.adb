-- ============================================================================
-- sonbal_process_arguments_tests.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Sonbal.Process_Arguments;
with Sonbal_Test_Support;

package body Sonbal_Process_Arguments_Tests is

  package Arguments renames Sonbal.Process_Arguments;

  use type Arguments.Append_State;

  procedure append_and_observe
    (reporter : in out Clair.Test.Reporter.Context)
  is
    executable : constant String := "/bin/echo";
    trailing   : constant String := "sonbal";
    value      : Arguments.Arguments;
    state      : Arguments.Append_State;
  begin
    Arguments.clear (value);
    state := Arguments.append (value, executable);
    state :=
      (if state = Arguments.Append_Accepted
       then Arguments.append (value, "")
       else state);
    state :=
      (if state = Arguments.Append_Accepted
       then Arguments.append (value, trailing)
       else state);

    Sonbal_Test_Support.check
      (reporter,
       state = Arguments.Append_Accepted and then
         Arguments.is_valid (value) and then
         Arguments.count (value) = 3 and then
         Arguments.total_bytes (value) =
           executable'Length + trailing'Length and then
         Arguments.argument_at (value, 1) = executable and then
         Arguments.argument_at (value, 2) = "" and then
         Arguments.argument_at (value, 3) = trailing,
       "bounded process arguments preserve exact item boundaries");
  end append_and_observe;

  procedure invalid_append_is_transactional
    (reporter : in out Clair.Test.Reporter.Context)
  is
    executable : constant String := "/bin/echo";
    value      : Arguments.Arguments;
    state      : Arguments.Append_State;
  begin
    Arguments.clear (value);
    state := Arguments.append (value, "");
    Sonbal_Test_Support.check
      (reporter,
       state = Arguments.Append_Empty_Executable and then
         not Arguments.is_valid (value) and then
         Arguments.count (value) = 0 and then
         Arguments.total_bytes (value) = 0,
       "empty executable is rejected without mutation");

    state := Arguments.append (value, executable);
    state :=
      (if state = Arguments.Append_Accepted
       then Arguments.append
         (value, "bad" & Character'Val (0) & "argument")
       else state);

    Sonbal_Test_Support.check
      (reporter,
       state = Arguments.Append_Contains_Nul and then
         Arguments.count (value) = 1 and then
         Arguments.total_bytes (value) = executable'Length and then
         Arguments.argument_at (value, 1) = executable,
       "embedded NUL rejection preserves the prior valid argv");
  end invalid_append_is_transactional;

  procedure count_and_byte_limits_are_exact
    (reporter : in out Clair.Test.Reporter.Context)
  is
    value : Arguments.Arguments;
    state : Arguments.Append_State;
    valid : Boolean := True;
  begin
    Arguments.clear (value);
    state := Arguments.append (value, "/usr/bin/true");
    valid := state = Arguments.Append_Accepted;

    for index in 2 .. Arguments.MAXIMUM_ARGUMENT_COUNT loop
      state := Arguments.append (value, "");
      valid := valid and then state = Arguments.Append_Accepted;
    end loop;

    state := Arguments.append (value, "");
    Sonbal_Test_Support.check
      (reporter,
       valid and then
         state = Arguments.Append_Count_Exceeded and then
         Arguments.count (value) = Arguments.MAXIMUM_ARGUMENT_COUNT,
       "argument count ceiling rejects one extra item without mutation");

    Arguments.clear (value);
    declare
      full : constant String (1 .. Arguments.MAXIMUM_ARGV_BYTES) :=
        [others => 'x'];
    begin
      state := Arguments.append (value, full);
    end;

    Sonbal_Test_Support.check
      (reporter,
       state = Arguments.Append_Accepted and then
         Arguments.total_bytes (value) = Arguments.MAXIMUM_ARGV_BYTES,
       "aggregate byte ceiling accepts its exact maximum");

    state := Arguments.append (value, "x");
    Sonbal_Test_Support.check
      (reporter,
       state = Arguments.Append_Bytes_Exceeded and then
         Arguments.total_bytes (value) = Arguments.MAXIMUM_ARGV_BYTES,
       "aggregate byte ceiling rejects one extra byte transactionally");
  end count_and_byte_limits_are_exact;

  procedure run (reporter : in out Clair.Test.Reporter.Context) is
  begin
    Clair.Test.Reporter.run_scenario
      (reporter,
       "append and observe",
       append_and_observe'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "invalid append is transactional",
       invalid_append_is_transactional'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "count and byte limits are exact",
       count_and_byte_limits_are_exact'access);
  end run;

end Sonbal_Process_Arguments_Tests;
