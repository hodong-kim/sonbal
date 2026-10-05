/* =========================================================================
 * sonbal_connector_openai_transport_test.c
 * Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
 * SPDX-License-Identifier: 0BSD
 * =========================================================================
 */
#define _POSIX_C_SOURCE 200809L

#include "sonbal_openai_transport.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static int failures = 0;

static void
check(bool condition, const char *message)
{
  if (condition)
    return;

  fprintf(stderr, "[FAIL] %s\n", message);
  failures++;
}

static bool
set_nonblocking(int fd)
{
  int flags = fcntl(fd, F_GETFL, 0);

  if (flags < 0)
    return false;

  return fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0;
}

static bool
wait_and_drain(int fd, int timeout_ms)
{
  struct pollfd item;
  unsigned char buffer[256];
  int status;

  memset(&item, 0, sizeof item);
  item.fd = fd;
  item.events = POLLIN;

  do {
    status = poll(&item, 1, timeout_ms);
  } while (status < 0 && errno == EINTR);

  if (status <= 0 || (item.revents & POLLIN) == 0)
    return false;

  for (;;) {
    ssize_t count = read(fd, buffer, sizeof buffer);

    if (count > 0)
      continue;
    if (count < 0 && errno == EINTR)
      continue;
    if (count < 0 &&
        (errno == EAGAIN || errno == EWOULDBLOCK))
      return true;
    return count == 0;
  }
}

