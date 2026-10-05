-- ============================================================================
-- sonbal_connector_host_test_callbacks.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

package body Sonbal_Connector_Host_Test_Callbacks is

  function watch_fault
    (source  : access constant Clair.Event_Loop.Source_Handle;
     fd      : Clair.IO.Descriptor;
     events  : Clair.Event_Loop.Event_Mask;
     context : System.Address)
  return Clair.Status.Code
  is
    pragma Unreferenced (source, fd, events, context);
  begin
    return Clair.Status.OK;
  end watch_fault;

end Sonbal_Connector_Host_Test_Callbacks;
