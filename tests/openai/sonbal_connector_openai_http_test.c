/* =========================================================================
 * sonbal_connector_openai_http_test.c
 * Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
 * SPDX-License-Identifier: 0BSD
 * =========================================================================
 */
#define _POSIX_C_SOURCE 200809L

#include "sonbal_openai_http.h"

#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

static int failures = 0;

static void
check (bool condition, const char *message)
{
  if (condition)
    return;

  fprintf(stderr, "[FAIL] %s\n", message);
  failures++;
}

struct cancel_context {
  struct sonbal_openai_http_client *client;
};

static void *
cancel_after_delay (void *context)
{
  struct cancel_context *cancel = context;
  struct timespec delay;

  delay.tv_sec = 0;
  delay.tv_nsec = 100000000L;
  (void)nanosleep(&delay, NULL);

  sonbal_openai_http_cancel(cancel->client);
  return NULL;
}

int
main (int argc, char **argv)
{
  static const char credential[] = "test-secret";
  static const char credential_without_nul[] = {
    't', 'e', 's', 't', '-', 's', 'e', 'c', 'r', 'e', 't'
  };
  static const char response_json[] =
    "{\"request_id\":\"req_1\",\"channel\":\"main\","
    "\"resp_json\":{\"jsonrpc\":\"2.0\",\"id\":1,"
    "\"result\":{\"ok\":true}},"
    "\"resp_code\":200,\"resp_type\":\"jsonrpc_response\"}";
  static const char poll_body[] = "{\"commands\":[]}";

  struct sonbal_openai_http_client client;
  struct sonbal_openai_http_client invalid_client;
  struct sonbal_openai_http_client production_client;
  struct sonbal_openai_http_result result;
  struct cancel_context cancel;
  pthread_t cancel_thread;
  char body[4096];
  enum sonbal_openai_http_status status;

  if (argc != 2) {
    fprintf(stderr, "usage: %s BASE_URL\n", argv[0]);
    return 2;
  }

  status = sonbal_openai_http_initialize(
    &invalid_client,
    "http://example.com",
    "tunnel_test",
    credential,
    strlen(credential),
    "sonbal-test",
    "1");
  check(
    status == SONBAL_OPENAI_HTTP_INVALID_ARGUMENT,
    "non-loopback insecure base URL was accepted");

  status = sonbal_openai_http_initialize(
    &production_client,
    "https://api.openai.com",
    "tunnel_test",
    credential_without_nul,
    sizeof credential_without_nul,
    "sonbal-test",
    "1");
  check(
    status == SONBAL_OPENAI_HTTP_OK,
    "length-delimited credential required caller NUL storage");
  if (status == SONBAL_OPENAI_HTTP_OK)
    sonbal_openai_http_finalize(&production_client);

  status = sonbal_openai_http_initialize(
    &production_client,
    "https://api.openai.com",
    "tunnel_test",
    credential,
    strlen(credential),
    "sonbal-test",
    "1");
  check(
    status == SONBAL_OPENAI_HTTP_OK,
    "production OpenAI base URL was rejected");
  if (status == SONBAL_OPENAI_HTTP_OK)
    sonbal_openai_http_finalize(&production_client);

  status = sonbal_openai_http_initialize(
    &client,
    argv[1],
    "tunnel/opaque",
    credential,
    strlen(credential),
    "sonbal-test",
    "1");
  if (status != SONBAL_OPENAI_HTTP_OK) {
    fprintf(stderr, "[FAIL] HTTP client initialization failed: %d\n", status);
    return 1;
  }

  status = sonbal_openai_http_poll(
    &client, 7, 600001, body, sizeof body, &result);
  check(
    status == SONBAL_OPENAI_HTTP_INVALID_ARGUMENT,
    "poll timeout above HTTP guardrail reached transport");

  memset(body, 0, sizeof body);
  status = sonbal_openai_http_poll(
    &client, 7, 30000, body, sizeof body, &result);
  check(status == SONBAL_OPENAI_HTTP_OK, "poll 200 transport failed");
  check(result.response_code == 200, "poll 200 status changed");
  check(
    result.body_length == strlen(poll_body) &&
      memcmp(body, poll_body, strlen(poll_body)) == 0,
    "poll 200 body changed");
  check(
    result.headers_received_ns != 0,
    "poll response receipt timestamp missing");
  check(
    !result.retry_after_present &&
      !result.retry_after_valid &&
      result.retry_after_ms == 0,
    "absent Retry-After produced a retry hint");

  memset(body, 0, sizeof body);
  status = sonbal_openai_http_poll(
    &client, 7, 30000, body, sizeof body, &result);
  check(status == SONBAL_OPENAI_HTTP_OK, "poll 429 transport failed");
  check(result.response_code == 429, "poll 429 status changed");
  check(
    result.retry_after_present &&
      result.retry_after_valid &&
      result.retry_after_ms == 2000,
    "delta-seconds Retry-After was not preserved");

  memset(body, 0, sizeof body);
  status = sonbal_openai_http_poll(
    &client, 7, 30000, body, sizeof body, &result);
  check(status == SONBAL_OPENAI_HTTP_OK, "poll 503 transport failed");
  check(result.response_code == 503, "poll 503 status changed");
  check(
    result.retry_after_present &&
      result.retry_after_valid &&
      result.retry_after_ms > 0 &&
      result.retry_after_ms <= 5000,
    "HTTP-date Retry-After was not preserved");

  memset(body, 0, sizeof body);
  status = sonbal_openai_http_poll(
    &client, 7, 30000, body, sizeof body, &result);
  check(status == SONBAL_OPENAI_HTTP_OK, "poll 204 transport failed");
  check(result.response_code == 204, "poll 204 status changed");
  check(result.body_length == 0, "poll 204 unexpectedly had a body");
  check(
    result.headers_received_ns != 0,
    "poll 204 receipt timestamp missing");

  memset(body, 0, sizeof body);
  status = sonbal_openai_http_poll(
    &client, 7, 30000, body, 16, &result);
  check(
    status == SONBAL_OPENAI_HTTP_BODY_LIMIT,
    "oversized poll body did not fail boundedly");

  cancel.client = &client;
  check(
    pthread_create(
      &cancel_thread, NULL, cancel_after_delay, &cancel) == 0,
    "cannot create HTTP cancellation test thread");

  memset(body, 0, sizeof body);
  status = sonbal_openai_http_poll(
    &client, 7, 30000, body, sizeof body, &result);
  check(
    status == SONBAL_OPENAI_HTTP_CANCELLED,
    "in-flight poll cancellation did not surface");

  (void)pthread_join(cancel_thread, NULL);
  sonbal_openai_http_reset_cancellation(&client);

  status = sonbal_openai_http_post_response(
    &client,
    "opaque-shard-token",
    response_json,
    strlen(response_json),
    5000,
    body,
    sizeof body,
    &result);
  check(status == SONBAL_OPENAI_HTTP_OK, "response POST transport failed");
  check(result.response_code == 200, "response POST status changed");

  status = sonbal_openai_http_post_response(
    &client,
    "bad,token",
    response_json,
    strlen(response_json),
    5000,
    body,
    sizeof body,
    &result);
  check(
    status == SONBAL_OPENAI_HTTP_INVALID_ARGUMENT,
    "invalid shard token reached HTTP transport");

  sonbal_openai_http_finalize(&client);

  if (failures != 0) {
    fprintf(stderr, "%d OpenAI HTTP test(s) failed\n", failures);
    return 1;
  }

  puts("[PASS] OpenAI connector bounded HTTP primitive");
  return 0;
}