int
main(int argc, char **argv)
{
  static const char credential[] = "test-secret";
  struct sonbal_openai_configuration configuration;
  struct sonbal_openai_transport *transport = NULL;
  struct sonbal_connector_event event;
  enum sonbal_openai_transport_status status;
  sonbal_connector_request_token_t first_token = 0;
  sonbal_connector_request_token_t live_token = 0;
  char request[4096];
  char correlation[256];
  int wakeup[2] = {-1, -1};

  if (argc != 2) {
    fprintf(stderr, "usage: %s BASE_URL\n", argv[0]);
    return 2;
  }

  memset(&configuration, 0, sizeof configuration);
  memcpy(
    configuration.tunnel_id,
    "deadline-test",
    sizeof "deadline-test");
  configuration.tunnel_id_length =
    sizeof "deadline-test" - 1;
  configuration.poll_limit = 25;
  configuration.poll_timeout_ms = 1000;

  check(pipe(wakeup) == 0, "cannot create transport wakeup pipe");
  if (failures != 0)
    goto done;

  check(
    set_nonblocking(wakeup[0]) &&
      set_nonblocking(wakeup[1]),
    "cannot make transport wakeup pipe nonblocking");
  if (failures != 0)
    goto done;

  status = sonbal_openai_transport_create(
    &transport,
    &configuration,
    argv[1],
    credential,
    strlen(credential),
    1,
    sizeof request,
    sizeof request,
    wakeup[1]);
  check(
    status == SONBAL_OPENAI_TRANSPORT_OK,
    "transport creation failed");
  if (status != SONBAL_OPENAI_TRANSPORT_OK)
    goto done;

  status = sonbal_openai_transport_start(transport);
  check(
    status == SONBAL_OPENAI_TRANSPORT_OK,
    "transport start failed");
  if (status != SONBAL_OPENAI_TRANSPORT_OK)
    goto done;

  check(
    wait_and_drain(wakeup[0], 3000),
    "deadline request did not signal progress");

  memset(&event, 0, sizeof event);
  memset(request, 0, sizeof request);
  memset(correlation, 0, sizeof correlation);

  status = sonbal_openai_transport_next_event(
    transport,
    request,
    sizeof request,
    correlation,
    sizeof correlation,
    &event);
  check(
    status == SONBAL_OPENAI_TRANSPORT_OK &&
      event.kind == SONBAL_CONNECTOR_EVENT_REQUEST,
    "deadline request was not published");
  check(event.token != 0, "deadline request token missing");
  check(
    event.request_length > 0 &&
      strstr(request, "\"method\":\"tools/call\"") != NULL,
    "deadline request payload changed");
  check(
    event.correlation_length == strlen("req_queue") &&
      memcmp(
        correlation,
        "req_queue",
        strlen("req_queue")) == 0,
    "first queued request correlation changed");

  first_token = event.token;

  memset(&event, 0, sizeof event);
  status = sonbal_openai_transport_next_event(
    transport,
    request,
    sizeof request,
    correlation,
    sizeof correlation,
    &event);
  check(
    status == SONBAL_OPENAI_TRANSPORT_WOULD_BLOCK,
    "provider queue bypassed the active execution limit");

  {
    struct timespec delay;

    delay.tv_sec = 0;
    delay.tv_nsec = 300000000L;
    (void)nanosleep(&delay, NULL);
  }

  status = sonbal_openai_transport_complete(
    transport,
    first_token,
    "{\"jsonrpc\":\"2.0\",\"id\":\"queue-ping\","
    "\"result\":{\"ok\":true}}",
    strlen(
      "{\"jsonrpc\":\"2.0\",\"id\":\"queue-ping\","
      "\"result\":{\"ok\":true}}"));
  check(
    status == SONBAL_OPENAI_TRANSPORT_OK,
    "first queued request completion was rejected");

  check(
    wait_and_drain(wakeup[0], 3000),
    "second queued request did not signal progress");

  memset(&event, 0, sizeof event);
  memset(request, 0, sizeof request);
  memset(correlation, 0, sizeof correlation);

  status = sonbal_openai_transport_next_event(
    transport,
    request,
    sizeof request,
    correlation,
    sizeof correlation,
    &event);
  check(
    status == SONBAL_OPENAI_TRANSPORT_OK &&
      event.kind == SONBAL_CONNECTOR_EVENT_REQUEST,
    "second queued request was not published");
  check(
    event.correlation_length == strlen("req_deadline") &&
      memcmp(
        correlation,
        "req_deadline",
        strlen("req_deadline")) == 0,
    "deadline request correlation changed");

  live_token = event.token;

  check(
    wait_and_drain(wakeup[0], 3000),
    "deadline expiry did not signal abandonment");

  status = sonbal_openai_transport_complete(
    transport,
    live_token,
    "{}",
    2);
  check(
    status == SONBAL_OPENAI_TRANSPORT_INVALID_STATE,
    "pending abandonment accepted a late completion");

  memset(&event, 0, sizeof event);
  status = sonbal_openai_transport_next_event(
    transport,
    request,
    sizeof request,
    correlation,
    sizeof correlation,
    &event);
  check(
    status == SONBAL_OPENAI_TRANSPORT_OK &&
      event.kind == SONBAL_CONNECTOR_EVENT_REQUEST_ABANDONED &&
      event.token == live_token,
    "late completion consumed the abandonment event");

  status = sonbal_openai_transport_complete(
    transport,
    live_token,
    "{}",
    2);
  check(
    status == SONBAL_OPENAI_TRANSPORT_INVALID_STATE,
    "retired abandoned token accepted a late completion");

  memset(&event, 0, sizeof event);
  memset(request, 0, sizeof request);
  memset(correlation, 0, sizeof correlation);
  status = sonbal_openai_transport_next_event(
    transport,
    request,
    sizeof request,
    correlation,
    sizeof correlation,
    &event);
  check(
    status == SONBAL_OPENAI_TRANSPORT_OK &&
      event.kind == SONBAL_CONNECTOR_EVENT_REQUEST,
    "capacity was not reusable after abandonment");
  check(
    event.correlation_length == strlen("req_after") &&
      memcmp(
        correlation,
        "req_after",
        strlen("req_after")) == 0,
    "queued expiry or capacity reuse ordering changed");

  status = sonbal_openai_transport_complete(
    transport,
    event.token,
    "{\"jsonrpc\":\"2.0\",\"id\":\"after-ping\","
    "\"result\":{\"ok\":true}}",
    strlen(
      "{\"jsonrpc\":\"2.0\",\"id\":\"after-ping\","
      "\"result\":{\"ok\":true}}"));
  check(
    status == SONBAL_OPENAI_TRANSPORT_OK,
    "post-abandonment request completion was rejected");

  {
    struct timespec delay;

    delay.tv_sec = 0;
    delay.tv_nsec = 250000000L;
    (void)nanosleep(&delay, NULL);
  }

  status = sonbal_openai_transport_begin_shutdown(transport);
  check(
    status == SONBAL_OPENAI_TRANSPORT_OK,
    "transport shutdown transition failed");

  {
    bool shutdown_complete = false;
    unsigned attempt;

    for (attempt = 0; attempt < 20; attempt++) {
      if (!wait_and_drain(wakeup[0], 250))
        continue;

      memset(&event, 0, sizeof event);
      status = sonbal_openai_transport_next_event(
        transport,
        request,
        sizeof request,
        correlation,
        sizeof correlation,
        &event);

      if (status == SONBAL_OPENAI_TRANSPORT_WOULD_BLOCK)
        continue;

      if (status == SONBAL_OPENAI_TRANSPORT_OK &&
          event.kind ==
            SONBAL_CONNECTOR_EVENT_SHUTDOWN_COMPLETE) {
        shutdown_complete = true;
        break;
      }

      check(false, "unexpected event during transport shutdown");
      break;
    }

    check(
      shutdown_complete,
      "transport shutdown completion event missing");
  }

done:
  sonbal_openai_transport_destroy(&transport);

  if (wakeup[0] >= 0)
    (void)close(wakeup[0]);
  if (wakeup[1] >= 0)
    (void)close(wakeup[1]);

  if (failures != 0) {
    fprintf(stderr, "%d OpenAI transport test(s) failed\n", failures);
    return 1;
  }

  puts("[PASS] OpenAI connector inflight deadline transport");
  return 0;
}
