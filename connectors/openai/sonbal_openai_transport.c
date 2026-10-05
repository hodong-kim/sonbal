/* =========================================================================
 * sonbal_openai_transport.c
 * Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
 * SPDX-License-Identifier: 0BSD
 * =========================================================================
 */
#define _POSIX_C_SOURCE 200809L

#include "sonbal_openai_transport.h"

#include "sonbal_openai_http.h"

#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define POLL_COMMAND_OVERHEAD_BYTES ((size_t)4096)
#define POST_ENVELOPE_OVERHEAD_BYTES ((size_t)8192)
#define CONTROL_RESPONSE_BYTES ((size_t)4096)
#define POST_TIMEOUT_MS UINT32_C(30000)
#define RETRY_BASE_MS UINT64_C(100)
#define RETRY_MAX_LOCAL_MS UINT64_C(5000)
#define RETRY_MAX_DELAY_MS UINT64_C(30000)

enum slot_state {
  SLOT_FREE = 0,
  SLOT_STAGING_JSONRPC,
  SLOT_STAGING_SESSION,
  SLOT_QUEUED,
  SLOT_PREFETCH_OVERFLOW,
  SLOT_INFLIGHT,
  SLOT_RESPONSE_PENDING,
  SLOT_SESSION_ACK_PENDING,
  SLOT_ABANDON_PENDING,
  SLOT_POSTING
};

struct command_slot {
  enum slot_state state;
  sonbal_connector_request_token_t token;

  char request_id[SONBAL_OPENAI_MAX_REQUEST_ID_BYTES + 1];
  size_t request_id_length;

  char shard_token[SONBAL_OPENAI_MAX_SHARD_TOKEN_BYTES + 1];
  size_t shard_token_length;

  char channel[SONBAL_OPENAI_MAX_CHANNEL_BYTES + 1];
  size_t channel_length;

  char *request;
  size_t request_length;

  char *response;
  size_t response_length;

  bool deadline_valid;
  uint64_t deadline_ns;
};

struct sonbal_openai_transport {
  struct sonbal_openai_configuration configuration;
  struct sonbal_openai_http_client http;
  bool http_initialized;

  pthread_mutex_t lock;
  pthread_cond_t condition;
  pthread_cond_t deadline_condition;
  bool lock_initialized;
  bool condition_initialized;
  bool deadline_condition_initialized;

  pthread_t worker;
  bool worker_created;
  bool worker_exited;

  pthread_t deadline_monitor;
  bool deadline_monitor_created;
  bool deadline_monitor_ready;
  bool deadline_monitor_exited;

  struct command_slot *slots;
  size_t slot_count;

  char *poll_body;
  size_t poll_body_capacity;

  char *post_body;
  size_t post_body_capacity;

  uint32_t maximum_active_requests;
  uint32_t maximum_request_bytes;
  uint32_t maximum_response_bytes;
  int wakeup_write_fd;

  sonbal_connector_request_token_t next_token;
  uint64_t random_state;

  bool started;
  bool stopping;
  bool fatal_pending;
  bool fatal_reported;
  bool shutdown_reported;
};

struct batch_context {
  struct sonbal_openai_transport *transport;
  uint64_t receipt_ns;
};

enum post_result {
  POST_OK = 0,
  POST_EXPIRED,
  POST_FAILED
};

enum retry_wait_result {
  RETRY_READY = 0,
  RETRY_STOPPED,
  RETRY_EXPIRED,
  RETRY_FAILED
};

static void
secure_zero(void *address, size_t length)
{
  volatile unsigned char *bytes = address;

  while (length > 0) {
    *bytes++ = 0;
    length--;
  }
}

static bool
monotonic_now_ns(uint64_t *value)
{
  struct timespec now;
  uint64_t seconds;

  if (value == NULL ||
      clock_gettime(CLOCK_MONOTONIC, &now) != 0 ||
      now.tv_sec < 0 ||
      now.tv_nsec < 0 ||
      now.tv_nsec >= 1000000000L)
    return false;

  seconds = (uint64_t)now.tv_sec;
  if (seconds > UINT64_MAX / UINT64_C(1000000000))
    return false;

  *value =
    seconds * UINT64_C(1000000000) + (uint64_t)now.tv_nsec;
  return true;
}

static uint64_t
saturating_add_u64(uint64_t left, uint64_t right)
{
  if (right > UINT64_MAX - left)
    return UINT64_MAX;

  return left + right;
}

static void
timespec_from_ns(uint64_t nanoseconds, struct timespec *value)
{
  value->tv_sec =
    (time_t)(nanoseconds / UINT64_C(1000000000));
  value->tv_nsec =
    (long)(nanoseconds % UINT64_C(1000000000));
}

static uint64_t
next_random(struct sonbal_openai_transport *transport)
{
  uint64_t value = transport->random_state;

  if (value == 0)
    value = UINT64_C(0x9e3779b97f4a7c15);

  value ^= value << 13;
  value ^= value >> 7;
  value ^= value << 17;
  transport->random_state = value;
  return value;
}

static uint64_t
retry_delay_ms(
  struct sonbal_openai_transport *transport,
  unsigned attempt,
  uint64_t retry_after_ms)
{
  uint64_t local = RETRY_BASE_MS;
  uint64_t jitter;
  unsigned shifts = attempt;

  while (shifts > 0 && local < RETRY_MAX_LOCAL_MS) {
    if (local > RETRY_MAX_LOCAL_MS / 2) {
      local = RETRY_MAX_LOCAL_MS;
      break;
    }

    local *= 2;
    shifts--;
  }

  if (local > RETRY_MAX_LOCAL_MS)
    local = RETRY_MAX_LOCAL_MS;

  jitter = next_random(transport) % (local / 4 + 1);
  if (jitter > RETRY_MAX_DELAY_MS - local)
    local = RETRY_MAX_DELAY_MS;
  else
    local += jitter;

  if (retry_after_ms > RETRY_MAX_DELAY_MS)
    retry_after_ms = RETRY_MAX_DELAY_MS;
  if (retry_after_ms > local)
    local = retry_after_ms;

  return local;
}

static bool
signal_wakeup(struct sonbal_openai_transport *transport)
{
  unsigned char byte = 1;
  ssize_t count;

  if (transport == NULL || transport->wakeup_write_fd < 0)
    return false;

  do {
    count = write(transport->wakeup_write_fd, &byte, 1);
  } while (count < 0 && errno == EINTR);

  if (count == 1)
    return true;

  return count < 0 &&
    (errno == EAGAIN || errno == EWOULDBLOCK);
}

static void
notify_state_change_locked(
  struct sonbal_openai_transport *transport)
{
  if (transport->condition_initialized)
    (void)pthread_cond_broadcast(&transport->condition);
  if (transport->deadline_condition_initialized)
    (void)pthread_cond_broadcast(
      &transport->deadline_condition);
}

