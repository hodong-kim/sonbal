/* =========================================================================
 * sonbal_connector_openai_protocol_test.c
 * Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
 * SPDX-License-Identifier: 0BSD
 * =========================================================================
 */
#include "sonbal_openai_protocol.h"

#include <stdio.h>
#include <string.h>

#define MAX_COLLECTED 8
#define MAX_RAW 2048

struct collected_command {
  struct sonbal_openai_command command;
  char raw[MAX_RAW];
  char raw_headers[MAX_RAW];
};

struct collector {
  struct collected_command items[MAX_COLLECTED];
  size_t count;
  size_t capacity;
};

static int failures = 0;

static void
check (bool condition, const char *message)
{
  if (condition)
    return;

  fprintf(stderr, "[FAIL] %s\n", message);
  failures++;
}

static bool
collect_command (
  const struct sonbal_openai_command *command,
  void *context)
{
  struct collector *collector = context;
  struct collected_command *target;

  if (collector->count >= collector->capacity ||
      collector->count >= MAX_COLLECTED)
    return false;

  target = &collector->items[collector->count++];
  memset(target, 0, sizeof *target);
  target->command = *command;

  if (command->jsonrpc_length > 0) {
    if (command->jsonrpc_length >= sizeof target->raw)
      return false;
    memcpy(target->raw, command->jsonrpc, command->jsonrpc_length);
    target->raw[command->jsonrpc_length] = '\0';
    target->command.jsonrpc = target->raw;
  }

  if (command->headers_length > 0) {
    if (command->headers_length >= sizeof target->raw_headers)
      return false;
    memcpy(
      target->raw_headers,
      command->headers,
      command->headers_length);
    target->raw_headers[command->headers_length] = '\0';
    target->command.headers = target->raw_headers;
  }

  return true;
}

static enum sonbal_openai_protocol_status
parse_poll (
  const char *json,
  size_t maximum_jsonrpc_bytes,
  struct collector *collector,
  size_t *count)
{
  memset(collector, 0, sizeof *collector);
  collector->capacity = MAX_COLLECTED;

  return sonbal_openai_parse_poll_response(
    json,
    strlen(json),
    maximum_jsonrpc_bytes,
    collect_command,
    collector,
    count);
}

