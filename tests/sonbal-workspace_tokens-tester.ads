-- ============================================================================
-- sonbal-workspace_tokens-tester.ads
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Interfaces;

package Sonbal.Workspace_Tokens.Tester is

  function next_generation
    (self : Context)
  return Interfaces.Unsigned_64;

  function retained_token_slot_count
    (self : Context)
  return Natural;

  function retained_rotation_operation_count
    (self : Context)
  return Natural;

end Sonbal.Workspace_Tokens.Tester;
