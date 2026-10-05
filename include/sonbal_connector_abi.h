/* ============================================================================
 * sonbal_connector_abi.h
 * Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
 * SPDX-License-Identifier: 0BSD
 * ============================================================================
 */
#ifndef SONBAL_CONNECTOR_ABI_H
#define SONBAL_CONNECTOR_ABI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SONBAL_CONNECTOR_ABI_MAGIC UINT64_C(0x534f4e42414c4331)
#define SONBAL_CONNECTOR_ABI_VERSION UINT32_C(1)

#define SONBAL_CONNECTOR_STATUS_OK 0
#define SONBAL_CONNECTOR_STATUS_WOULD_BLOCK 1
#define SONBAL_CONNECTOR_STATUS_INVALID_ARGUMENT 2
#define SONBAL_CONNECTOR_STATUS_INVALID_STATE 3
#define SONBAL_CONNECTOR_STATUS_STARTUP_FAILED 4
#define SONBAL_CONNECTOR_STATUS_RESOURCE_EXHAUSTED 5
#define SONBAL_CONNECTOR_STATUS_INTERNAL_ERROR 6

#define SONBAL_CONNECTOR_KIND_UNKNOWN UINT32_C(0)
#define SONBAL_CONNECTOR_KIND_OPENAI UINT32_C(1)

#define SONBAL_CONNECTOR_EVENT_NONE UINT32_C(0)
#define SONBAL_CONNECTOR_EVENT_REQUEST UINT32_C(1)
#define SONBAL_CONNECTOR_EVENT_REQUEST_ABANDONED UINT32_C(2)
#define SONBAL_CONNECTOR_EVENT_FATAL UINT32_C(3)
#define SONBAL_CONNECTOR_EVENT_SHUTDOWN_COMPLETE UINT32_C(4)

#define SONBAL_CONNECTOR_NO_REQUEST_TOKEN UINT64_C(0)
#define SONBAL_CONNECTOR_INVALID_STARTUP_FD (-1)

typedef int sonbal_connector_status_t;
typedef uint32_t sonbal_connector_kind_t;
typedef uint32_t sonbal_connector_event_kind_t;
typedef uint64_t sonbal_connector_request_token_t;

struct sonbal_connector_initialize_parameters {
  uint32_t abi_version;
  uint32_t struct_size;
  uint32_t maximum_active_requests;
  uint32_t maximum_request_bytes;
  uint32_t maximum_response_bytes;
  int configuration_fd;
  int credential_fd;
};

struct sonbal_connector_event {
  sonbal_connector_request_token_t token;
  sonbal_connector_event_kind_t kind;
  uint32_t request_length;
  uint32_t correlation_length;
  uint32_t correlation_truncated;
};

typedef sonbal_connector_status_t
(*sonbal_connector_initialize_fn)(
  const struct sonbal_connector_initialize_parameters *parameters,
  void **instance,
  int *wakeup_fd);

typedef sonbal_connector_status_t
(*sonbal_connector_start_fn)(void *instance);

typedef sonbal_connector_status_t
(*sonbal_connector_next_event_fn)(
  void *instance,
  void *request_buffer,
  uint32_t request_capacity,
  void *correlation_buffer,
  uint32_t correlation_capacity,
  struct sonbal_connector_event *event);

typedef sonbal_connector_status_t
(*sonbal_connector_complete_request_fn)(
  void *instance,
  sonbal_connector_request_token_t token,
  const void *response,
  uint32_t response_length);

typedef sonbal_connector_status_t
(*sonbal_connector_begin_shutdown_fn)(void *instance);

typedef sonbal_connector_status_t
(*sonbal_connector_finalize_fn)(void **instance);

struct sonbal_connector_descriptor {
  uint64_t magic;
  uint32_t abi_version;
  uint32_t descriptor_size;
  sonbal_connector_kind_t kind;
  sonbal_connector_initialize_fn initialize;
  sonbal_connector_start_fn start;
  sonbal_connector_next_event_fn next_event;
  sonbal_connector_complete_request_fn complete_request;
  sonbal_connector_begin_shutdown_fn begin_shutdown;
  sonbal_connector_finalize_fn finalize;
};

extern const struct sonbal_connector_descriptor sonbal_connector_descriptor_v1;

#ifdef __cplusplus
}
#endif

#endif
