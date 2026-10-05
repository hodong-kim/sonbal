-- ============================================================================
-- sonbal_stdio_server_fixture.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Ada.Characters.Latin_1;
with Ada.Command_Line;
with Clair.Status;
with Clair.Unix.Signal;
with Sonbal.Configuration;
with Sonbal.Configuration.Tester;
with Sonbal.File_Read;
with Sonbal.MCP.Stdio_Server;

procedure Sonbal_Stdio_Server_Fixture is
  use type Clair.Status.Code;
  use type Clair.Unix.Signal.Action;
  use type Clair.Unix.Signal.Action_Kind;
  use type Sonbal.MCP.Stdio_Server.Run_Status;

  configuration : Sonbal.Configuration.Values;
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
     (Ada.Command_Line.Argument (1) = "--stdio-sigterm-restore" or else
      Ada.Command_Line.Argument (1) = "--stdio-sigint-restore")
  then
    declare
      signo : constant Clair.Unix.Signal.Number :=
        (if Ada.Command_Line.Argument (1) = "--stdio-sigterm-restore"
         then Clair.Unix.Signal.TERMINATION
         else Clair.Unix.Signal.INTERRUPT);
      before_action : Clair.Unix.Signal.Action;
      after_action  : Clair.Unix.Signal.Action;
      action_kind   : Clair.Unix.Signal.Action_Kind;
      status        : Clair.Status.Code;
    begin
      status := Clair.Unix.Signal.query_process_action (signo, before_action);
      if status /= Clair.Status.OK then
        Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
        return;
      end if;

      status := Clair.Unix.Signal.get_action_kind (before_action, action_kind);
      if status /= Clair.Status.OK or else
         action_kind /= Clair.Unix.Signal.Default_Disposition
      then
        Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
        return;
      end if;

      if Sonbal.MCP.Stdio_Server.run
        (Sonbal.Configuration.DEFAULT_MAX_WORK_SLOTS) /=
           Sonbal.MCP.Stdio_Server.Run_Completed
      then
        Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
        return;
      end if;

      status := Clair.Unix.Signal.query_process_action (signo, after_action);
      if status /= Clair.Status.OK or else after_action /= before_action then
        Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
        return;
      end if;

      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
      return;
    end;
  end if;
  if Ada.Command_Line.Argument_Count > 1 then
    Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
    return;
  elsif Ada.Command_Line.Argument_Count = 1 then
    declare
      source : constant String :=
        "execution:" & Ada.Characters.Latin_1.LF &
        "  max_work_slots: " & Ada.Command_Line.Argument (1) &
        Ada.Characters.Latin_1.LF;
    begin
      if not Sonbal.Configuration.Tester.parse_source
        (source, configuration)
      then
        Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
        return;
      end if;
    end;
  end if;

  case Sonbal.MCP.Stdio_Server.run (configuration.max_work_slots) is
    when Sonbal.MCP.Stdio_Server.Run_Completed =>
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
    when Sonbal.MCP.Stdio_Server.Run_Failed =>
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
  end case;
end Sonbal_Stdio_Server_Fixture;