static void
clear_slot(struct command_slot *slot)
{
  if (slot == NULL)
    return;

  if (slot->request != NULL) {
    secure_zero(slot->request, slot->request_length);
    free(slot->request);
  }

  if (slot->response != NULL) {
    secure_zero(slot->response, slot->response_length);
    free(slot->response);
  }

  secure_zero(slot, sizeof *slot);
  slot->state = SLOT_FREE;
}

static bool
slot_expired(
  const struct command_slot *slot,
  uint64_t now)
{
  return slot->deadline_valid && now >= slot->deadline_ns;
}

static size_t
queued_request_count_locked(
  const struct sonbal_openai_transport *transport)
{
  size_t index;
  size_t count = 0;

  for (index = 0; index < transport->slot_count; index++) {
    if (transport->slots[index].state == SLOT_QUEUED)
      count++;
  }

  return count;
}

static bool
promote_prefetch_overflow_locked(
  struct sonbal_openai_transport *transport)
{
  size_t index;
  size_t queued = queued_request_count_locked(transport);
  bool wake = false;

  if (queued >=
      (size_t)SONBAL_OPENAI_PROVIDER_QUEUE_CAPACITY)
    return false;

  for (index = 0; index < transport->slot_count; index++) {
    struct command_slot *slot = &transport->slots[index];

    if (slot->state != SLOT_PREFETCH_OVERFLOW)
      continue;

    slot->state = SLOT_QUEUED;
    queued++;
    wake = true;

    if (queued >=
        (size_t)SONBAL_OPENAI_PROVIDER_QUEUE_CAPACITY)
      break;
  }

  return wake;
}

static bool
expire_slots_locked(
  struct sonbal_openai_transport *transport,
  uint64_t now)
{
  size_t index;
  bool changed = false;
  bool wake = false;

  for (index = 0; index < transport->slot_count; index++) {
    struct command_slot *slot = &transport->slots[index];

    if (!slot_expired(slot, now))
      continue;

    switch (slot->state) {
      case SLOT_STAGING_JSONRPC:
      case SLOT_STAGING_SESSION:
      case SLOT_QUEUED:
      case SLOT_PREFETCH_OVERFLOW:
      case SLOT_RESPONSE_PENDING:
      case SLOT_SESSION_ACK_PENDING:
        clear_slot(slot);
        changed = true;
        break;

      case SLOT_INFLIGHT:
        slot->state = SLOT_ABANDON_PENDING;
        changed = true;
        wake = true;
        break;

      case SLOT_FREE:
      case SLOT_ABANDON_PENDING:
      case SLOT_POSTING:
        break;
    }
  }

  if (promote_prefetch_overflow_locked(transport)) {
    changed = true;
    wake = true;
  }

  if (wake)
    (void)signal_wakeup(transport);

  return changed;
}

static bool
refresh_deadlines_locked(
  struct sonbal_openai_transport *transport)
{
  uint64_t now;

  if (!monotonic_now_ns(&now))
    return false;

  if (expire_slots_locked(transport, now))
    notify_state_change_locked(transport);

  return true;
}

static bool
nearest_deadline_locked(
  const struct sonbal_openai_transport *transport,
  uint64_t *deadline)
{
  size_t index;
  bool found = false;
  uint64_t value = UINT64_MAX;

  for (index = 0; index < transport->slot_count; index++) {
    const struct command_slot *slot = &transport->slots[index];

    if (!slot->deadline_valid)
      continue;

    switch (slot->state) {
      case SLOT_QUEUED:
      case SLOT_PREFETCH_OVERFLOW:
      case SLOT_INFLIGHT:
      case SLOT_RESPONSE_PENDING:
      case SLOT_SESSION_ACK_PENDING:
        if (!found || slot->deadline_ns < value) {
          value = slot->deadline_ns;
          found = true;
        }
        break;

      case SLOT_FREE:
      case SLOT_STAGING_JSONRPC:
      case SLOT_STAGING_SESSION:
      case SLOT_ABANDON_PENDING:
      case SLOT_POSTING:
        break;
    }
  }

  if (found)
    *deadline = value;
  return found;
}

static size_t
active_request_count_locked(
  const struct sonbal_openai_transport *transport)
{
  size_t index;
  size_t count = 0;

  for (index = 0; index < transport->slot_count; index++) {
    if (transport->slots[index].state == SLOT_INFLIGHT ||
        transport->slots[index].state == SLOT_ABANDON_PENDING)
      count++;
  }

  return count;
}

static bool
can_publish_request_locked(
  const struct sonbal_openai_transport *transport)
{
  size_t index;

  if (active_request_count_locked(transport) >=
      transport->maximum_active_requests)
    return false;

  for (index = 0; index < transport->slot_count; index++) {
    if (transport->slots[index].state == SLOT_QUEUED)
      return true;
  }

  return false;
}

static uint32_t
poll_request_limit(
  const struct sonbal_openai_transport *transport)
{
  uint32_t limit = transport->configuration.poll_limit;

  if (limit > SONBAL_OPENAI_PROVIDER_QUEUE_CAPACITY)
    limit = SONBAL_OPENAI_PROVIDER_QUEUE_CAPACITY;

  return limit;
}

static bool
all_slots_free_locked(
  const struct sonbal_openai_transport *transport)
{
  size_t index;

  for (index = 0; index < transport->slot_count; index++) {
    if (transport->slots[index].state != SLOT_FREE)
      return false;
  }

  return true;
}

static bool
has_ready_event_locked(
  const struct sonbal_openai_transport *transport)
{
  size_t index;

  for (index = 0; index < transport->slot_count; index++) {
    if (transport->slots[index].state == SLOT_ABANDON_PENDING)
      return true;
  }

  if (can_publish_request_locked(transport))
    return true;

  if (transport->fatal_pending &&
      !transport->fatal_reported)
    return true;

  return transport->stopping &&
    transport->worker_exited &&
    transport->deadline_monitor_exited &&
    all_slots_free_locked(transport) &&
    !transport->shutdown_reported;
}

static void
resignal_if_ready_locked(
  struct sonbal_openai_transport *transport)
{
  if (has_ready_event_locked(transport))
    (void)signal_wakeup(transport);
}

static struct command_slot *
find_free_slot_locked(struct sonbal_openai_transport *transport)
{
  size_t index;

  for (index = 0; index < transport->slot_count; index++) {
    if (transport->slots[index].state == SLOT_FREE)
      return &transport->slots[index];
  }

  return NULL;
}

