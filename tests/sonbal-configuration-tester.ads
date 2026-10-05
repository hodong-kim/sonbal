-- ============================================================================
-- sonbal-configuration-tester.ads
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

package Sonbal.Configuration.Tester is
  function parse_source
    (source : String;
     result : out Values)
  return Boolean;
end Sonbal.Configuration.Tester;
