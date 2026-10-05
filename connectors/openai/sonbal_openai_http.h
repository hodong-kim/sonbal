/* =========================================================================
 * sonbal_openai_http.h
 * Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
 * SPDX-License-Identifier: 0BSD
 * =========================================================================
 */
#ifndef SONBAL_OPENAI_HTTP_H
#define SONBAL_OPENAI_HTTP_H

#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define SONBAL_OPENAI_HTTP_MAX_BASE_URL_BYTES UINT32_C(512)
#define SONBAL_OPENAI_HTTP_MAX_CLIENT_NAME_BYTES UINT32_C(64)
#define SONBAL_OPENAI_HTTP_MAX_CLIENT_VERSION_BYTES UINT32_C(64)
#define SONBAL_OPENAI_HTTP_MAX_CREDENTIAL_BYTES UINT32_C(1024)
#define SONBAL_OPENAI_HTTP_MAX_POLL_TIMEOUT_MS UINT32_C(600000)
#define SONBAL_OPENAI_HTTP_WIRE_PROTOCOL_VERSION "2026-08-25"

enum sonbal_openai_http_status {
  SONBAL_OPENAI_HTTP_OK = 0,
  SONBAL_OPENAI_HTTP_INVALID_ARGUMENT = 1,
  SONBAL_OPENAI_HTTP_INITIALIZATION_FAILED = 2,
  SONBAL_OPENAI_HTTP_TRANSPORT_FAILED = 3,
  SONBAL_OPENAI_HTTP_BODY_LIMIT = 4,
  SONBAL_OPENAI_HTTP_CANCELLED = 5
};

struct sonbal_openai_http_result {
  enum sonbal_openai_http_status status;
  long response_code;
  size_t body_length;
  uint64_t headers_received_ns;
  bool retry_after_present;
  bool retry_after_valid;
  uint64_t retry_after_ms;
  int transport_code;
};

struct sonbal_openai_http_client {
  void *easy;

  char credential[SONBAL_OPENAI_HTTP_MAX_CREDENTIAL_BYTES + 1];
  size_t credential_length;

  char base_url[SONBAL_OPENAI_HTTP_MAX_BASE_URL_BYTES + 1];
  size_t base_url_length;

  char tunnel_id[257];
  size_t tunnel_id_length;

  char client_name[SONBAL_OPENAI_HTTP_MAX_CLIENT_NAME_BYTES + 1];
  size_t client_name_length;

  char client_version[SONBAL_OPENAI_HTTP_MAX_CLIENT_VERSION_BYTES + 1];
  size_t client_version_length;

  atomic_bool cancelled;
  bool global_acquired;
};

enum sonbal_openai_http_status
sonbal_openai_http_initialize(
  struct sonbal_openai_http_client *client,
  const char *base_url,
  const char *tunnel_id,
  const char *credential,
  size_t credential_length,
  const char *client_name,
  const char *client_version);

void
sonbal_openai_http_cancel(
  struct sonbal_openai_http_client *client);

void
sonbal_openai_http_reset_cancellation(
  struct sonbal_openai_http_client *client);

enum sonbal_openai_http_status
sonbal_openai_http_poll(
  struct sonbal_openai_http_client *client,
  uint32_t limit,
  uint32_t timeout_ms,
  char *body,
  size_t body_capacity,
  struct sonbal_openai_http_result *result);

enum sonbal_openai_http_status
sonbal_openai_http_post_response(
  struct sonbal_openai_http_client *client,
  const char *shard_token,
  const char *json_body,
  size_t json_body_length,
  uint32_t timeout_ms,
  char *body,
  size_t body_capacity,
  struct sonbal_openai_http_result *result);

void
sonbal_openai_http_finalize(
  struct sonbal_openai_http_client *client);

#endif