static struct command_slot *
find_token_locked(
  struct sonbal_openai_transport *transport,
  sonbal_connector_request_token_t token)
{
  size_t index;

  for (index = 0; index < transport->slot_count; index++) {
    if (transport->slots[index].state != SLOT_FREE &&
        transport->slots[index].token == token)
      return &transport->slots[index];
  }

  return NULL;
}

static sonbal_connector_request_token_t
next_token_locked(struct sonbal_openai_transport *transport)
{
  sonbal_connector_request_token_t token = transport->next_token;

  if (token == SONBAL_CONNECTOR_NO_REQUEST_TOKEN)
    token = 1;

  transport->next_token = token + 1;
  if (transport->next_token == SONBAL_CONNECTOR_NO_REQUEST_TOKEN)
    transport->next_token = 1;

  return token;
}

static enum retry_wait_result
wait_retry(
  struct sonbal_openai_transport *transport,
  unsigned attempt,
  uint64_t retry_after_ms,
  const struct command_slot *slot)
{
  uint64_t now;
  uint64_t target;
  uint64_t delay_ms;

  if (!monotonic_now_ns(&now))
    return RETRY_FAILED;

  delay_ms = retry_delay_ms(
    transport, attempt, retry_after_ms);
  target = saturating_add_u64(
    now, delay_ms * UINT64_C(1000000));

  if (slot != NULL &&
      slot->deadline_valid &&
      target > slot->deadline_ns)
    target = slot->deadline_ns;

  if (pthread_mutex_lock(&transport->lock) != 0)
    return RETRY_FAILED;

  for (;;) {
    struct timespec absolute;
    int status;

    if (transport->stopping) {
      (void)pthread_mutex_unlock(&transport->lock);
      return RETRY_STOPPED;
    }

    if (!monotonic_now_ns(&now)) {
      (void)pthread_mutex_unlock(&transport->lock);
      return RETRY_FAILED;
    }

    if (slot != NULL &&
        slot->deadline_valid &&
        now >= slot->deadline_ns) {
      (void)pthread_mutex_unlock(&transport->lock);
      return RETRY_EXPIRED;
    }

    if (now >= target) {
      (void)pthread_mutex_unlock(&transport->lock);
      return RETRY_READY;
    }

    timespec_from_ns(target, &absolute);
    status = pthread_cond_timedwait(
      &transport->condition,
      &transport->lock,
      &absolute);

    if (status != 0 && status != ETIMEDOUT) {
      (void)pthread_mutex_unlock(&transport->lock);
      return RETRY_FAILED;
    }
  }
}

static bool
poll_retryable(
  enum sonbal_openai_http_status status,
  long response_code)
{
  if (status == SONBAL_OPENAI_HTTP_TRANSPORT_FAILED)
    return true;

  if (status != SONBAL_OPENAI_HTTP_OK)
    return false;

  return response_code == 429 ||
    (response_code >= 500 && response_code <= 599);
}

static bool
post_retryable(
  enum sonbal_openai_http_status status,
  long response_code)
{
  if (status == SONBAL_OPENAI_HTTP_TRANSPORT_FAILED)
    return true;

  if (status != SONBAL_OPENAI_HTTP_OK)
    return false;

  return response_code == 408 ||
    response_code == 429 ||
    response_code == 502 ||
    response_code == 503 ||
    response_code == 504;
}

static uint64_t
retry_after_hint_ms(
  const struct sonbal_openai_http_result *result)
{
  if (result == NULL ||
      !result->retry_after_valid ||
      (result->response_code != 429 &&
       result->response_code != 503))
    return 0;

  return result->retry_after_ms;
}

static bool
append_bytes(
  char *buffer,
  size_t capacity,
  size_t *length,
  const char *data,
  size_t count)
{
  if (*length > capacity || count > capacity - *length)
    return false;

  if (count > 0)
    memcpy(buffer + *length, data, count);
  *length += count;
  return true;
}

static bool
append_literal(
  char *buffer,
  size_t capacity,
  size_t *length,
  const char *text)
{
  return append_bytes(
    buffer, capacity, length, text, strlen(text));
}

static bool
append_json_string(
  char *buffer,
  size_t capacity,
  size_t *length,
  const char *text,
  size_t text_length)
{
  static const char hex[] = "0123456789abcdef";
  size_t index;

  if (!append_literal(buffer, capacity, length, "\""))
    return false;

  for (index = 0; index < text_length; index++) {
    unsigned char byte = (unsigned char)text[index];
    char escaped[6];

    if (byte == '"' || byte == '\\') {
      escaped[0] = '\\';
      escaped[1] = (char)byte;
      if (!append_bytes(
            buffer, capacity, length, escaped, 2))
        return false;
    } else if (byte < 0x20) {
      escaped[0] = '\\';
      escaped[1] = 'u';
      escaped[2] = '0';
      escaped[3] = '0';
      escaped[4] = hex[byte >> 4];
      escaped[5] = hex[byte & 0x0f];
      if (!append_bytes(
            buffer, capacity, length, escaped, 6))
        return false;
    } else if (!append_bytes(
                 buffer,
                 capacity,
                 length,
                 text + index,
                 1)) {
      return false;
    }
  }

  return append_literal(buffer, capacity, length, "\"");
}


static bool
serialize_post_body(
  const struct command_slot *slot,
  bool session_termination,
  char *buffer,
  size_t capacity,
  size_t *length)
{
  const char *type;
  const char *code;
  size_t used = 0;

  if (!append_literal(
        buffer, capacity, &used, "{\"request_id\":") ||
      !append_json_string(
        buffer,
        capacity,
        &used,
        slot->request_id,
        slot->request_id_length) ||
      !append_literal(
        buffer, capacity, &used, ",\"channel\":") ||
      !append_json_string(
        buffer,
        capacity,
        &used,
        slot->channel,
        slot->channel_length))
    return false;

  if (session_termination) {
    type = "session_termination_response";
    code = "204";
  } else if (slot->response_length == 0) {
    type = "notify_ack";
    code = "204";
  } else {
    type = "jsonrpc_response";
    code = "200";

    if (!append_literal(
          buffer, capacity, &used, ",\"resp_json\":") ||
        !append_bytes(
          buffer,
          capacity,
          &used,
          slot->response,
          slot->response_length))
      return false;
  }

  if (!append_literal(
        buffer, capacity, &used, ",\"resp_code\":") ||
      !append_literal(buffer, capacity, &used, code) ||
      !append_literal(
        buffer, capacity, &used, ",\"resp_type\":") ||
      !append_json_string(
        buffer, capacity, &used, type, strlen(type)) ||
      !append_literal(buffer, capacity, &used, "}"))
    return false;

  *length = used;
  return true;
}

