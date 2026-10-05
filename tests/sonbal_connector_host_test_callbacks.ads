-- ============================================================================
-- sonbal_connector_host_test_callbacks.ads
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Clair.Event_Loop;
with Clair.IO;
with Clair.Status;
with System;

package Sonbal_Connector_Host_Test_Callbacks is

  function watch_fault
    (source  : access constant Clair.Event_Loop.Source_Handle;
     fd      : Clair.IO.Descriptor;
     events  : Clair.Event_Loop.Event_Mask;
     context : System.Address)
  return Clair.Status.Code
  with Convention => C;

end Sonbal_Connector_Host_Test_Callbacks;
