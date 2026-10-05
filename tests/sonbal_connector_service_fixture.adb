-- ============================================================================
-- sonbal_connector_service_fixture.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Ada.Command_Line;
with Ada.Text_IO;
with Clair.IO;
with Clair.Process;
with Clair.Process.POSIX;
with Clair.Status;
with Clair.Unix.File;
with Clair.Unix.Signal;
with Sonbal.Configuration;
with Sonbal.Connector_Service;

procedure Sonbal_Connector_Service_Fixture is

  use type Clair.IO.Descriptor;
  use type Clair.Status.Code;
  use type Sonbal.Connector_Service.Run_Result;

  trigger_failed : Boolean := False
    with Atomic;

  task Shutdown_Trigger;

  task body Shutdown_Trigger is
    trigger_status : Clair.Status.Code;
  begin
    delay 1.0;
    trigger_status := Clair.Process.POSIX.send_signal_to_process
      (target_id => Clair.Process.current_process_id,
       signal    => Clair.Unix.Signal.TERMINATION);
    if trigger_status /= Clair.Status.OK then
      trigger_failed := True;
    end if;
  exception
    when others =>
      trigger_failed := True;
  end Shutdown_Trigger;

  procedure fail (message : String) is
  begin
    Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, message);
    Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
    raise Program_Error with message;
  end fail;

  plugin_path : constant String := Ada.Command_Line.Argument (1);
  configuration_path : constant String := Ada.Command_Line.Argument (2);
  credential_path : constant String := Ada.Command_Line.Argument (3);
  credential_fd : Clair.IO.Descriptor := Clair.IO.INVALID_DESCRIPTOR;
  status : Clair.Status.Code;
  result : Sonbal.Connector_Service.Run_Result;

begin
  if Ada.Command_Line.Argument_Count /= 3 then
    fail ("usage: fixture PLUGIN CONFIGURATION CREDENTIAL");
  end if;

  status := Clair.Unix.File.open
    (path             => credential_path,
     requested_access => Clair.Unix.File.Read_Only,
     options          =>
       [Clair.Unix.File.Close_On_Exec => True, others => False],
     opened_descriptor => credential_fd);
  if status /= Clair.Status.OK then
    fail ("cannot open connector-service fixture credential");
  end if;

  result := Sonbal.Connector_Service.run
    (plugin_path        => plugin_path,
     configuration_path => configuration_path,
     credential_fd      => credential_fd,
     max_work_slots     => Sonbal.Configuration.DEFAULT_MAX_WORK_SLOTS);

  if credential_fd /= Clair.IO.INVALID_DESCRIPTOR then
    fail ("connector service retained startup credential descriptor");
  end if;

  if result /= Sonbal.Connector_Service.Run_Completed then
    fail ("connector service lifecycle failed");
  end if;

  if trigger_failed then
    fail ("connector service fixture could not deliver SIGTERM");
  end if;

  Ada.Text_IO.Put_Line ("[PASS] connector service bounded lifecycle");
  Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);

exception
  when Program_Error =>
    if credential_fd /= Clair.IO.INVALID_DESCRIPTOR then
      status := Clair.IO.close (credential_fd);
      credential_fd := Clair.IO.INVALID_DESCRIPTOR;
    end if;
end Sonbal_Connector_Service_Fixture;