static bool
copy_command_metadata(
  struct command_slot *slot,
  const struct sonbal_openai_command *command)
{
  if (command->request_id_length >
        SONBAL_OPENAI_MAX_REQUEST_ID_BYTES ||
      command->shard_token_length >
        SONBAL_OPENAI_MAX_SHARD_TOKEN_BYTES ||
      command->channel_length >
        SONBAL_OPENAI_MAX_CHANNEL_BYTES)
    return false;

  memcpy(
    slot->request_id,
    command->request_id,
    command->request_id_length + 1);
  slot->request_id_length = command->request_id_length;

  memcpy(
    slot->shard_token,
    command->shard_token,
    command->shard_token_length + 1);
  slot->shard_token_length = command->shard_token_length;

  memcpy(
    slot->channel,
    command->channel,
    command->channel_length + 1);
  slot->channel_length = command->channel_length;

  return true;
}

static bool
stage_polled_command(
  const struct sonbal_openai_command *command,
  void *context)
{
  struct batch_context *batch = context;
  struct sonbal_openai_transport *transport = batch->transport;
  struct command_slot *slot;

  if (command->kind == SONBAL_OPENAI_COMMAND_UNKNOWN)
    return true;

  if (command->kind == SONBAL_OPENAI_COMMAND_JSONRPC &&
      (command->jsonrpc == NULL ||
       command->jsonrpc_length == 0 ||
       command->jsonrpc_length >
         transport->maximum_request_bytes))
    return false;

  slot = find_free_slot_locked(transport);
  if (slot == NULL)
    return false;

  slot->token = next_token_locked(transport);

  if (!copy_command_metadata(slot, command)) {
    clear_slot(slot);
    return false;
  }

  if (command->response_timeout.present &&
      command->response_timeout.valid) {
    uint64_t now;

    slot->deadline_valid = true;
    slot->deadline_ns = saturating_add_u64(
      batch->receipt_ns,
      command->response_timeout.nanoseconds);

    if (!monotonic_now_ns(&now)) {
      clear_slot(slot);
      return false;
    }

    if (now >= slot->deadline_ns) {
      clear_slot(slot);
      return true;
    }
  }

  if (command->kind ==
      SONBAL_OPENAI_COMMAND_SESSION_TERMINATION) {
    slot->state = SLOT_STAGING_SESSION;
    return true;
  }

  slot->request = malloc(command->jsonrpc_length);
  if (slot->request == NULL) {
    clear_slot(slot);
    return false;
  }

  memcpy(
    slot->request,
    command->jsonrpc,
    command->jsonrpc_length);
  slot->request_length = command->jsonrpc_length;
  slot->state = SLOT_STAGING_JSONRPC;
  return true;
}

static void
rollback_staging_locked(
  struct sonbal_openai_transport *transport)
{
  size_t index;

  for (index = 0; index < transport->slot_count; index++) {
    if (transport->slots[index].state ==
          SLOT_STAGING_JSONRPC ||
        transport->slots[index].state ==
          SLOT_STAGING_SESSION)
      clear_slot(&transport->slots[index]);
  }
}

static bool
commit_staging_locked(
  struct sonbal_openai_transport *transport)
{
  size_t index;
  size_t queued = queued_request_count_locked(transport);
  bool wake = false;

  for (index = 0; index < transport->slot_count; index++) {
    if (transport->slots[index].state ==
        SLOT_STAGING_JSONRPC) {
      if (queued <
          (size_t)SONBAL_OPENAI_PROVIDER_QUEUE_CAPACITY) {
        transport->slots[index].state = SLOT_QUEUED;
        queued++;
        wake = true;
      } else {
        transport->slots[index].state =
          SLOT_PREFETCH_OVERFLOW;
      }
    } else if (
      transport->slots[index].state ==
        SLOT_STAGING_SESSION) {
      transport->slots[index].state =
        SLOT_SESSION_ACK_PENDING;
    }
  }

  return wake;
}

static void
mark_fatal_locked(
  struct sonbal_openai_transport *transport)
{
  size_t index;

  transport->fatal_pending = true;

  for (index = 0; index < transport->slot_count; index++) {
    struct command_slot *slot = &transport->slots[index];

    if (slot->state == SLOT_INFLIGHT)
      slot->state = SLOT_ABANDON_PENDING;
    else if (slot->state != SLOT_ABANDON_PENDING &&
             slot->state != SLOT_POSTING)
      clear_slot(slot);
  }

  (void)signal_wakeup(transport);
}

static void
fail_transport_locked(
  struct sonbal_openai_transport *transport)
{
  mark_fatal_locked(transport);
  transport->stopping = true;

  if (transport->http_initialized)
    sonbal_openai_http_cancel(&transport->http);

  notify_state_change_locked(transport);
}

static void
finish_deadline_monitor_locked(
  struct sonbal_openai_transport *transport)
{
  transport->deadline_monitor_ready = false;
  transport->deadline_monitor_exited = true;
  (void)signal_wakeup(transport);
  notify_state_change_locked(transport);
}

static void *
deadline_monitor_main(void *context)
{
  struct sonbal_openai_transport *transport = context;

  if (pthread_mutex_lock(&transport->lock) != 0)
    return NULL;

  transport->deadline_monitor_ready = true;
  (void)pthread_cond_broadcast(
    &transport->deadline_condition);

  for (;;) {
    uint64_t deadline;
    int status;

    if (transport->stopping) {
      finish_deadline_monitor_locked(transport);
      (void)pthread_mutex_unlock(&transport->lock);
      return NULL;
    }

    if (!refresh_deadlines_locked(transport)) {
      fail_transport_locked(transport);
      finish_deadline_monitor_locked(transport);
      (void)pthread_mutex_unlock(&transport->lock);
      return NULL;
    }

    if (nearest_deadline_locked(transport, &deadline)) {
      struct timespec absolute;

      timespec_from_ns(deadline, &absolute);
      status = pthread_cond_timedwait(
        &transport->deadline_condition,
        &transport->lock,
        &absolute);
    } else {
      status = pthread_cond_wait(
        &transport->deadline_condition,
        &transport->lock);
    }

    if (status != 0 && status != ETIMEDOUT) {
      fail_transport_locked(transport);
      finish_deadline_monitor_locked(transport);
      (void)pthread_mutex_unlock(&transport->lock);
      return NULL;
    }
  }
}

static void
shutdown_slots_locked(
  struct sonbal_openai_transport *transport)
{
  size_t index;
  bool wake = false;

  for (index = 0; index < transport->slot_count; index++) {
    struct command_slot *slot = &transport->slots[index];

    switch (slot->state) {
      case SLOT_INFLIGHT:
        slot->state = SLOT_ABANDON_PENDING;
        wake = true;
        break;

      case SLOT_ABANDON_PENDING:
      case SLOT_POSTING:
      case SLOT_FREE:
        break;

      default:
        clear_slot(slot);
        break;
    }
  }

