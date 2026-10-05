/*
 * sonbal_connector_fake_plugin.c
 * Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
 * SPDX-License-Identifier: 0BSD
 */
#include "sonbal_connector_abi.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define PHASE_IDLE 0
#define PHASE_PING_REQUEST 1
#define PHASE_WAIT_PING 2
#define PHASE_ROTATE_PREPARE 3
#define PHASE_WAIT_ROTATE_PREPARE 4
#define PHASE_ROTATE_COMMIT 5
#define PHASE_WAIT_ROTATE_COMMIT 6
#define PHASE_RUN_REQUEST 7
#define PHASE_ABANDON_RUN 8
#define PHASE_DONE 9
#define PHASE_WAIT_RUN_SHUTDOWN 10
#define PHASE_ABANDON_PING 11
#define PHASE_NOTIFICATION_REQUEST 12
#define PHASE_WAIT_NOTIFICATION 13
#define PHASE_START_JOB_REQUEST 14
#define PHASE_WAIT_START_JOB 15

#define WATCH_FD_ENV "SONBAL_CONNECTOR_TEST_WATCH_FD"

#define MCP_META \
  "\"_meta\":{" \
  "\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\"," \
  "\"io.modelcontextprotocol/clientCapabilities\":{}," \
  "\"io.modelcontextprotocol/clientInfo\":{" \
  "\"name\":\"connector-fixture\",\"version\":\"1\"}}"

struct fake_state {
  int read_fd;
  int write_fd;
  char mode;
  int started;
  int stopping;
  int shutdown_published;
  unsigned phase;
  unsigned completion_attempts;
  unsigned finalize_attempts;
  sonbal_connector_request_token_t live_token;
  char operation_id[80];
  char workspace_token[128];
  char workspace_root[4096];
};

