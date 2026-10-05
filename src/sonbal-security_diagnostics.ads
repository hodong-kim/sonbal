-- ============================================================================
-- sonbal-security_diagnostics.ads
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

package Sonbal.Security_Diagnostics is

  type Terminal_State is
    (No_Controlling_Terminal,
     Controlling_Terminal_Accessible,
     Terminal_Probe_Failed);

  type Observation is record
    control_plane_api_key_present : Boolean := False;
    openai_api_key_present        : Boolean := False;
    openai_admin_key_present      : Boolean := False;
    ssh_auth_sock_present         : Boolean := False;
    terminal                      : Terminal_State := Terminal_Probe_Failed;
  end record;

  --! summary Observe non-secret process security state for deployment checks.
  function observe return Observation;

  --! summary Return whether the observation satisfies the M5-01 preflight.
  function is_hardened (item : Observation) return Boolean;

  --! summary Print only presence/state diagnostics, never credential values.
  procedure print_report (item : Observation);

end Sonbal.Security_Diagnostics;