static void
test_configuration (void)
{
  struct sonbal_openai_configuration configuration;
  enum sonbal_openai_protocol_status status;

  status = sonbal_openai_parse_configuration(
    "{\"tunnel_id\":\"tunnel_abc\"}",
    strlen("{\"tunnel_id\":\"tunnel_abc\"}"),
    &configuration);

  check(
    status == SONBAL_OPENAI_PROTOCOL_OK,
    "minimal OpenAI configuration rejected");
  check(
    strcmp(configuration.tunnel_id, "tunnel_abc") == 0,
    "tunnel id changed during configuration parse");
  check(
    configuration.poll_limit == SONBAL_OPENAI_DEFAULT_POLL_LIMIT,
    "default poll limit changed");
  check(
    configuration.poll_timeout_ms ==
      SONBAL_OPENAI_DEFAULT_POLL_TIMEOUT_MS,
    "default poll timeout changed");

  status = sonbal_openai_parse_configuration(
    "{\"tunnel_id\":\"opaque\",\"poll_limit\":7,"
    "\"poll_timeout_ms\":22000}",
    strlen(
      "{\"tunnel_id\":\"opaque\",\"poll_limit\":7,"
      "\"poll_timeout_ms\":22000}"),
    &configuration);

  check(
    status == SONBAL_OPENAI_PROTOCOL_OK,
    "bounded poll configuration rejected");
  check(
    configuration.poll_limit == 7 &&
      configuration.poll_timeout_ms == 22000,
    "bounded poll configuration changed");

  status = sonbal_openai_parse_configuration(
    "{\"poll_limit\":1}",
    strlen("{\"poll_limit\":1}"),
    &configuration);
  check(
    status == SONBAL_OPENAI_PROTOCOL_INVALID_ENVELOPE,
    "configuration without tunnel id was accepted");

  status = sonbal_openai_parse_configuration(
    "{\"tunnel_id\":\"x\",\"typo\":1}",
    strlen("{\"tunnel_id\":\"x\",\"typo\":1}"),
    &configuration);
  check(
    status == SONBAL_OPENAI_PROTOCOL_INVALID_ENVELOPE,
    "unknown configuration key was accepted");

  status = sonbal_openai_parse_configuration(
    "{\"tunnel_id\":\"x\",\"poll_limit\":26}",
    strlen("{\"tunnel_id\":\"x\",\"poll_limit\":26}"),
    &configuration);
  check(
    status == SONBAL_OPENAI_PROTOCOL_INVALID_ENVELOPE,
    "out-of-range poll limit was accepted");

  status = sonbal_openai_parse_configuration(
    "{\"tunnel_id\":\"x\",\"poll_timeout_ms\":600000}",
    strlen("{\"tunnel_id\":\"x\",\"poll_timeout_ms\":600000}"),
    &configuration);
  check(
    status == SONBAL_OPENAI_PROTOCOL_OK &&
      configuration.poll_timeout_ms == 600000,
    "maximum poll timeout was rejected");

  status = sonbal_openai_parse_configuration(
    "{\"tunnel_id\":\"x\",\"poll_timeout_ms\":600001}",
    strlen("{\"tunnel_id\":\"x\",\"poll_timeout_ms\":600001}"),
    &configuration);
  check(
    status == SONBAL_OPENAI_PROTOCOL_INVALID_ENVELOPE,
    "poll timeout above guardrail was accepted");

  status = sonbal_openai_parse_configuration(
    "{\"tunnel_id\":\"x\","
    "\"poll_timeout_ms\":184467440737095516160000}",
    strlen(
      "{\"tunnel_id\":\"x\","
      "\"poll_timeout_ms\":184467440737095516160000}"),
    &configuration);
  check(
    status == SONBAL_OPENAI_PROTOCOL_INVALID_ENVELOPE,
    "overflowing poll timeout was accepted");

  {
    char tunnel[SONBAL_OPENAI_MAX_TUNNEL_ID_BYTES + 2];
    char json[SONBAL_OPENAI_MAX_TUNNEL_ID_BYTES + 32];
    size_t index;

    for (index = 0; index < SONBAL_OPENAI_MAX_TUNNEL_ID_BYTES; index++)
      tunnel[index] = 'a';
    tunnel[SONBAL_OPENAI_MAX_TUNNEL_ID_BYTES] = '\0';

    snprintf(json, sizeof json, "{\"tunnel_id\":\"%s\"}", tunnel);
    status = sonbal_openai_parse_configuration(
      json, strlen(json), &configuration);
    check(
      status == SONBAL_OPENAI_PROTOCOL_OK &&
        configuration.tunnel_id_length ==
          SONBAL_OPENAI_MAX_TUNNEL_ID_BYTES,
      "maximum-length tunnel id was not preserved");

    tunnel[SONBAL_OPENAI_MAX_TUNNEL_ID_BYTES] = 'b';
    tunnel[SONBAL_OPENAI_MAX_TUNNEL_ID_BYTES + 1] = '\0';
    snprintf(json, sizeof json, "{\"tunnel_id\":\"%s\"}", tunnel);
    status = sonbal_openai_parse_configuration(
      json, strlen(json), &configuration);
    check(
      status == SONBAL_OPENAI_PROTOCOL_INVALID_ENVELOPE,
      "overlength tunnel id was accepted");
  }
}

