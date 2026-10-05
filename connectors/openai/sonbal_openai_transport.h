/* =========================================================================
 * sonbal_openai_transport.h
 * Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
 * SPDX-License-Identifier: 0BSD
 * =========================================================================
 */
#ifndef SONBAL_OPENAI_TRANSPORT_H
#define SONBAL_OPENAI_TRANSPORT_H

#include "sonbal_connector_abi.h"
#include "sonbal_openai_protocol.h"

#include <stddef.h>
#include <stdint.h>

#define SONBAL_OPENAI_PROVIDER_QUEUE_CAPACITY UINT32_C(20)

struct sonbal_openai_transport;

enum sonbal_openai_transport_status {
  SONBAL_OPENAI_TRANSPORT_OK = 0,
  SONBAL_OPENAI_TRANSPORT_WOULD_BLOCK = 1,
  SONBAL_OPENAI_TRANSPORT_INVALID_ARGUMENT = 2,
  SONBAL_OPENAI_TRANSPORT_INVALID_STATE = 3,
  SONBAL_OPENAI_TRANSPORT_RESOURCE_EXHAUSTED = 4,
  SONBAL_OPENAI_TRANSPORT_INTERNAL_ERROR = 5
};

enum sonbal_openai_transport_status
sonbal_openai_transport_create(
  struct sonbal_openai_transport **transport,
  const struct sonbal_openai_configuration *configuration,
  const char *base_url,
  const char *credential,
  size_t credential_length,
  uint32_t maximum_active_requests,
  uint32_t maximum_request_bytes,
  uint32_t maximum_response_bytes,
  int wakeup_write_fd);

enum sonbal_openai_transport_status
sonbal_openai_transport_start(
  struct sonbal_openai_transport *transport);

enum sonbal_openai_transport_status
sonbal_openai_transport_next_event(
  struct sonbal_openai_transport *transport,
  void *request_buffer,
  uint32_t request_capacity,
  void *correlation_buffer,
  uint32_t correlation_capacity,
  struct sonbal_connector_event *event);

enum sonbal_openai_transport_status
sonbal_openai_transport_complete(
  struct sonbal_openai_transport *transport,
  sonbal_connector_request_token_t token,
  const void *response,
  uint32_t response_length);

enum sonbal_openai_transport_status
sonbal_openai_transport_begin_shutdown(
  struct sonbal_openai_transport *transport);

void
sonbal_openai_transport_destroy(
  struct sonbal_openai_transport **transport);

#endif
