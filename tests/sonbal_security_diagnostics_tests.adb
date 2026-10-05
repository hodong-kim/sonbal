-- ============================================================================
-- sonbal_security_diagnostics_tests.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Sonbal.Security_Diagnostics;
with Sonbal_Test_Support;

package body Sonbal_Security_Diagnostics_Tests is

  function clean_observation return Sonbal.Security_Diagnostics.Observation is
  begin
    return
      (control_plane_api_key_present => False,
       openai_api_key_present        => False,
       openai_admin_key_present      => False,
       ssh_auth_sock_present         => False,
       terminal                      =>
         Sonbal.Security_Diagnostics.No_Controlling_Terminal);
  end clean_observation;

  procedure clean_topology_is_hardened
    (reporter : in out Clair.Test.Reporter.Context)
  is
  begin
    Sonbal_Test_Support.check
      (reporter,
       Sonbal.Security_Diagnostics.is_hardened (clean_observation),
       "clean deployment observation is hardened");
  end clean_topology_is_hardened;

  procedure ambient_credentials_are_rejected
    (reporter : in out Clair.Test.Reporter.Context)
  is
    item : Sonbal.Security_Diagnostics.Observation := clean_observation;
  begin
    item.control_plane_api_key_present := True;
    Sonbal_Test_Support.check
      (reporter,
       not Sonbal.Security_Diagnostics.is_hardened (item),
       "control-plane API key environment is unsafe");

    item := clean_observation;
    item.openai_api_key_present := True;
    Sonbal_Test_Support.check
      (reporter,
       not Sonbal.Security_Diagnostics.is_hardened (item),
       "fallback API key environment is unsafe");

    item := clean_observation;
    item.openai_admin_key_present := True;
    Sonbal_Test_Support.check
      (reporter,
       not Sonbal.Security_Diagnostics.is_hardened (item),
       "admin API key environment is unsafe");

    item := clean_observation;
    item.ssh_auth_sock_present := True;
    Sonbal_Test_Support.check
      (reporter,
       not Sonbal.Security_Diagnostics.is_hardened (item),
       "SSH agent environment is unsafe");
  end ambient_credentials_are_rejected;

  procedure terminal_access_is_rejected
    (reporter : in out Clair.Test.Reporter.Context)
  is
    item : Sonbal.Security_Diagnostics.Observation := clean_observation;
  begin
    item.terminal :=
      Sonbal.Security_Diagnostics.Controlling_Terminal_Accessible;
    Sonbal_Test_Support.check
      (reporter,
       not Sonbal.Security_Diagnostics.is_hardened (item),
       "accessible controlling terminal is unsafe");

    item.terminal := Sonbal.Security_Diagnostics.Terminal_Probe_Failed;
    Sonbal_Test_Support.check
      (reporter,
       not Sonbal.Security_Diagnostics.is_hardened (item),
       "indeterminate terminal state fails closed");
  end terminal_access_is_rejected;

  procedure run (reporter : in out Clair.Test.Reporter.Context) is
  begin
    Clair.Test.Reporter.run_scenario
      (reporter,
       "clean topology is hardened",
       clean_topology_is_hardened'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "ambient credentials are rejected",
       ambient_credentials_are_rejected'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "terminal access is rejected",
       terminal_access_is_rejected'access);
  end run;

end Sonbal_Security_Diagnostics_Tests;