  if (wake)
    (void)signal_wakeup(transport);
}

static struct command_slot *
next_post_slot_locked(
  struct sonbal_openai_transport *transport,
  bool *session_termination)
{
  size_t index;

  for (index = 0; index < transport->slot_count; index++) {
    struct command_slot *slot = &transport->slots[index];

    if (slot->state == SLOT_SESSION_ACK_PENDING) {
      *session_termination = true;
      slot->state = SLOT_POSTING;
      return slot;
    }

    if (slot->state == SLOT_RESPONSE_PENDING) {
      *session_termination = false;
      slot->state = SLOT_POSTING;
      return slot;
    }
  }

  return NULL;
}

static uint32_t
remaining_post_timeout_ms(
  const struct command_slot *slot,
  uint64_t now)
{
  uint64_t remaining;
  uint64_t milliseconds;

  if (!slot->deadline_valid)
    return POST_TIMEOUT_MS;

  if (now >= slot->deadline_ns)
    return 0;

  remaining = slot->deadline_ns - now;
  milliseconds =
    (remaining + UINT64_C(999999)) / UINT64_C(1000000);

  if (milliseconds == 0)
    milliseconds = 1;
  if (milliseconds > POST_TIMEOUT_MS)
    milliseconds = POST_TIMEOUT_MS;

  return (uint32_t)milliseconds;
}

static enum post_result
post_slot(
  struct sonbal_openai_transport *transport,
  struct command_slot *slot,
  bool session_termination)
{
  char control_body[CONTROL_RESPONSE_BYTES];
  size_t post_length;
  unsigned attempt = 0;

  if (!serialize_post_body(
        slot,
        session_termination,
        transport->post_body,
        transport->post_body_capacity,
        &post_length))
    return POST_FAILED;

  for (;;) {
    struct sonbal_openai_http_result result;
    enum sonbal_openai_http_status status;
    enum retry_wait_result wait_status;
    uint64_t now;
    uint32_t timeout_ms;

    if (!monotonic_now_ns(&now))
      return POST_FAILED;

    timeout_ms = remaining_post_timeout_ms(slot, now);
    if (timeout_ms == 0)
      return POST_EXPIRED;

    sonbal_openai_http_reset_cancellation(&transport->http);
    status = sonbal_openai_http_post_response(
      &transport->http,
      slot->shard_token,
      transport->post_body,
      post_length,
      timeout_ms,
      control_body,
      sizeof control_body,
      &result);

    if (status == SONBAL_OPENAI_HTTP_CANCELLED) {
      bool stopping = false;

      if (pthread_mutex_lock(&transport->lock) != 0)
        return POST_FAILED;
      stopping = transport->stopping;
      (void)pthread_mutex_unlock(&transport->lock);
      return stopping ? POST_OK : POST_FAILED;
    }

    if (status == SONBAL_OPENAI_HTTP_OK &&
        (result.response_code == 200 ||
         result.response_code == 404))
      return POST_OK;

    if (slot->deadline_valid &&
        monotonic_now_ns(&now) &&
        now >= slot->deadline_ns)
      return POST_EXPIRED;

    if (!post_retryable(status, result.response_code))
      return POST_FAILED;

    wait_status = wait_retry(
      transport,
      attempt++,
      retry_after_hint_ms(&result),
      slot);

    if (wait_status == RETRY_STOPPED)
      return POST_OK;
    if (wait_status == RETRY_EXPIRED)
      return POST_EXPIRED;
    if (wait_status == RETRY_FAILED)
      return POST_FAILED;
  }
}


static void *
transport_worker(void *context)
{
  struct sonbal_openai_transport *transport = context;
  unsigned poll_attempt = 0;

  for (;;) {
    struct command_slot *post_slot_value = NULL;
    bool session_termination = false;

    if (pthread_mutex_lock(&transport->lock) != 0)
      break;

    if (transport->stopping) {
      shutdown_slots_locked(transport);
      transport->worker_exited = true;
      (void)signal_wakeup(transport);
      notify_state_change_locked(transport);
      (void)pthread_mutex_unlock(&transport->lock);
      return NULL;
    }

    post_slot_value =
      next_post_slot_locked(
        transport, &session_termination);

    if (post_slot_value != NULL) {
      enum post_result post_status;

      (void)pthread_mutex_unlock(&transport->lock);

      post_status = post_slot(
        transport,
        post_slot_value,
        session_termination);

      if (pthread_mutex_lock(&transport->lock) != 0)
        return NULL;

      clear_slot(post_slot_value);

      if (post_status == POST_FAILED) {
        mark_fatal_locked(transport);
        transport->worker_exited = true;
        notify_state_change_locked(transport);
        (void)pthread_mutex_unlock(&transport->lock);
        return NULL;
      }

      notify_state_change_locked(transport);
      (void)pthread_mutex_unlock(&transport->lock);
      continue;
    }

    if (!all_slots_free_locked(transport)) {
      if (pthread_cond_wait(
            &transport->condition,
            &transport->lock) != 0) {
        mark_fatal_locked(transport);
        transport->worker_exited = true;
        notify_state_change_locked(transport);
        (void)pthread_mutex_unlock(&transport->lock);
        return NULL;
      }

      (void)pthread_mutex_unlock(&transport->lock);
      continue;
    }

    (void)pthread_mutex_unlock(&transport->lock);

    {
      struct sonbal_openai_http_result result;
      enum sonbal_openai_http_status http_status;

      sonbal_openai_http_reset_cancellation(&transport->http);
      http_status = sonbal_openai_http_poll(
        &transport->http,
        poll_request_limit(transport),
        transport->configuration.poll_timeout_ms,
        transport->poll_body,
        transport->poll_body_capacity,
        &result);

      if (pthread_mutex_lock(&transport->lock) != 0)
        return NULL;

      if (transport->stopping) {
        shutdown_slots_locked(transport);
        transport->worker_exited = true;
        (void)signal_wakeup(transport);
        notify_state_change_locked(transport);
        (void)pthread_mutex_unlock(&transport->lock);
        return NULL;
      }

      if (http_status == SONBAL_OPENAI_HTTP_CANCELLED) {
        (void)pthread_mutex_unlock(&transport->lock);
        continue;
      }

      if (poll_retryable(
            http_status, result.response_code)) {
        enum retry_wait_result wait_status;
        uint64_t retry_after =
          retry_after_hint_ms(&result);

        (void)pthread_mutex_unlock(&transport->lock);

        wait_status = wait_retry(
          transport,
          poll_attempt++,
          retry_after,
          NULL);

        if (wait_status == RETRY_READY ||
            wait_status == RETRY_STOPPED)
          continue;

        if (pthread_mutex_lock(&transport->lock) == 0) {
          mark_fatal_locked(transport);
          transport->worker_exited = true;
          notify_state_change_locked(transport);
          (void)pthread_mutex_unlock(&transport->lock);
        }
        return NULL;
      }

      if (http_status != SONBAL_OPENAI_HTTP_OK ||
          (result.response_code != 200 &&
           result.response_code != 204)) {
        mark_fatal_locked(transport);
        transport->worker_exited = true;
        notify_state_change_locked(transport);
        (void)pthread_mutex_unlock(&transport->lock);
        return NULL;
      }

      poll_attempt = 0;

      if (result.response_code == 204) {
        (void)pthread_mutex_unlock(&transport->lock);
        continue;
      }

      if (result.headers_received_ns == 0) {
        mark_fatal_locked(transport);
        transport->worker_exited = true;
        notify_state_change_locked(transport);
        (void)pthread_mutex_unlock(&transport->lock);
        return NULL;
      }

      {
        struct batch_context batch;
        size_t command_count = 0;
        enum sonbal_openai_protocol_status parse_status;
        bool wake;

        batch.transport = transport;
        batch.receipt_ns = result.headers_received_ns;

        parse_status = sonbal_openai_parse_poll_response(
          transport->poll_body,
          result.body_length,
          transport->maximum_request_bytes,
          stage_polled_command,
          &batch,
          &command_count);
        (void)command_count;

        if (parse_status != SONBAL_OPENAI_PROTOCOL_OK) {
          rollback_staging_locked(transport);
          mark_fatal_locked(transport);
          transport->worker_exited = true;
          notify_state_change_locked(transport);
          (void)pthread_mutex_unlock(&transport->lock);
          return NULL;
        }

        wake = commit_staging_locked(transport);
        if (wake)
          (void)signal_wakeup(transport);

        notify_state_change_locked(transport);
      }

      (void)pthread_mutex_unlock(&transport->lock);
    }
  }

  if (pthread_mutex_lock(&transport->lock) == 0) {
    mark_fatal_locked(transport);
    transport->worker_exited = true;
    notify_state_change_locked(transport);
    (void)pthread_mutex_unlock(&transport->lock);
  }

  return NULL;
}

