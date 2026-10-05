/* =========================================================================
 * sonbal_openai_protocol.h
 * Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
 * SPDX-License-Identifier: 0BSD
 * =========================================================================
 */
#ifndef SONBAL_OPENAI_PROTOCOL_H
#define SONBAL_OPENAI_PROTOCOL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define SONBAL_OPENAI_MAX_CONFIG_BYTES UINT32_C(8192)
#define SONBAL_OPENAI_MAX_TUNNEL_ID_BYTES UINT32_C(256)
#define SONBAL_OPENAI_MAX_REQUEST_ID_BYTES UINT32_C(256)
#define SONBAL_OPENAI_MAX_SHARD_TOKEN_BYTES UINT32_C(1024)
#define SONBAL_OPENAI_MAX_CHANNEL_BYTES UINT32_C(128)
#define SONBAL_OPENAI_MAX_CREATED_AT_BYTES UINT32_C(128)
#define SONBAL_OPENAI_MAX_TIMEOUT_TEXT_BYTES UINT32_C(64)
#define SONBAL_OPENAI_MAX_CREDENTIAL_BYTES UINT32_C(1024)

#define SONBAL_OPENAI_DEFAULT_POLL_LIMIT UINT32_C(25)
#define SONBAL_OPENAI_DEFAULT_POLL_TIMEOUT_MS UINT32_C(30000)
#define SONBAL_OPENAI_MAX_POLL_LIMIT UINT32_C(25)
#define SONBAL_OPENAI_MAX_POLL_TIMEOUT_MS UINT32_C(600000)

enum sonbal_openai_protocol_status {
  SONBAL_OPENAI_PROTOCOL_OK = 0,
  SONBAL_OPENAI_PROTOCOL_INVALID_JSON = 1,
  SONBAL_OPENAI_PROTOCOL_INVALID_ENVELOPE = 2,
  SONBAL_OPENAI_PROTOCOL_LIMIT_EXCEEDED = 3
};

enum sonbal_openai_command_kind {
  SONBAL_OPENAI_COMMAND_JSONRPC = 1,
  SONBAL_OPENAI_COMMAND_SESSION_TERMINATION = 2,
  SONBAL_OPENAI_COMMAND_UNKNOWN = 3
};

struct sonbal_openai_configuration {
  char tunnel_id[SONBAL_OPENAI_MAX_TUNNEL_ID_BYTES + 1];
  size_t tunnel_id_length;
  uint32_t poll_limit;
  uint32_t poll_timeout_ms;
};

struct sonbal_openai_timeout {
  bool present;
  bool valid;
  uint64_t nanoseconds;
};

struct sonbal_openai_command {
  enum sonbal_openai_command_kind kind;

  char request_id[SONBAL_OPENAI_MAX_REQUEST_ID_BYTES + 1];
  size_t request_id_length;

  char shard_token[SONBAL_OPENAI_MAX_SHARD_TOKEN_BYTES + 1];
  size_t shard_token_length;

  char channel[SONBAL_OPENAI_MAX_CHANNEL_BYTES + 1];
  size_t channel_length;

  char created_at[SONBAL_OPENAI_MAX_CREATED_AT_BYTES + 1];
  size_t created_at_length;

  struct sonbal_openai_timeout response_timeout;

  const char *headers;
  size_t headers_length;

  const char *jsonrpc;
  size_t jsonrpc_length;
};

typedef bool (*sonbal_openai_command_callback)(
  const struct sonbal_openai_command *command,
  void *context);

enum sonbal_openai_protocol_status
sonbal_openai_parse_configuration(
  const char *json,
  size_t length,
  struct sonbal_openai_configuration *configuration);

enum sonbal_openai_protocol_status
sonbal_openai_parse_poll_response(
  const char *json,
  size_t length,
  size_t maximum_jsonrpc_bytes,
  sonbal_openai_command_callback callback,
  void *context,
  size_t *command_count);

bool
sonbal_openai_parse_response_timeout(
  const char *text,
  size_t length,
  uint64_t *nanoseconds);

#endif