static int
set_nonblocking (int fd)
{
  int flags = fcntl(fd, F_GETFL, 0);
  if (flags < 0)
    return -1;
  return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static int
watch_fault_fd (void)
{
  const char *text = getenv(WATCH_FD_ENV);
  char *end = NULL;
  long value;

  if (text == NULL || *text == '\0')
    return -1;

  errno = 0;
  value = strtol(text, &end, 10);

  if (errno != 0 || end == text || *end != '\0' ||
      value < 0 || value > INT_MAX)
    return -1;

  return (int)value;
}

static char
read_mode (int fd)
{
  char value = 'G';
  ssize_t count;

  if (fd < 0)
    return value;

  count = read(fd, &value, 1);
  if (count == 1)
    return value;
  return 'G';
}

static int
signal_progress (struct fake_state *state)
{
  char marker = 'x';
  ssize_t count;

  count = write(state->write_fd, &marker, 1);
  if (count == 1)
    return 0;
  if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
    return 0;
  return -1;
}

static int
drain_progress (struct fake_state *state)
{
  char bytes[64];
  ssize_t count;

  for (;;) {
    count = read(state->read_fd, bytes, sizeof(bytes));
    if (count > 0)
      continue;
    if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
      return 0;
    if (count == 0)
      return -1;
    return -1;
  }
}

static int
copy_request (
  const char *request,
  void *request_buffer,
  uint32_t request_capacity,
  struct sonbal_connector_event *event,
  sonbal_connector_request_token_t token)
{
  size_t length = strlen(request);

  if (request_buffer == NULL || length > request_capacity)
    return -1;

  memcpy(request_buffer, request, length);
  event->token = token;
  event->kind = SONBAL_CONNECTOR_EVENT_REQUEST;
  event->request_length = (uint32_t)length;
  event->correlation_length = 0;
  event->correlation_truncated = 0;
  return 0;
}

static int
response_text (
  const void *response,
  uint32_t response_length,
  char *target,
  size_t target_size)
{
  if (response == NULL || response_length == 0 ||
      response_length >= target_size)
    return -1;

  memcpy(target, response, response_length);
  target[response_length] = '\0';
  return 0;
}

static int
extract_json_string (
  const char *text,
  const char *field,
  char *target,
  size_t target_size)
{
  char needle[96];
  const char *start;
  const char *finish;
  size_t length;

  if (snprintf(needle, sizeof(needle), "\"%s\":\"", field) < 0)
    return -1;

  start = strstr(text, needle);
  if (start == NULL)
    return -1;
  start += strlen(needle);

  finish = strchr(start, '"');
  if (finish == NULL)
    return -1;

  length = (size_t)(finish - start);
  if (length == 0 || length >= target_size)
    return -1;

  memcpy(target, start, length);
  target[length] = '\0';
  return 0;
}

static sonbal_connector_status_t
fake_initialize (
  const struct sonbal_connector_initialize_parameters *parameters,
  void **instance,
  int *wakeup_fd)
{
  struct fake_state *state;
  int fds[2];
  char mode;

  if (parameters == NULL || instance == NULL || wakeup_fd == NULL)
    return SONBAL_CONNECTOR_STATUS_INVALID_ARGUMENT;

  *instance = NULL;
  *wakeup_fd = SONBAL_CONNECTOR_INVALID_STARTUP_FD;

  if (parameters->abi_version != SONBAL_CONNECTOR_ABI_VERSION ||
      parameters->struct_size != sizeof(*parameters) ||
      parameters->maximum_active_requests == 0 ||
      parameters->maximum_request_bytes == 0 ||
      parameters->maximum_response_bytes == 0)
    return SONBAL_CONNECTOR_STATUS_INVALID_ARGUMENT;

  mode = read_mode(parameters->configuration_fd);
  if (mode == 'I')
    return SONBAL_CONNECTOR_STATUS_STARTUP_FAILED;

  state = calloc(1, sizeof(*state));
  if (state == NULL)
    return SONBAL_CONNECTOR_STATUS_RESOURCE_EXHAUSTED;

  if (getcwd(state->workspace_root, sizeof(state->workspace_root)) == NULL) {
    free(state);
    return SONBAL_CONNECTOR_STATUS_STARTUP_FAILED;
  }

  if (pipe(fds) != 0) {
    free(state);
    return SONBAL_CONNECTOR_STATUS_STARTUP_FAILED;
  }

  if (set_nonblocking(fds[0]) != 0 || set_nonblocking(fds[1]) != 0) {
    close(fds[0]);
    close(fds[1]);
    free(state);
    return SONBAL_CONNECTOR_STATUS_STARTUP_FAILED;
  }

  state->read_fd = fds[0];
  state->write_fd = fds[1];
  state->mode = mode;
  state->phase = PHASE_IDLE;
  *instance = state;
  *wakeup_fd = state->read_fd;

  if (mode == 'V') {
    *wakeup_fd = -2;
  } else if (mode == 'W') {
    int target_fd = watch_fault_fd();

    if (target_fd < 0) {
      close(state->read_fd);
      close(state->write_fd);
      free(state);
      *instance = NULL;
      *wakeup_fd = SONBAL_CONNECTOR_INVALID_STARTUP_FD;
      return SONBAL_CONNECTOR_STATUS_STARTUP_FAILED;
    }

    *wakeup_fd = target_fd;
  }

  return SONBAL_CONNECTOR_STATUS_OK;
}

static sonbal_connector_status_t
fake_start (void *instance)
{
  struct fake_state *state = instance;

  if (state == NULL || state->started || state->stopping)
    return SONBAL_CONNECTOR_STATUS_INVALID_STATE;

  if (state->mode == 'S')
    return SONBAL_CONNECTOR_STATUS_STARTUP_FAILED;

  state->started = 1;

  if (state->mode == 'R' || state->mode == 'B' || state->mode == 'X') {
    state->phase = PHASE_PING_REQUEST;
    if (signal_progress(state) != 0)
      return SONBAL_CONNECTOR_STATUS_INTERNAL_ERROR;
  } else if (state->mode == 'A' || state->mode == 'Q' ||
             state->mode == 'J') {
    state->phase = PHASE_ROTATE_PREPARE;
    if (signal_progress(state) != 0)
      return SONBAL_CONNECTOR_STATUS_INTERNAL_ERROR;
  } else if (state->mode == 'N') {
    state->phase = PHASE_NOTIFICATION_REQUEST;
    if (signal_progress(state) != 0)
      return SONBAL_CONNECTOR_STATUS_INTERNAL_ERROR;
  }

  return SONBAL_CONNECTOR_STATUS_OK;
}

static sonbal_connector_status_t
fake_next_event (
  void *instance,
  void *request_buffer,
  uint32_t request_capacity,
  void *correlation_buffer,
  uint32_t correlation_capacity,
  struct sonbal_connector_event *event)
{
  struct fake_state *state = instance;
  char request[4096];
  int length;

  (void)correlation_buffer;
  (void)correlation_capacity;

  if (state == NULL || event == NULL)
    return SONBAL_CONNECTOR_STATUS_INVALID_ARGUMENT;

  memset(event, 0, sizeof(*event));

  if (drain_progress(state) != 0)
    return SONBAL_CONNECTOR_STATUS_INTERNAL_ERROR;

  if (state->stopping && state->live_token == 0 &&
      state->phase != PHASE_PING_REQUEST &&
      state->phase != PHASE_ROTATE_PREPARE &&
      state->phase != PHASE_ROTATE_COMMIT &&
      state->phase != PHASE_RUN_REQUEST &&
      state->phase != PHASE_ABANDON_RUN &&
      state->phase != PHASE_NOTIFICATION_REQUEST &&
      state->phase != PHASE_START_JOB_REQUEST &&
      !state->shutdown_published) {
    state->shutdown_published = 1;
    event->kind = SONBAL_CONNECTOR_EVENT_SHUTDOWN_COMPLETE;
    return SONBAL_CONNECTOR_STATUS_OK;
  }

  switch (state->phase) {
  case PHASE_PING_REQUEST:
    length = snprintf(
      request,
      sizeof(request),
      "{\"jsonrpc\":\"2.0\",\"id\":\"connector-ping\","
      "\"method\":\"tools/call\",\"params\":{"
      MCP_META ",\"name\":\"ping\",\"arguments\":{}}}");
    if (length < 0 || (size_t)length >= sizeof(request) ||
        copy_request(
          request, request_buffer, request_capacity, event, UINT64_C(1)) != 0)
      return SONBAL_CONNECTOR_STATUS_INTERNAL_ERROR;
    state->live_token = UINT64_C(1);
    state->phase = PHASE_WAIT_PING;
    return SONBAL_CONNECTOR_STATUS_OK;

  case PHASE_ROTATE_PREPARE:
    length = snprintf(
      request,
      sizeof(request),
      "{\"jsonrpc\":\"2.0\",\"id\":\"prepare\","
      "\"method\":\"tools/call\",\"params\":{"
      MCP_META ",\"name\":\"rotate_workspace_token\","
      "\"arguments\":{\"root\":\"%s\"}}}",
      state->workspace_root);
    if (length < 0 || (size_t)length >= sizeof(request) ||
        copy_request(
          request, request_buffer, request_capacity, event, UINT64_C(1)) != 0)
      return SONBAL_CONNECTOR_STATUS_INTERNAL_ERROR;
    state->live_token = UINT64_C(1);
    state->phase = PHASE_WAIT_ROTATE_PREPARE;
    return SONBAL_CONNECTOR_STATUS_OK;

  case PHASE_ROTATE_COMMIT:
    length = snprintf(
      request,
      sizeof(request),
      "{\"jsonrpc\":\"2.0\",\"id\":\"commit\","
      "\"method\":\"tools/call\",\"params\":{"
      MCP_META ",\"name\":\"rotate_workspace_token\","
      "\"arguments\":{\"root\":\"%s\",\"operation_id\":\"%s\"}}}",
      state->workspace_root,
      state->operation_id);
    if (length < 0 || (size_t)length >= sizeof(request) ||
        copy_request(
          request, request_buffer, request_capacity, event, UINT64_C(2)) != 0)
      return SONBAL_CONNECTOR_STATUS_INTERNAL_ERROR;
    state->live_token = UINT64_C(2);
    state->phase = PHASE_WAIT_ROTATE_COMMIT;
    return SONBAL_CONNECTOR_STATUS_OK;

  case PHASE_RUN_REQUEST:
    length = snprintf(
      request,
      sizeof(request),
      "{\"jsonrpc\":\"2.0\",\"id\":\"run\","
      "\"method\":\"tools/call\",\"params\":{"
      MCP_META ",\"name\":\"run_process\",\"arguments\":{"
      "\"workspace_token\":\"%s\","
      "\"argv\":[\"/bin/sleep\",\"30\"],"
      "\"resolution\":\"exact_path\",\"cwd\":\"%s\","
      "\"timeout_ms\":30000}}}",
      state->workspace_token,
      state->workspace_root);
    if (length < 0 || (size_t)length >= sizeof(request) ||
        copy_request(
          request, request_buffer, request_capacity, event, UINT64_C(3)) != 0)
      return SONBAL_CONNECTOR_STATUS_INTERNAL_ERROR;
    state->live_token = UINT64_C(3);
    state->phase =
      state->mode == 'A' ? PHASE_ABANDON_RUN : PHASE_WAIT_RUN_SHUTDOWN;
    return SONBAL_CONNECTOR_STATUS_OK;

  case PHASE_ABANDON_RUN:
    event->token = UINT64_C(3);
    event->kind = SONBAL_CONNECTOR_EVENT_REQUEST_ABANDONED;
    state->live_token = 0;
    state->phase = PHASE_DONE;
    return SONBAL_CONNECTOR_STATUS_OK;

  case PHASE_ABANDON_PING:
    event->token = UINT64_C(1);
    event->kind = SONBAL_CONNECTOR_EVENT_REQUEST_ABANDONED;
    state->live_token = 0;
    state->phase = PHASE_DONE;
    return SONBAL_CONNECTOR_STATUS_OK;

  case PHASE_NOTIFICATION_REQUEST:
    length = snprintf(
      request,
      sizeof(request),
      "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\","
      "\"params\":{}}");
    if (length < 0 || (size_t)length >= sizeof(request) ||
        copy_request(
          request, request_buffer, request_capacity, event, UINT64_C(1)) != 0)
      return SONBAL_CONNECTOR_STATUS_INTERNAL_ERROR;
    state->live_token = UINT64_C(1);
    state->phase = PHASE_WAIT_NOTIFICATION;
    return SONBAL_CONNECTOR_STATUS_OK;

  case PHASE_START_JOB_REQUEST:
    length = snprintf(
      request,
      sizeof(request),
      "{\"jsonrpc\":\"2.0\",\"id\":\"start-job\","
      "\"method\":\"tools/call\",\"params\":{"
      MCP_META ",\"name\":\"start_process\",\"arguments\":{"
      "\"workspace_token\":\"%s\","
      "\"argv\":[\"/bin/sleep\",\"30\"],"
      "\"resolution\":\"exact_path\",\"cwd\":\"%s\","
      "\"timeout_ms\":30000}}}",
      state->workspace_token,
      state->workspace_root);
    if (length < 0 || (size_t)length >= sizeof(request) ||
        copy_request(
          request, request_buffer, request_capacity, event, UINT64_C(3)) != 0)
      return SONBAL_CONNECTOR_STATUS_INTERNAL_ERROR;
    state->live_token = UINT64_C(3);
    state->phase = PHASE_WAIT_START_JOB;
    return SONBAL_CONNECTOR_STATUS_OK;

  default:
    return SONBAL_CONNECTOR_STATUS_WOULD_BLOCK;
  }
}

static sonbal_connector_status_t
fake_complete_request (
  void *instance,
  sonbal_connector_request_token_t token,
  const void *response,
  uint32_t response_length)
{
  struct fake_state *state = instance;
  char text[4096];

  if (state == NULL || token == 0 || token != state->live_token)
    return SONBAL_CONNECTOR_STATUS_INVALID_ARGUMENT;

  if ((state->mode == 'B' || state->mode == 'X') &&
      state->phase == PHASE_WAIT_PING &&
      state->completion_attempts == 0) {
    state->completion_attempts++;
    if (state->mode == 'X')
      state->phase = PHASE_ABANDON_PING;
    if (signal_progress(state) != 0)
      return SONBAL_CONNECTOR_STATUS_INTERNAL_ERROR;
    return SONBAL_CONNECTOR_STATUS_WOULD_BLOCK;
  }

  if (state->phase == PHASE_ABANDON_PING)
    return SONBAL_CONNECTOR_STATUS_INVALID_STATE;

  if (state->phase == PHASE_WAIT_NOTIFICATION) {
    if (response != NULL || response_length != 0)
      return SONBAL_CONNECTOR_STATUS_INTERNAL_ERROR;
    state->live_token = 0;
    state->phase = PHASE_DONE;
    return SONBAL_CONNECTOR_STATUS_OK;
  }

  if (response_text(response, response_length, text, sizeof(text)) != 0)
    return SONBAL_CONNECTOR_STATUS_INTERNAL_ERROR;

  if (state->phase == PHASE_WAIT_PING) {
    if (strstr(text, "\"id\":\"connector-ping\"") == NULL ||
        strstr(text, "\"isError\":false") == NULL)
      return SONBAL_CONNECTOR_STATUS_INTERNAL_ERROR;
    state->live_token = 0;
    state->phase = PHASE_DONE;
    return SONBAL_CONNECTOR_STATUS_OK;
  }

  if (state->phase == PHASE_WAIT_ROTATE_PREPARE) {
    if (extract_json_string(
          text,
          "operation_id",
          state->operation_id,
          sizeof(state->operation_id)) != 0)
      return SONBAL_CONNECTOR_STATUS_INTERNAL_ERROR;
    state->live_token = 0;
    state->phase = PHASE_ROTATE_COMMIT;
    if (signal_progress(state) != 0)
      return SONBAL_CONNECTOR_STATUS_INTERNAL_ERROR;
    return SONBAL_CONNECTOR_STATUS_OK;
  }

  if (state->phase == PHASE_WAIT_ROTATE_COMMIT) {
    if (extract_json_string(
          text,
          "workspace_token",
          state->workspace_token,
          sizeof(state->workspace_token)) != 0)
      return SONBAL_CONNECTOR_STATUS_INTERNAL_ERROR;
    state->live_token = 0;
    state->phase =
      state->mode == 'J' ? PHASE_START_JOB_REQUEST : PHASE_RUN_REQUEST;
    if (signal_progress(state) != 0)
      return SONBAL_CONNECTOR_STATUS_INTERNAL_ERROR;
    return SONBAL_CONNECTOR_STATUS_OK;
  }

  if (state->phase == PHASE_WAIT_RUN_SHUTDOWN) {
    if (strstr(text, "\"id\":\"run\"") == NULL)
      return SONBAL_CONNECTOR_STATUS_INTERNAL_ERROR;
    state->live_token = 0;
    state->phase = PHASE_DONE;
    if (state->stopping && signal_progress(state) != 0)
      return SONBAL_CONNECTOR_STATUS_INTERNAL_ERROR;
    return SONBAL_CONNECTOR_STATUS_OK;
  }

  if (state->phase == PHASE_WAIT_START_JOB) {
    if (strstr(text, "\"id\":\"start-job\"") == NULL ||
        strstr(text, "\"status\":\"running\"") == NULL)
      return SONBAL_CONNECTOR_STATUS_INTERNAL_ERROR;
    state->live_token = 0;
    state->phase = PHASE_DONE;
    return SONBAL_CONNECTOR_STATUS_OK;
  }

  return SONBAL_CONNECTOR_STATUS_INVALID_STATE;
}

static sonbal_connector_status_t
fake_begin_shutdown (void *instance)
{
  struct fake_state *state = instance;

  if (state == NULL || !state->started || state->stopping)
    return SONBAL_CONNECTOR_STATUS_INVALID_STATE;

  state->stopping = 1;
  if (signal_progress(state) != 0) {
    state->stopping = 0;
    return SONBAL_CONNECTOR_STATUS_INTERNAL_ERROR;
  }

  return SONBAL_CONNECTOR_STATUS_OK;
}

static sonbal_connector_status_t
fake_finalize (void **instance)
{
  struct fake_state *state;

  if (instance == NULL || *instance == NULL)
    return SONBAL_CONNECTOR_STATUS_INVALID_ARGUMENT;

  state = *instance;
  if (state->mode == 'F')
    return SONBAL_CONNECTOR_STATUS_INTERNAL_ERROR;

  if (state->mode == 'Y' && state->finalize_attempts++ == 0)
    return SONBAL_CONNECTOR_STATUS_INTERNAL_ERROR;

  if (state->started && !state->shutdown_published)
    return SONBAL_CONNECTOR_STATUS_INVALID_STATE;

  close(state->read_fd);
  close(state->write_fd);
  free(state);
  *instance = NULL;
  return SONBAL_CONNECTOR_STATUS_OK;
}

const struct sonbal_connector_descriptor sonbal_connector_descriptor_v1 = {
  SONBAL_CONNECTOR_ABI_MAGIC,
  SONBAL_CONNECTOR_ABI_VERSION,
  sizeof(struct sonbal_connector_descriptor),
  SONBAL_CONNECTOR_KIND_OPENAI,
  fake_initialize,
  fake_start,
  fake_next_event,
  fake_complete_request,
  fake_begin_shutdown,
  fake_finalize
};
