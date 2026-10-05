-- ============================================================================
-- sonbal-platform_config.ads
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

package Sonbal.Platform_Config is
  type Supported_OS is (Linux, FreeBSD);

  TARGET_OS : constant Supported_OS := FreeBSD;
  CONFIG_FILE_PATH : constant String := "/usr/local/etc/sonbal/sonbal.yaml";
  OPENAI_CONNECTOR_LIBRARY_PATH : constant String :=
    "/usr/local/lib/sonbal/connectors/libsonbal_connector_openai.so";
  OPENAI_CONNECTOR_CONFIG_PATH : constant String :=
    "/usr/local/etc/sonbal/openai.json";
end Sonbal.Platform_Config;