static bool
allocate_storage(
  struct sonbal_openai_transport *transport,
  uint32_t maximum_active_requests,
  uint32_t maximum_request_bytes,
  uint32_t maximum_response_bytes)
{
  size_t per_command;
  size_t poll_capacity;
  size_t post_capacity;
  size_t total_slots;

  per_command =
    (size_t)maximum_request_bytes +
    POLL_COMMAND_OVERHEAD_BYTES;
  if (per_command < (size_t)maximum_request_bytes)
    return false;

  total_slots =
    (size_t)maximum_active_requests +
    (size_t)SONBAL_OPENAI_PROVIDER_QUEUE_CAPACITY;
  if (total_slots < (size_t)maximum_active_requests)
    return false;

  if (total_slots > SIZE_MAX / per_command)
    return false;

  poll_capacity = total_slots * per_command;
  if (poll_capacity > SIZE_MAX - 1024)
    return false;
  poll_capacity += 1024;

  post_capacity =
    (size_t)maximum_response_bytes +
    POST_ENVELOPE_OVERHEAD_BYTES;
  if (post_capacity < (size_t)maximum_response_bytes)
    return false;

  transport->slots = calloc(
    total_slots, sizeof *transport->slots);
  transport->slot_count = total_slots;

  transport->poll_body = malloc(poll_capacity);
  transport->post_body = malloc(post_capacity);

  if (transport->slots == NULL ||
      transport->poll_body == NULL ||
      transport->post_body == NULL)
    return false;

  transport->poll_body_capacity = poll_capacity;
  transport->post_body_capacity = post_capacity;
  transport->maximum_active_requests = maximum_active_requests;
  transport->maximum_request_bytes =
    maximum_request_bytes;
  transport->maximum_response_bytes =
    maximum_response_bytes;
  transport->next_token = 1;

  return true;
}

static void
release_storage(struct sonbal_openai_transport *transport)
{
  size_t index;

  if (transport->slots != NULL) {
    for (index = 0; index < transport->slot_count; index++)
      clear_slot(&transport->slots[index]);

    secure_zero(
      transport->slots,
      transport->slot_count *
        sizeof *transport->slots);
    free(transport->slots);
  }

  if (transport->poll_body != NULL) {
    secure_zero(
      transport->poll_body,
      transport->poll_body_capacity);
    free(transport->poll_body);
  }

  if (transport->post_body != NULL) {
    secure_zero(
      transport->post_body,
      transport->post_body_capacity);
    free(transport->post_body);
  }

  transport->slots = NULL;
  transport->slot_count = 0;
  transport->poll_body = NULL;
  transport->poll_body_capacity = 0;
  transport->post_body = NULL;
  transport->post_body_capacity = 0;
}


static bool
initialize_monotonic_condition(
  pthread_cond_t *condition)
{
  pthread_condattr_t attributes;
  int status;

  if (pthread_condattr_init(&attributes) != 0)
    return false;

  if (pthread_condattr_setclock(
        &attributes, CLOCK_MONOTONIC) != 0) {
    (void)pthread_condattr_destroy(&attributes);
    return false;
  }

  status = pthread_cond_init(condition, &attributes);
  (void)pthread_condattr_destroy(&attributes);
  return status == 0;
}

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
  int wakeup_write_fd)
{
  struct sonbal_openai_transport *state;
  enum sonbal_openai_http_status http_status;

  if (transport == NULL ||
      configuration == NULL ||
      base_url == NULL ||
      credential == NULL ||
      credential_length == 0 ||
      maximum_active_requests == 0 ||
      maximum_request_bytes == 0 ||
      maximum_response_bytes == 0 ||
      wakeup_write_fd < 0)
    return SONBAL_OPENAI_TRANSPORT_INVALID_ARGUMENT;

  *transport = NULL;

  state = calloc(1, sizeof *state);
  if (state == NULL)
    return SONBAL_OPENAI_TRANSPORT_RESOURCE_EXHAUSTED;

  state->configuration = *configuration;
  state->wakeup_write_fd = wakeup_write_fd;

  {
    uint64_t seed;

    if (!monotonic_now_ns(&seed))
      seed = UINT64_C(0x243f6a8885a308d3);

    state->random_state =
      seed ^
      (uint64_t)(uintptr_t)state ^
      (uint64_t)getpid();
  }

  if (pthread_mutex_init(&state->lock, NULL) != 0)
    goto fail_internal;
  state->lock_initialized = true;

  if (!initialize_monotonic_condition(&state->condition))
    goto fail_internal;
  state->condition_initialized = true;

  if (!initialize_monotonic_condition(
        &state->deadline_condition))
    goto fail_internal;
  state->deadline_condition_initialized = true;

  if (!allocate_storage(
        state,
        maximum_active_requests,
        maximum_request_bytes,
        maximum_response_bytes))
    goto fail_resource;

  http_status = sonbal_openai_http_initialize(
    &state->http,
    base_url,
    state->configuration.tunnel_id,
    credential,
    credential_length,
    "sonbal",
    "1");
  if (http_status != SONBAL_OPENAI_HTTP_OK)
    goto fail_internal;

  state->http_initialized = true;
  *transport = state;
  return SONBAL_OPENAI_TRANSPORT_OK;

fail_resource:
  sonbal_openai_transport_destroy(&state);
  return SONBAL_OPENAI_TRANSPORT_RESOURCE_EXHAUSTED;

fail_internal:
  sonbal_openai_transport_destroy(&state);
  return SONBAL_OPENAI_TRANSPORT_INTERNAL_ERROR;
}

