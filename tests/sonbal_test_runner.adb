-- ============================================================================
-- sonbal_test_runner.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Ada.Command_Line;
with Ada.Exceptions;
with Clair.Test.Reporter;
with Sonbal_Connector_ABI_Tests;
with Sonbal_Configuration_Tests;
with Sonbal_Diagnostics_Tests;
with Sonbal_File_Read_Tests;
with Sonbal_MCP_JSON_Tests;
with Sonbal_MCP_Dispatcher_Tests;
with Sonbal_MCP_Request_Core_Tests;
with Sonbal_MCP_Stdio_Framing_Tests;
with Sonbal_Process_Arguments_Tests;
with Sonbal_Process_Execution_Tests;
with Sonbal_Process_Jobs_Tests;
with Sonbal_Process_Runtime_Tests;
with Sonbal_Security_Diagnostics_Tests;
with Sonbal_Workspace_Tokens_Tests;

procedure Sonbal_Test_Runner is
   Reporter : Clair.Test.Reporter.Context;
begin
   Clair.Test.Reporter.Configure_From_Command_Line (Reporter);
   Clair.Test.Reporter.set_suite_count (Reporter, 14);
   Clair.Test.Reporter.Print_Header (Reporter);

   Clair.Test.Reporter.run_suite
     (Reporter,
      "Sonbal.Connector_ABI",
      Sonbal_Connector_ABI_Tests.run'access);
   Clair.Test.Reporter.run_suite
     (Reporter,
      "Sonbal.Configuration",
      Sonbal_Configuration_Tests.run'access);
   Clair.Test.Reporter.run_suite
     (Reporter,
      "Sonbal.Diagnostics",
      Sonbal_Diagnostics_Tests.run'access);
   Clair.Test.Reporter.run_suite
     (Reporter,
      "Sonbal.File_Read",
      Sonbal_File_Read_Tests.run'access);
   Clair.Test.Reporter.Run_Suite
     (Reporter,
      "Sonbal.MCP.Stdio_Framing",
      Sonbal_MCP_Stdio_Framing_Tests.Run'Access);
   Clair.Test.Reporter.Run_Suite
     (Reporter, "Sonbal.MCP.JSON", Sonbal_MCP_JSON_Tests.Run'Access);
   Clair.Test.Reporter.Run_Suite
     (Reporter,
      "Sonbal.MCP.Dispatcher",
      Sonbal_MCP_Dispatcher_Tests.Run'Access);
   Clair.Test.Reporter.run_suite
     (Reporter,
      "Sonbal.MCP.Request_Core",
      Sonbal_MCP_Request_Core_Tests.run'access);
   Clair.Test.Reporter.run_suite
     (Reporter,
      "Sonbal.Process_Arguments",
      Sonbal_Process_Arguments_Tests.run'access);
   Clair.Test.Reporter.run_suite
     (Reporter,
      "Sonbal.Process_Execution",
      Sonbal_Process_Execution_Tests.run'access);
   Clair.Test.Reporter.run_suite
     (Reporter,
      "Sonbal.Process_Jobs",
      Sonbal_Process_Jobs_Tests.run'access);
   Clair.Test.Reporter.run_suite
     (Reporter,
      "Sonbal.Process_Runtime",
      Sonbal_Process_Runtime_Tests.run'access);
   Clair.Test.Reporter.run_suite
     (Reporter,
      "Sonbal.Workspace_Tokens",
      Sonbal_Workspace_Tokens_Tests.run'access);
   Clair.Test.Reporter.run_suite
     (Reporter,
      "Sonbal.Security_Diagnostics",
      Sonbal_Security_Diagnostics_Tests.run'access);
   Clair.Test.Reporter.Print_Summary (Reporter);

   if Clair.Test.Reporter.Has_Failures (Reporter) then
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   else
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
   end if;
exception
   when Error : others =>
      Clair.Test.Reporter.Print_Exception
        (Reporter,
         Ada.Exceptions.Exception_Name (Error),
         Ada.Exceptions.Exception_Message (Error),
         Ada.Exceptions.Exception_Information (Error));
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
end Sonbal_Test_Runner;
