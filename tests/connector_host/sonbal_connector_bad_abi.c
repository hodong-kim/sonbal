/*
 * sonbal_connector_bad_abi.c
 * Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
 * SPDX-License-Identifier: 0BSD
 */
#include "sonbal_connector_abi.h"

const struct sonbal_connector_descriptor sonbal_connector_descriptor_v1 = {
  UINT64_C(0),
  SONBAL_CONNECTOR_ABI_VERSION,
  sizeof(struct sonbal_connector_descriptor),
  SONBAL_CONNECTOR_KIND_OPENAI,
  0,
  0,
  0,
  0,
  0,
  0
};
