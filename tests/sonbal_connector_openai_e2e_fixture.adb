-- ============================================================================
-- sonbal_connector_openai_e2e_fixture.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Ada.Command_Line;
with Ada.Text_IO;
with Clair.IO;
with Clair.Status;
with Clair.Unix.File;
with Sonbal.Configuration;
with Sonbal.Connector_Service;
with Sonbal.File_Read;

procedure Sonbal_Connector_OpenAI_E2E_Fixture is

  use type Clair.IO.Descriptor;
  use type Clair.Status.Code;
  use type Sonbal.Connector_Service.Run_Result;

  procedure fail (message : String) is
  begin
    Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, message);
    Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
    raise Program_Error with message;
  end fail;

  plugin_path        : constant String := Ada.Command_Line.Argument (1);
  configuration_path : constant String := Ada.Command_Line.Argument (2);
  credential_path    : constant String := Ada.Command_Line.Argument (3);
  expected_result    : constant String := Ada.Command_Line.Argument (4);
  credential_fd      : Clair.IO.Descriptor := Clair.IO.INVALID_DESCRIPTOR;
  status             : Clair.Status.Code;
  result             : Sonbal.Connector_Service.Run_Result;

begin
  if Ada.Command_Line.Argument_Count > 0 and then
     Ada.Command_Line.Argument (1) = "--internal-read-file"
  then
    if Ada.Command_Line.Argument_Count = 8 and then
       Sonbal.File_Read.run_helper
         (workspace_root     => Ada.Command_Line.Argument (2),
          root_filesystem_id => Ada.Command_Line.Argument (3),
          root_object_id     => Ada.Command_Line.Argument (4),
          path               => Ada.Command_Line.Argument (5),
          offset_text        => Ada.Command_Line.Argument (6),
          maximum_text       => Ada.Command_Line.Argument (7),
          expected_revision  => Ada.Command_Line.Argument (8))
    then
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
    else
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
    end if;
    return;
  end if;

  if Ada.Command_Line.Argument_Count /= 4 then
    fail ("usage: fixture PLUGIN CONFIGURATION CREDENTIAL EXPECTED_RESULT");
  end if;
  if expected_result /= "completed" and then expected_result /= "failed" then
    fail ("expected result must be completed or failed");
  end if;

  status := Clair.Unix.File.open
    (path             => credential_path,
     requested_access => Clair.Unix.File.Read_Only,
     options          =>
       [Clair.Unix.File.Close_On_Exec => True, others => False],
     opened_descriptor => credential_fd);
  if status /= Clair.Status.OK then
    fail ("cannot open PCA-05 credential fixture");
  end if;

  result := Sonbal.Connector_Service.run
    (plugin_path        => plugin_path,
     configuration_path => configuration_path,
     credential_fd      => credential_fd,
     max_work_slots     => Sonbal.Configuration.DEFAULT_MAX_WORK_SLOTS);

  if credential_fd /= Clair.IO.INVALID_DESCRIPTOR then
    fail ("PCA-05 service retained startup credential descriptor");
  end if;

  if expected_result = "completed" then
    if result /= Sonbal.Connector_Service.Run_Completed then
      fail ("PCA-05 connector service lifecycle did not complete");
    end if;
  elsif result /= Sonbal.Connector_Service.Run_Failed then
    fail ("PCA-05 connector service lifecycle did not fail closed");
  end if;

  Ada.Text_IO.Put_Line
    ("[PASS] PCA-05 Linux connector service " & expected_result);
  Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);

exception
  when Program_Error =>
    if credential_fd /= Clair.IO.INVALID_DESCRIPTOR then
      status := Clair.IO.close (credential_fd);
      credential_fd := Clair.IO.INVALID_DESCRIPTOR;
    end if;
end Sonbal_Connector_OpenAI_E2E_Fixture;
