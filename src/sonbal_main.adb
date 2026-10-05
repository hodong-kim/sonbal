-- ============================================================================
-- sonbal_main.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Ada.Command_Line;
with Clair.IO;
with Clair.Log;
with Sonbal.Configuration;
with Sonbal.Connector_Service;
with Sonbal.File_Read;
with Sonbal.MCP.Stdio_Server;
with Sonbal.Platform_Config;
with Sonbal.POSIX;
with Sonbal.Security_Diagnostics;

procedure Sonbal_Main is
  configuration : Sonbal.Configuration.Values;
  load_status   : Sonbal.Configuration.Load_Status;
  openai_connector_mode : constant Boolean :=
    Ada.Command_Line.Argument_Count = 2 and then
    Ada.Command_Line.Argument (1) = "--connector" and then
    Ada.Command_Line.Argument (2) = "openai";
  SHARED_FILE_CREATION_MASK : constant Sonbal.POSIX.File_Creation_Mask :=
    Sonbal.POSIX.File_Creation_Mask(8#002#);

  procedure configure_file_creation_mask
  is
    previous : constant Sonbal.POSIX.File_Creation_Mask :=
      Sonbal.POSIX.set_file_creation_mask (SHARED_FILE_CREATION_MASK);
    pragma Unreferenced (previous);
  begin
    null;
  end configure_file_creation_mask;

  procedure write_diagnostic (message : String) is
  begin
    Clair.Log.write
      (severity     => Clair.Log.Error,
       message      => message,
       destinations => Clair.Log.Native_Diagnostic);
  exception
    when others =>
      null;
  end write_diagnostic;
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

  if Ada.Command_Line.Argument_Count = 1 and then
     Ada.Command_Line.Argument (1) = "--security-check"
  then
    declare
      observation : constant Sonbal.Security_Diagnostics.Observation :=
        Sonbal.Security_Diagnostics.observe;
    begin
      Sonbal.Security_Diagnostics.print_report (observation);
      if Sonbal.Security_Diagnostics.is_hardened (observation) then
        Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
      else
        Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      end if;
      return;
    end;
  elsif Ada.Command_Line.Argument_Count /= 0 and then
        not openai_connector_mode
  then
    write_diagnostic ("sonbal: unsupported command-line argument");
    Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
    return;
  end if;

  configure_file_creation_mask;

  load_status := Sonbal.Configuration.load (configuration);
  case load_status is
    when Sonbal.Configuration.Configuration_Loaded |
         Sonbal.Configuration.Configuration_Defaulted =>
      null;
    when Sonbal.Configuration.Configuration_Invalid =>
      write_diagnostic ("sonbal: invalid configuration");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      return;
    when Sonbal.Configuration.Configuration_Read_Failed =>
      write_diagnostic ("sonbal: configuration read failed");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      return;
  end case;

  if openai_connector_mode then
    declare
      credential_fd : Clair.IO.Descriptor := Clair.IO.Descriptor (3);
    begin
      case Sonbal.Connector_Service.run
        (plugin_path        =>
           Sonbal.Platform_Config.OPENAI_CONNECTOR_LIBRARY_PATH,
         configuration_path =>
           Sonbal.Platform_Config.OPENAI_CONNECTOR_CONFIG_PATH,
         credential_fd      => credential_fd,
         max_work_slots     => configuration.max_work_slots)
      is
        when Sonbal.Connector_Service.Run_Completed =>
          Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
        when Sonbal.Connector_Service.Run_Failed =>
          Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      end case;
    end;
  else
    case Sonbal.MCP.Stdio_Server.run (configuration.max_work_slots) is
      when Sonbal.MCP.Stdio_Server.Run_Completed =>
        Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
      when Sonbal.MCP.Stdio_Server.Run_Failed =>
        Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
    end case;
  end if;
end Sonbal_Main;
