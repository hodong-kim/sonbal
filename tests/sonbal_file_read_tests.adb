-- ============================================================================
-- sonbal_file_read_tests.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Clair.IO;
with Clair.Process.Execution;
with Clair.Status;
with Sonbal.File_Read;
with Sonbal_Test_Support;
with System.Storage_Elements;

package body Sonbal_File_Read_Tests is

  use type Clair.Status.Code;
  use type Sonbal.File_Read.Read_State;
  use type System.Storage_Elements.Storage_Element;
  use type System.Storage_Elements.Storage_Offset;

  PRINTF_PATH : constant String := "/usr/bin/printf";

  function repeated (item : Character; count : Positive) return String is
    result : constant String (1 .. count) := [others => item];
  begin
    return result;
  end repeated;

  procedure parse_emitted_frame
    (reporter          : in out Clair.Test.Reporter.Context;
     frame             : String;
     requested_offset  : Clair.IO.File_Offset;
     requested_maximum : Positive;
     expected_revision : String;
     expected_status   : Clair.Status.Code;
     expected_state    : Sonbal.File_Read.Read_State;
     label             : String;
     expect_abc        : Boolean := False)
  is
    command : Clair.Process.Execution.Command :=
      Clair.Process.Execution.empty_command;
    outcome : Clair.Process.Execution.Result :=
      Clair.Process.Execution.empty_result;
    parsed : Sonbal.File_Read.Read_Result;
    status : Clair.Status.Code;
    parse_status : Clair.Status.Code := Clair.Status.INTERNAL_ERROR;
  begin
    status := Clair.Process.Execution.set_executable (command, PRINTF_PATH);
    if status = Clair.Status.OK then
      status := Clair.Process.Execution.add_argument (command, frame);
    end if;
    if status = Clair.Status.OK then
      status := Clair.Process.Execution.execute (command, outcome);
    end if;
    if status = Clair.Status.OK then
      parse_status := Sonbal.File_Read.parse_helper_outcome
        (status             => status,
         outcome            => outcome,
         requested_offset   => requested_offset,
         requested_maximum  => requested_maximum,
         expected_revision  => expected_revision,
         result             => parsed);
    end if;

    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK and then
         parse_status = expected_status and then
         (parse_status /= Clair.Status.OK or else
          parsed.state = expected_state) and then
         (not expect_abc or else
          (parsed.content_length = 3 and then
           parsed.content(parsed.content'first) =
             System.Storage_Elements.Storage_Element
               (Character'pos ('a')) and then
           parsed.content(parsed.content'first + System.Storage_Elements.Storage_Offset(1)) =
             System.Storage_Elements.Storage_Element
               (Character'pos ('b')) and then
           parsed.content(parsed.content'first + System.Storage_Elements.Storage_Offset(2)) =
             System.Storage_Elements.Storage_Element
               (Character'pos ('c')))),
       label);

    Clair.Process.Execution.reset (outcome);
    Clair.Process.Execution.reset (command);
  exception
    when others =>
      Clair.Process.Execution.reset (outcome);
      Clair.Process.Execution.reset (command);
      raise;
  end parse_emitted_frame;

  procedure helper_frame_validation
    (reporter : in out Clair.Test.Reporter.Context)
  is
    revision : constant String := "r1-" & repeated ('a', 96);
    other_revision : constant String := "r1-" & repeated ('b', 96);
    lf : constant Character := Character'val (10);
  begin
    parse_emitted_frame
      (reporter,
       "SBRF1|ok|" & revision & "|3|0|3|1" & lf & "abc",
       0,
       3,
       "",
       Clair.Status.OK,
       Sonbal.File_Read.Read_OK,
       "valid helper frame preserves exact bounded payload",
       expect_abc => True);

    parse_emitted_frame
      (reporter,
       "BADF1|not_found|-|0|0|0|0" & lf,
       0,
       1,
       "",
       Clair.Status.INTERNAL_ERROR,
       Sonbal.File_Read.Read_Execution_Failed,
       "wrong helper protocol magic fails closed");

    parse_emitted_frame
      (reporter,
       "SBRF1|not_found|-|0|0|0|0" & lf & "x",
       0,
       1,
       "",
       Clair.Status.INTERNAL_ERROR,
       Sonbal.File_Read.Read_Execution_Failed,
       "error helper frame rejects unexpected payload");

    parse_emitted_frame
      (reporter,
       "SBRF1|timed_out|-|0|0|0|0" & lf,
       0,
       1,
       "",
       Clair.Status.INTERNAL_ERROR,
       Sonbal.File_Read.Read_Execution_Failed,
       "helper cannot fabricate parent-owned timeout state");

    parse_emitted_frame
      (reporter,
       "SBRF1|ok|" & revision & "|3|0|2|0" & lf & "abc",
       0,
       3,
       "",
       Clair.Status.INTERNAL_ERROR,
       Sonbal.File_Read.Read_Execution_Failed,
       "success helper frame rejects inconsistent payload length");

    parse_emitted_frame
      (reporter,
       "SBRF1|ok|" & revision & "|3|0|3|1" & lf & "abc",
       0,
       3,
       other_revision,
       Clair.Status.INTERNAL_ERROR,
       Sonbal.File_Read.Read_Execution_Failed,
       "success helper frame cannot bypass expected revision");
  end helper_frame_validation;

  procedure run (reporter : in out Clair.Test.Reporter.Context) is
  begin
    Clair.Test.Reporter.run_scenario
      (reporter,
       "private helper frame validation",
       helper_frame_validation'access);
  end run;

end Sonbal_File_Read_Tests;