static void
test_timeout (void)
{
  uint64_t nanoseconds = 0;

  check(
    sonbal_openai_parse_response_timeout(
      "0s", strlen("0s"), &nanoseconds) &&
      nanoseconds == 0,
    "zero response timeout rejected");

  check(
    sonbal_openai_parse_response_timeout(
      "4500ms", strlen("4500ms"), &nanoseconds) &&
      nanoseconds == UINT64_C(4500000000),
    "millisecond response timeout changed");

  check(
    sonbal_openai_parse_response_timeout(
      "2m", strlen("2m"), &nanoseconds) &&
      nanoseconds == UINT64_C(120000000000),
    "minute response timeout changed");

  check(
    !sonbal_openai_parse_response_timeout(
      "4.5s", strlen("4.5s"), &nanoseconds),
    "fractional response timeout was accepted");
  check(
    !sonbal_openai_parse_response_timeout(
      "-1s", strlen("-1s"), &nanoseconds),
    "signed response timeout was accepted");
  check(
    !sonbal_openai_parse_response_timeout(
      "1m30s", strlen("1m30s"), &nanoseconds),
    "compound response timeout was accepted");
  check(
    !sonbal_openai_parse_response_timeout(
      "18446744073709551615h",
      strlen("18446744073709551615h"),
      &nanoseconds),
    "overflowing response timeout was accepted");
}

static void
test_poll_commands (void)
{
  static const char jsonrpc[] =
    "{\"jsonrpc\":\"2.0\",\"id\":\"rpc_1\","
    "\"method\":\"tools/list\",\"params\":{}}";
  char poll[4096];
  struct collector collector;
  size_t count = 0;
  enum sonbal_openai_protocol_status status;

  snprintf(
    poll,
    sizeof poll,
    "{\"future_root\":{\"ignored\":true},\"commands\":["
    "{\"request_id\":\"req_1\","
    "\"shard_token\":\"shard_1\","
    "\"command_type\":\"jsonrpc\","
    "\"channel\":\"main\","
    "\"created_at\":\"2026-09-30T00:00:00Z\","
    "\"response_timeout\":\"30s\","
    "\"headers\":{\"Mcp-Session-Id\":[\"s1\",\"s2\"]},"
    "\"future_command\":[1,2,3],"
    "\"jsonrpc\":%s},"
    "{\"request_id\":\"req_2\","
    "\"shard_token\":\"shard_2\","
    "\"command_type\":\"session_termination\","
    "\"created_at\":\"2026-09-30T00:00:01Z\","
    "\"headers\":{\"Mcp-Session-Id\":[\"session_1\"]}}"
    "]}",
    jsonrpc);

  status = parse_poll(poll, 1024, &collector, &count);

  check(
    status == SONBAL_OPENAI_PROTOCOL_OK,
    "valid mixed poll envelope rejected");
  check(count == 2, "mixed poll command count changed");
  check(
    collector.items[0].command.kind ==
      SONBAL_OPENAI_COMMAND_JSONRPC,
    "jsonrpc command discriminator changed");
  check(
    strcmp(collector.items[0].raw, jsonrpc) == 0,
    "raw jsonrpc object was not preserved byte-exactly");
  check(
    strcmp(collector.items[0].command.request_id, "req_1") == 0 &&
      strcmp(
        collector.items[0].command.shard_token,
        "shard_1") == 0,
    "jsonrpc command correlation changed");
  check(
    strcmp(
      collector.items[0].command.created_at,
      "2026-09-30T00:00:00Z") == 0,
    "created_at metadata changed");
  check(
    strcmp(
      collector.items[0].raw_headers,
      "{\"Mcp-Session-Id\":[\"s1\",\"s2\"]}") == 0,
    "multi-valued headers object was not preserved byte-exactly");
  check(
    collector.items[0].command.response_timeout.present &&
      collector.items[0].command.response_timeout.valid &&
      collector.items[0].command.response_timeout.nanoseconds ==
        UINT64_C(30000000000),
    "valid command response timeout changed");
  check(
    collector.items[1].command.kind ==
      SONBAL_OPENAI_COMMAND_SESSION_TERMINATION,
    "session termination discriminator changed");
  check(
    strcmp(collector.items[1].command.channel, "main") == 0,
    "absent channel did not default to main");
  check(
    collector.items[1].command.jsonrpc_length == 0,
    "session termination acquired a jsonrpc payload");
}

