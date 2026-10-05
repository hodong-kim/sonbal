-- ============================================================================
-- sonbal-mcp-stdio_server.ads
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Sonbal.Configuration;

package Sonbal.MCP.Stdio_Server is
   type Run_Status is (Run_Completed, Run_Failed);

   function run
     (max_work_slots : Sonbal.Configuration.Work_Slot_Count)
   return Run_Status;
end Sonbal.MCP.Stdio_Server;