enum sonbal_openai_transport_status
sonbal_openai_transport_start(
  struct sonbal_openai_transport *transport)
{
  int wait_status = 0;

  if (transport == NULL)
    return SONBAL_OPENAI_TRANSPORT_INVALID_ARGUMENT;

  if (pthread_mutex_lock(&transport->lock) != 0)
    return SONBAL_OPENAI_TRANSPORT_INTERNAL_ERROR;

  if (transport->started ||
      transport->worker_created ||
      transport->deadline_monitor_created ||
      transport->stopping) {
    (void)pthread_mutex_unlock(&transport->lock);
    return SONBAL_OPENAI_TRANSPORT_INVALID_STATE;
  }

  transport->worker_exited = false;
  transport->deadline_monitor_ready = false;
  transport->deadline_monitor_exited = false;
  transport->fatal_pending = false;
  transport->fatal_reported = false;
  transport->shutdown_reported = false;
  transport->started = true;

  if (pthread_create(
        &transport->deadline_monitor,
        NULL,
        deadline_monitor_main,
        transport) != 0) {
    transport->started = false;
    transport->deadline_monitor_exited = true;
    (void)pthread_mutex_unlock(&transport->lock);
    return SONBAL_OPENAI_TRANSPORT_INTERNAL_ERROR;
  }
  transport->deadline_monitor_created = true;

  while (!transport->deadline_monitor_ready &&
         !transport->deadline_monitor_exited) {
    wait_status = pthread_cond_wait(
      &transport->deadline_condition,
      &transport->lock);
    if (wait_status != 0)
      break;
  }

  if (wait_status != 0 ||
      !transport->deadline_monitor_ready) {
    transport->stopping = true;
    notify_state_change_locked(transport);
    (void)pthread_mutex_unlock(&transport->lock);

    (void)pthread_join(transport->deadline_monitor, NULL);
    transport->deadline_monitor_created = false;

    if (pthread_mutex_lock(&transport->lock) == 0) {
      transport->started = false;
      transport->stopping = false;
      transport->deadline_monitor_ready = false;
      transport->deadline_monitor_exited = false;
      (void)pthread_mutex_unlock(&transport->lock);
    }
    return SONBAL_OPENAI_TRANSPORT_INTERNAL_ERROR;
  }

  (void)pthread_mutex_unlock(&transport->lock);

  if (pthread_create(
        &transport->worker,
        NULL,
        transport_worker,
        transport) != 0) {
    if (pthread_mutex_lock(&transport->lock) == 0) {
      transport->stopping = true;
      notify_state_change_locked(transport);
      (void)pthread_mutex_unlock(&transport->lock);
    }

    (void)pthread_join(transport->deadline_monitor, NULL);
    transport->deadline_monitor_created = false;

    if (pthread_mutex_lock(&transport->lock) == 0) {
      transport->started = false;
      transport->stopping = false;
      transport->deadline_monitor_ready = false;
      transport->deadline_monitor_exited = false;
      (void)pthread_mutex_unlock(&transport->lock);
    }
    return SONBAL_OPENAI_TRANSPORT_INTERNAL_ERROR;
  }

  transport->worker_created = true;
  return SONBAL_OPENAI_TRANSPORT_OK;
}

enum sonbal_openai_transport_status
sonbal_openai_transport_next_event(
  struct sonbal_openai_transport *transport,
  void *request_buffer,
  uint32_t request_capacity,
  void *correlation_buffer,
  uint32_t correlation_capacity,
  struct sonbal_connector_event *event)
{
  size_t index;

  if (transport == NULL || event == NULL)
    return SONBAL_OPENAI_TRANSPORT_INVALID_ARGUMENT;

  memset(event, 0, sizeof *event);

  if (pthread_mutex_lock(&transport->lock) != 0)
    return SONBAL_OPENAI_TRANSPORT_INTERNAL_ERROR;

  if (!transport->started) {
    (void)pthread_mutex_unlock(&transport->lock);
    return SONBAL_OPENAI_TRANSPORT_INVALID_STATE;
  }

  if (!refresh_deadlines_locked(transport))
    fail_transport_locked(transport);

  for (index = 0; index < transport->slot_count; index++) {
    struct command_slot *slot = &transport->slots[index];

    if (slot->state == SLOT_ABANDON_PENDING) {
      event->token = slot->token;
      event->kind = SONBAL_CONNECTOR_EVENT_REQUEST_ABANDONED;
      clear_slot(slot);
      notify_state_change_locked(transport);
      resignal_if_ready_locked(transport);
      (void)pthread_mutex_unlock(&transport->lock);
      return SONBAL_OPENAI_TRANSPORT_OK;
    }
  }

  if (transport->fatal_pending &&
      !transport->fatal_reported) {
    transport->fatal_reported = true;
    event->kind = SONBAL_CONNECTOR_EVENT_FATAL;
    resignal_if_ready_locked(transport);
    (void)pthread_mutex_unlock(&transport->lock);
    return SONBAL_OPENAI_TRANSPORT_OK;
  }