static void
test_timeout_compatibility (void)
{
  struct collector collector;
  size_t count = 0;
  enum sonbal_openai_protocol_status status;

  status = parse_poll(
    "{\"commands\":["
    "{\"request_id\":\"a\",\"shard_token\":\"b\","
    "\"command_type\":\"jsonrpc\","
    "\"created_at\":\"2026-09-30T00:00:00Z\","
    "\"response_timeout\":\"4.5s\","
    "\"jsonrpc\":{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}},"
    "{\"request_id\":\"c\",\"shard_token\":\"d\","
    "\"command_type\":\"jsonrpc\","
    "\"created_at\":\"2026-09-30T00:00:01Z\","
    "\"response_timeout\":30,"
    "\"jsonrpc\":{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}},"
    "{\"request_id\":\"e\",\"shard_token\":\"f\","
    "\"command_type\":\"jsonrpc\","
    "\"created_at\":\"2026-09-30T00:00:02Z\","
    "\"response_timeout\":\"0s\","
    "\"jsonrpc\":{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"ping\"}}"
    "]}",
    1024,
    &collector,
    &count);

  check(
    status == SONBAL_OPENAI_PROTOCOL_OK && count == 3,
    "timeout compatibility poll rejected");
  check(
    collector.items[0].command.response_timeout.present &&
      !collector.items[0].command.response_timeout.valid,
    "malformed timeout did not fail open");
  check(
    collector.items[1].command.response_timeout.present &&
      !collector.items[1].command.response_timeout.valid,
    "wrong-type timeout did not fail open");
  check(
    collector.items[2].command.response_timeout.valid &&
      collector.items[2].command.response_timeout.nanoseconds == 0,
    "valid zero timeout lost immediate-expiry semantics");
}

static void
test_unknown_command (void)
{
  struct collector collector;
  size_t count = 0;
  enum sonbal_openai_protocol_status status;

  status = parse_poll(
    "{\"commands\":[{"
    "\"request_id\":\"req_unknown\","
    "\"shard_token\":\"opaque\","
    "\"command_type\":\"future_command\","
    "\"created_at\":\"2026-09-30T00:00:00Z\","
    "\"payload\":{\"jsonrpc\":{\"method\":\"must_not_dispatch\"}}"
    "}]}",
    1024,
    &collector,
    &count);

  check(
    status == SONBAL_OPENAI_PROTOCOL_OK && count == 1,
    "unknown future command rejected");
  check(
    collector.items[0].command.kind ==
      SONBAL_OPENAI_COMMAND_UNKNOWN,
    "unknown command was reinterpreted as a known command");
  check(
    collector.items[0].command.jsonrpc_length == 0,
    "unknown command exposed nested jsonrpc as dispatch payload");
}

static void
test_unicode_metadata (void)
{
  struct collector collector;
  size_t count = 0;
  enum sonbal_openai_protocol_status status;

  status = parse_poll(
    "{\"commands\":[{"
    "\"request_id\":\"req_\\u03a9\","
    "\"shard_token\":\"s\","
    "\"command_type\":\"jsonrpc\","
    "\"created_at\":\"2026-09-30T00:00:00Z\","
    "\"jsonrpc\":{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}"
    "}]}",
    1024,
    &collector,
    &count);

  check(
    status == SONBAL_OPENAI_PROTOCOL_OK && count == 1,
    "unicode metadata poll rejected");
  check(
    strcmp(
      collector.items[0].command.request_id,
      "req_\xce\xa9") == 0,
    "escaped unicode request id decoded incorrectly");
}

