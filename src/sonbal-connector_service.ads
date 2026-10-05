-- ============================================================================
-- sonbal-connector_service.ads
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Clair.IO;
with Sonbal.Configuration;

package Sonbal.Connector_Service is

  type Run_Result is (Run_Completed, Run_Failed);

  function run
    (plugin_path        : String;
     configuration_path : String;
     credential_fd      : in out Clair.IO.Descriptor;
     max_work_slots     : Sonbal.Configuration.Work_Slot_Count)
  return Run_Result;

end Sonbal.Connector_Service;
