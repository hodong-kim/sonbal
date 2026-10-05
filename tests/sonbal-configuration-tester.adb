-- ============================================================================
-- sonbal-configuration-tester.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

package body Sonbal.Configuration.Tester is
  function parse_source
    (source : String;
     result : out Values)
  return Boolean
  is
  begin
    return Sonbal.Configuration.parse_source (source, result);
  end parse_source;
end Sonbal.Configuration.Tester;