static void
test_rejections (void)
{
  struct collector collector;
  size_t count = 0;
  enum sonbal_openai_protocol_status status;

  status = parse_poll(
    "{\"commands\":[{"
    "\"request_id\":\"a\",\"shard_token\":\"b\","
    "\"created_at\":\"2026-09-30T00:00:00Z\","
    "\"jsonrpc\":{\"jsonrpc\":\"2.0\",\"method\":\"ping\"}"
    "}]}",
    1024,
    &collector,
    &count);
  check(
    status == SONBAL_OPENAI_PROTOCOL_OK &&
      count == 1 &&
      collector.items[0].command.kind ==
        SONBAL_OPENAI_COMMAND_JSONRPC,
    "default jsonrpc discriminator was not honored");

  status = parse_poll(
    "{\"commands\":[{"
    "\"request_id\":\"a\",\"shard_token\":\"b\","
    "\"command_type\":\"future\""
    "}]}",
    1024,
    &collector,
    &count);
  check(
    status == SONBAL_OPENAI_PROTOCOL_INVALID_ENVELOPE,
    "command without required created_at was accepted");

  status = parse_poll(
    "{\"commands\":[{"
    "\"request_id\":\"a\",\"shard_token\":\"b\","
    "\"command_type\":\"jsonrpc\","
    "\"created_at\":\"2026-09-30T00:00:00Z\""
    "}]}",
    1024,
    &collector,
    &count);
  check(
    status == SONBAL_OPENAI_PROTOCOL_INVALID_ENVELOPE,
    "jsonrpc command without jsonrpc object was accepted");

  status = parse_poll(
    "{\"commands\":[{"
    "\"request_id\":\"a\",\"request_id\":\"b\","
    "\"shard_token\":\"c\",\"command_type\":\"future\","
    "\"created_at\":\"2026-09-30T00:00:00Z\""
    "}]}",
    1024,
    &collector,
    &count);
  check(
    status == SONBAL_OPENAI_PROTOCOL_INVALID_ENVELOPE,
    "duplicate command correlation was accepted");

  status = parse_poll(
    "{\"commands\":[{"
    "\"request_id\":\"a\",\"shard_token\":\"b\","
    "\"command_type\":\"jsonrpc\","
    "\"created_at\":\"2026-09-30T00:00:00Z\","
    "\"jsonrpc\":{\"jsonrpc\":\"2.0\",\"method\":\"ping\"}"
    "}]}",
    16,
    &collector,
    &count);
  check(
    status == SONBAL_OPENAI_PROTOCOL_LIMIT_EXCEEDED,
    "oversized jsonrpc payload was accepted");

  status = parse_poll(
    "{\"commands\":[",
    1024,
    &collector,
    &count);
  check(
    status == SONBAL_OPENAI_PROTOCOL_INVALID_JSON,
    "truncated poll JSON was accepted");

  status = parse_poll(
    "{\"not_commands\":[]}",
    1024,
    &collector,
    &count);
  check(
    status == SONBAL_OPENAI_PROTOCOL_INVALID_ENVELOPE,
    "poll envelope without commands was accepted");
}

static void
test_callback_capacity (void)
{
  struct collector collector;
  size_t count = 0;
  enum sonbal_openai_protocol_status status;
  const char *poll =
    "{\"commands\":["
    "{\"request_id\":\"a\",\"shard_token\":\"b\","
    "\"command_type\":\"future\","
    "\"created_at\":\"2026-09-30T00:00:00Z\"},"
    "{\"request_id\":\"c\",\"shard_token\":\"d\","
    "\"command_type\":\"future\","
    "\"created_at\":\"2026-09-30T00:00:01Z\"}"
    "]}";

  memset(&collector, 0, sizeof collector);
  collector.capacity = 1;

  status = sonbal_openai_parse_poll_response(
    poll,
    strlen(poll),
    1024,
    collect_command,
    &collector,
    &count);

  check(
    status == SONBAL_OPENAI_PROTOCOL_LIMIT_EXCEEDED,
    "bounded command callback overflow was not rejected");
}

int
main (void)
{
  test_configuration();
  test_timeout();
  test_poll_commands();
  test_timeout_compatibility();
  test_unknown_command();
  test_unicode_metadata();
  test_rejections();
  test_callback_capacity();

  if (failures != 0) {
    fprintf(stderr, "%d OpenAI protocol test(s) failed\n", failures);
    return 1;
  }

  puts("[PASS] OpenAI connector bounded protocol core");
  return 0;
}
