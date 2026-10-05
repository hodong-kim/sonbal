/* =========================================================================
 * sonbal_connector_openai.c
 * Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
 * SPDX-License-Identifier: 0BSD
 * =========================================================================
 */
#define _POSIX_C_SOURCE 200809L

#include "sonbal_connector_abi.h"
#include "sonbal_openai_protocol.h"
#include "sonbal_openai_transport.h"

#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct openai_connector {
  struct sonbal_openai_configuration configuration;

  char credential[SONBAL_OPENAI_MAX_CREDENTIAL_BYTES + 1];
  size_t credential_length;

  uint32_t maximum_active_requests;
  uint32_t maximum_request_bytes;
  uint32_t maximum_response_bytes;

  int wakeup_read_fd;
  int wakeup_write_fd;

  struct sonbal_openai_transport *transport;

  bool started;
  bool stopping;
};

static void
secure_zero (void *address, size_t length)
{
  volatile unsigned char *bytes = address;

  while (length > 0) {
    *bytes++ = 0;
    length--;
  }
}

static int
set_nonblocking (int fd)
{
  int flags = fcntl(fd, F_GETFL, 0);

  if (flags < 0)
    return -1;

  return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static sonbal_connector_status_t
create_wakeup_pipe (struct openai_connector *state)
{
  int fds[2];

  if (pipe(fds) != 0)
    return SONBAL_CONNECTOR_STATUS_STARTUP_FAILED;

  if (set_nonblocking(fds[0]) != 0 ||
      set_nonblocking(fds[1]) != 0) {
    int saved_errno = errno;

    (void)close(fds[0]);
    (void)close(fds[1]);
    errno = saved_errno;
    return SONBAL_CONNECTOR_STATUS_STARTUP_FAILED;
  }

  state->wakeup_read_fd = fds[0];
  state->wakeup_write_fd = fds[1];
  return SONBAL_CONNECTOR_STATUS_OK;
}

static bool
drain_wakeup_pipe (struct openai_connector *state)
{
  unsigned char buffer[256];

  for (;;) {
    ssize_t count = read(
      state->wakeup_read_fd, buffer, sizeof buffer);

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

static sonbal_connector_status_t
transport_status (
  enum sonbal_openai_transport_status status)
{
  switch (status) {
    case SONBAL_OPENAI_TRANSPORT_OK:
      return SONBAL_CONNECTOR_STATUS_OK;
    case SONBAL_OPENAI_TRANSPORT_WOULD_BLOCK:
      return SONBAL_CONNECTOR_STATUS_WOULD_BLOCK;
    case SONBAL_OPENAI_TRANSPORT_INVALID_ARGUMENT:
      return SONBAL_CONNECTOR_STATUS_INVALID_ARGUMENT;
    case SONBAL_OPENAI_TRANSPORT_INVALID_STATE:
      return SONBAL_CONNECTOR_STATUS_INVALID_STATE;
    case SONBAL_OPENAI_TRANSPORT_RESOURCE_EXHAUSTED:
      return SONBAL_CONNECTOR_STATUS_RESOURCE_EXHAUSTED;
    case SONBAL_OPENAI_TRANSPORT_INTERNAL_ERROR:
      return SONBAL_CONNECTOR_STATUS_INTERNAL_ERROR;
  }

  return SONBAL_CONNECTOR_STATUS_INTERNAL_ERROR;
}

static sonbal_connector_status_t
read_bounded_file (
  int fd,
  char *buffer,
  size_t maximum,
  size_t *length)
{
  size_t used = 0;

  if (fd < 0 || buffer == NULL || length == NULL || maximum == 0)
    return SONBAL_CONNECTOR_STATUS_INVALID_ARGUMENT;

  for (;;) {
    ssize_t count;

    if (used == maximum) {
      unsigned char probe;

      do {
        count = read(fd, &probe, 1);
      } while (count < 0 && errno == EINTR);

      if (count > 0)
        return SONBAL_CONNECTOR_STATUS_RESOURCE_EXHAUSTED;
      if (count < 0)
        return SONBAL_CONNECTOR_STATUS_STARTUP_FAILED;
      break;
    }

    do {
      count = read(fd, buffer + used, maximum - used);
    } while (count < 0 && errno == EINTR);

    if (count < 0)
      return SONBAL_CONNECTOR_STATUS_STARTUP_FAILED;
    if (count == 0)
      break;

    used += (size_t)count;
  }

  *length = used;
  return SONBAL_CONNECTOR_STATUS_OK;
}

static sonbal_connector_status_t
load_configuration (
  int fd,
  struct sonbal_openai_configuration *configuration)
{
  char buffer[SONBAL_OPENAI_MAX_CONFIG_BYTES];
  size_t length = 0;
  enum sonbal_openai_protocol_status status;
  sonbal_connector_status_t read_status;

  read_status = read_bounded_file(
    fd, buffer, sizeof buffer, &length);
  if (read_status != SONBAL_CONNECTOR_STATUS_OK)
    return read_status;

  status = sonbal_openai_parse_configuration(
    buffer, length, configuration);
  secure_zero(buffer, sizeof buffer);

  if (status == SONBAL_OPENAI_PROTOCOL_LIMIT_EXCEEDED)
    return SONBAL_CONNECTOR_STATUS_RESOURCE_EXHAUSTED;
  if (status != SONBAL_OPENAI_PROTOCOL_OK)
    return SONBAL_CONNECTOR_STATUS_INVALID_ARGUMENT;

  return SONBAL_CONNECTOR_STATUS_OK;
}

static sonbal_connector_status_t
load_credential (
  int fd,
  char *credential,
  size_t capacity,
  size_t *credential_length)
{
  size_t length = 0;
  size_t index;
  sonbal_connector_status_t status;

  if (capacity < 2)
    return SONBAL_CONNECTOR_STATUS_INVALID_ARGUMENT;

  status = read_bounded_file(
    fd, credential, capacity - 1, &length);
  if (status != SONBAL_CONNECTOR_STATUS_OK)
    return status;

  while (length > 0 &&
         (credential[length - 1] == '\n' ||
          credential[length - 1] == '\r'))
    length--;

  if (length == 0)
    return SONBAL_CONNECTOR_STATUS_INVALID_ARGUMENT;

  for (index = 0; index < length; index++) {
    unsigned char byte = (unsigned char)credential[index];

    if (byte <= 0x20 || byte == 0x7f) {
      secure_zero(credential, capacity);
      return SONBAL_CONNECTOR_STATUS_INVALID_ARGUMENT;
    }
  }

  credential[length] = '\0';
  *credential_length = length;
  return SONBAL_CONNECTOR_STATUS_OK;
}

static void
release_state (struct openai_connector *state)
{
  if (state == NULL)
    return;

  if (state->transport != NULL)
    sonbal_openai_transport_destroy(&state->transport);

  if (state->wakeup_read_fd >= 0)
    (void)close(state->wakeup_read_fd);
  if (state->wakeup_write_fd >= 0)
    (void)close(state->wakeup_write_fd);

  secure_zero(state->credential, sizeof state->credential);
  secure_zero(&state->configuration, sizeof state->configuration);
  secure_zero(state, sizeof *state);
  free(state);
}

static sonbal_connector_status_t
openai_initialize (
  const struct sonbal_connector_initialize_parameters *parameters,
  void **instance,
  int *wakeup_fd)
{
  struct openai_connector *state = NULL;
  sonbal_connector_status_t status;

  if (parameters == NULL || instance == NULL || wakeup_fd == NULL)
    return SONBAL_CONNECTOR_STATUS_INVALID_ARGUMENT;

  *instance = NULL;
  *wakeup_fd = SONBAL_CONNECTOR_INVALID_STARTUP_FD;

  if (parameters->abi_version != SONBAL_CONNECTOR_ABI_VERSION ||
      parameters->struct_size != sizeof *parameters ||
      parameters->maximum_active_requests == 0 ||
      parameters->maximum_request_bytes == 0 ||
      parameters->maximum_response_bytes == 0 ||
      parameters->configuration_fd < 0 ||
      parameters->credential_fd < 0)
    return SONBAL_CONNECTOR_STATUS_INVALID_ARGUMENT;

  state = calloc(1, sizeof *state);
  if (state == NULL)
    return SONBAL_CONNECTOR_STATUS_RESOURCE_EXHAUSTED;

  state->wakeup_read_fd = -1;
  state->wakeup_write_fd = -1;

  status = load_configuration(
    parameters->configuration_fd, &state->configuration);
  if (status != SONBAL_CONNECTOR_STATUS_OK)
    goto fail;

  status = load_credential(
    parameters->credential_fd,
    state->credential,
    sizeof state->credential,
    &state->credential_length);
  if (status != SONBAL_CONNECTOR_STATUS_OK)
    goto fail;

  state->maximum_active_requests = parameters->maximum_active_requests;
  state->maximum_request_bytes = parameters->maximum_request_bytes;
  state->maximum_response_bytes = parameters->maximum_response_bytes;

  status = create_wakeup_pipe(state);
  if (status != SONBAL_CONNECTOR_STATUS_OK)
    goto fail;

  *instance = state;
  *wakeup_fd = state->wakeup_read_fd;
  return SONBAL_CONNECTOR_STATUS_OK;

fail:
  release_state(state);
  return status;
}

static sonbal_connector_status_t
openai_start (void *instance)
{
  struct openai_connector *state = instance;
  enum sonbal_openai_transport_status status;
#ifdef SONBAL_OPENAI_CONNECTOR_TESTING
  const char *base_url = getenv("SONBAL_OPENAI_TEST_BASE_URL");
#else
  const char *base_url = "https://api.openai.com";
#endif

  if (state == NULL || state->started || state->stopping)
    return SONBAL_CONNECTOR_STATUS_INVALID_STATE;

#ifdef SONBAL_OPENAI_CONNECTOR_TESTING
  if (base_url == NULL || base_url[0] == '\0')
    return SONBAL_CONNECTOR_STATUS_STARTUP_FAILED;
#endif

  status = sonbal_openai_transport_create(
    &state->transport,
    &state->configuration,
    base_url,
    state->credential,
    state->credential_length,
    state->maximum_active_requests,
    state->maximum_request_bytes,
    state->maximum_response_bytes,
    state->wakeup_write_fd);
  if (status != SONBAL_OPENAI_TRANSPORT_OK)
    return transport_status(status);

  status = sonbal_openai_transport_start(state->transport);
  if (status != SONBAL_OPENAI_TRANSPORT_OK) {
    sonbal_openai_transport_destroy(&state->transport);
    return transport_status(status);
  }

  state->started = true;
  state->stopping = false;
  return SONBAL_CONNECTOR_STATUS_OK;
}

static sonbal_connector_status_t
openai_next_event (
  void *instance,
  void *request_buffer,
  uint32_t request_capacity,
  void *correlation_buffer,
  uint32_t correlation_capacity,
  struct sonbal_connector_event *event)
{
  struct openai_connector *state = instance;

  if (state == NULL || event == NULL)
    return SONBAL_CONNECTOR_STATUS_INVALID_ARGUMENT;
  if (!state->started)
    return SONBAL_CONNECTOR_STATUS_INVALID_STATE;

  {
    enum sonbal_openai_transport_status status;

    if (!drain_wakeup_pipe(state))
      return SONBAL_CONNECTOR_STATUS_INTERNAL_ERROR;

    status = sonbal_openai_transport_next_event(
      state->transport,
      request_buffer,
      request_capacity,
      correlation_buffer,
      correlation_capacity,
      event);

    if (status == SONBAL_OPENAI_TRANSPORT_OK &&
        event->kind ==
          SONBAL_CONNECTOR_EVENT_SHUTDOWN_COMPLETE) {
      state->started = false;
    }

    return transport_status(status);
  }
}

static sonbal_connector_status_t
openai_complete_request (
  void *instance,
  sonbal_connector_request_token_t token,
  const void *response,
  uint32_t response_length)
{
  struct openai_connector *state = instance;

  if (state == NULL)
    return SONBAL_CONNECTOR_STATUS_INVALID_ARGUMENT;
  if (!state->started)
    return SONBAL_CONNECTOR_STATUS_INVALID_STATE;

  return transport_status(
    sonbal_openai_transport_complete(
      state->transport,
      token,
      response,
      response_length));
}

static sonbal_connector_status_t
openai_begin_shutdown (void *instance)
{
  struct openai_connector *state = instance;

  if (state == NULL)
    return SONBAL_CONNECTOR_STATUS_INVALID_ARGUMENT;
  if (!state->started)
    return SONBAL_CONNECTOR_STATUS_INVALID_STATE;
  if (state->stopping)
    return SONBAL_CONNECTOR_STATUS_OK;

  {
    enum sonbal_openai_transport_status status =
      sonbal_openai_transport_begin_shutdown(
        state->transport);

    if (status == SONBAL_OPENAI_TRANSPORT_OK)
      state->stopping = true;
    return transport_status(status);
  }
}

static sonbal_connector_status_t
openai_finalize (void **instance)
{
  struct openai_connector *state;

  if (instance == NULL || *instance == NULL)
    return SONBAL_CONNECTOR_STATUS_INVALID_ARGUMENT;

  state = *instance;
  if (state->started)
    return SONBAL_CONNECTOR_STATUS_INVALID_STATE;

  release_state(state);
  *instance = NULL;
  return SONBAL_CONNECTOR_STATUS_OK;
}

const struct sonbal_connector_descriptor sonbal_connector_descriptor_v1 = {
  SONBAL_CONNECTOR_ABI_MAGIC,
  SONBAL_CONNECTOR_ABI_VERSION,
  sizeof(struct sonbal_connector_descriptor),
  SONBAL_CONNECTOR_KIND_OPENAI,
  openai_initialize,
  openai_start,
  openai_next_event,
  openai_complete_request,
  openai_begin_shutdown,
  openai_finalize
};