  if (active_request_count_locked(transport) <
      transport->maximum_active_requests) {
    for (index = 0; index < transport->slot_count; index++) {
      struct command_slot *slot = &transport->slots[index];

      if (slot->state != SLOT_QUEUED)
        continue;

      if (slot->request_length > request_capacity ||
          (slot->request_length > 0 &&
           request_buffer == NULL)) {
        (void)pthread_mutex_unlock(&transport->lock);
        return SONBAL_OPENAI_TRANSPORT_RESOURCE_EXHAUSTED;
      }

      if (slot->request_length > 0)
        memcpy(
          request_buffer,
          slot->request,
          slot->request_length);

      event->token = slot->token;
      event->kind = SONBAL_CONNECTOR_EVENT_REQUEST;
      event->request_length =
        (uint32_t)slot->request_length;

      if (slot->request_id_length > 0) {
        size_t copy_length = slot->request_id_length;

        if (correlation_buffer == NULL ||
            correlation_capacity == 0) {
          event->correlation_truncated = 1;
          copy_length = 0;
        } else if (copy_length > correlation_capacity) {
          copy_length = correlation_capacity;
          event->correlation_truncated = 1;
        }

        if (copy_length > 0)
          memcpy(
            correlation_buffer,
            slot->request_id,
            copy_length);
        event->correlation_length =
          (uint32_t)copy_length;
      }

      if (slot->request != NULL) {
        secure_zero(
          slot->request,
          slot->request_length);
        free(slot->request);
        slot->request = NULL;
        slot->request_length = 0;
      }
      slot->state = SLOT_INFLIGHT;
      (void)promote_prefetch_overflow_locked(transport);
      resignal_if_ready_locked(transport);
      (void)pthread_mutex_unlock(&transport->lock);
      return SONBAL_OPENAI_TRANSPORT_OK;
    }
  }

  if (transport->stopping &&
      transport->worker_exited &&
      transport->deadline_monitor_exited &&
      all_slots_free_locked(transport) &&
      !transport->shutdown_reported) {
    transport->shutdown_reported = true;
    transport->started = false;
    event->kind =
      SONBAL_CONNECTOR_EVENT_SHUTDOWN_COMPLETE;
    (void)pthread_mutex_unlock(&transport->lock);
    return SONBAL_OPENAI_TRANSPORT_OK;
  }

  (void)pthread_mutex_unlock(&transport->lock);
  return SONBAL_OPENAI_TRANSPORT_WOULD_BLOCK;
}

enum sonbal_openai_transport_status
sonbal_openai_transport_complete(
  struct sonbal_openai_transport *transport,
  sonbal_connector_request_token_t token,
  const void *response,
  uint32_t response_length)
{
  struct command_slot *slot;

  if (transport == NULL ||
      token == SONBAL_CONNECTOR_NO_REQUEST_TOKEN ||
      (response_length > 0 && response == NULL))
    return SONBAL_OPENAI_TRANSPORT_INVALID_ARGUMENT;

  if (response_length > transport->maximum_response_bytes)
    return SONBAL_OPENAI_TRANSPORT_RESOURCE_EXHAUSTED;

  if (pthread_mutex_lock(&transport->lock) != 0)
    return SONBAL_OPENAI_TRANSPORT_INTERNAL_ERROR;

  if (!transport->started) {
    (void)pthread_mutex_unlock(&transport->lock);
    return SONBAL_OPENAI_TRANSPORT_INVALID_STATE;
  }

  if (!refresh_deadlines_locked(transport)) {
    fail_transport_locked(transport);
    (void)pthread_mutex_unlock(&transport->lock);
    return SONBAL_OPENAI_TRANSPORT_INTERNAL_ERROR;
  }

  slot = find_token_locked(transport, token);
  if (slot == NULL ||
      (slot->state != SLOT_INFLIGHT &&
       slot->state != SLOT_ABANDON_PENDING)) {
    (void)pthread_mutex_unlock(&transport->lock);
    return SONBAL_OPENAI_TRANSPORT_INVALID_STATE;
  }

  if (slot->state == SLOT_ABANDON_PENDING) {
    (void)pthread_mutex_unlock(&transport->lock);
    return SONBAL_OPENAI_TRANSPORT_INVALID_STATE;
  }

  if (transport->stopping) {
    clear_slot(slot);
    notify_state_change_locked(transport);
    (void)pthread_mutex_unlock(&transport->lock);
    return SONBAL_OPENAI_TRANSPORT_OK;
  }

  if (response_length > 0) {
    slot->response = malloc(response_length);
    if (slot->response == NULL) {
      (void)pthread_mutex_unlock(&transport->lock);
      return SONBAL_OPENAI_TRANSPORT_RESOURCE_EXHAUSTED;
    }

    memcpy(slot->response, response, response_length);
    slot->response_length = response_length;
  }

  slot->state = SLOT_RESPONSE_PENDING;
  notify_state_change_locked(transport);
  resignal_if_ready_locked(transport);
  (void)pthread_mutex_unlock(&transport->lock);
  return SONBAL_OPENAI_TRANSPORT_OK;
}

enum sonbal_openai_transport_status
sonbal_openai_transport_begin_shutdown(
  struct sonbal_openai_transport *transport)
{
  if (transport == NULL)
    return SONBAL_OPENAI_TRANSPORT_INVALID_ARGUMENT;

  if (pthread_mutex_lock(&transport->lock) != 0)
    return SONBAL_OPENAI_TRANSPORT_INTERNAL_ERROR;

  if (!transport->started) {
    (void)pthread_mutex_unlock(&transport->lock);
    return SONBAL_OPENAI_TRANSPORT_INVALID_STATE;
  }

  if (!transport->stopping) {
    transport->stopping = true;
    sonbal_openai_http_cancel(&transport->http);
    notify_state_change_locked(transport);
    (void)signal_wakeup(transport);
  }

  (void)pthread_mutex_unlock(&transport->lock);
  return SONBAL_OPENAI_TRANSPORT_OK;
}

void
sonbal_openai_transport_destroy(
  struct sonbal_openai_transport **transport)
{
  struct sonbal_openai_transport *state;

  if (transport == NULL || *transport == NULL)
    return;

  state = *transport;

  if (state->worker_created ||
      state->deadline_monitor_created) {
    if (state->lock_initialized &&
        pthread_mutex_lock(&state->lock) == 0) {
      state->stopping = true;
      if (state->http_initialized)
        sonbal_openai_http_cancel(&state->http);
      if (state->condition_initialized)
        notify_state_change_locked(state);
      (void)pthread_mutex_unlock(&state->lock);
    }

    if (state->worker_created) {
      (void)pthread_join(state->worker, NULL);
      state->worker_created = false;
    }

    if (state->deadline_monitor_created) {
      (void)pthread_join(state->deadline_monitor, NULL);
      state->deadline_monitor_created = false;
    }
  }

  if (state->http_initialized) {
    sonbal_openai_http_finalize(&state->http);
    state->http_initialized = false;
  }

  release_storage(state);

  if (state->deadline_condition_initialized)
    (void)pthread_cond_destroy(&state->deadline_condition);
  if (state->condition_initialized)
    (void)pthread_cond_destroy(&state->condition);
  if (state->lock_initialized)
    (void)pthread_mutex_destroy(&state->lock);

  secure_zero(state, sizeof *state);
  free(state);
  *transport = NULL;
}
