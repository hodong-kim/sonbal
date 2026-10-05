-- ============================================================================
-- sonbal-configuration.ads
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Sonbal.Platform_Config;

package Sonbal.Configuration is

  --! summary Fallback execution ceiling when no explicit value is configured.
  DEFAULT_MAX_WORK_SLOTS  : constant Positive := 16;
  --! summary Compiled fail-closed ceiling for configured concurrent work.
  ABSOLUTE_MAX_WORK_SLOTS : constant Positive := 64;
  MAXIMUM_CONFIG_BYTES    : constant Positive := 16_384;

  CONFIG_FILE_PATH : constant String :=
    Sonbal.Platform_Config.CONFIG_FILE_PATH;

  subtype Work_Slot_Count is Positive range 1 .. ABSOLUTE_MAX_WORK_SLOTS;

  --! summary Report whether bounded diagnostic tracing is explicitly enabled.
  --! notes Only the exact environment value `1` enables tracing. Missing,
  --!   malformed, or unreadable environment state selects the safe default.
  function diagnostic_trace_enabled return Boolean;

  type Values is record
    max_work_slots : Work_Slot_Count := DEFAULT_MAX_WORK_SLOTS;
  end record;

  type Load_Status is
    (Configuration_Loaded,
     Configuration_Defaulted,
     Configuration_Invalid,
     Configuration_Read_Failed);

  --! summary Load the fixed Sonbal YAML configuration path.
  --! notes A missing file selects product defaults. Existing invalid or
  --!   unreadable configuration fails closed.
  function load (result : out Values) return Load_Status;

private

  function parse_source
    (source : String;
     result : out Values)
  return Boolean;

end Sonbal.Configuration;
