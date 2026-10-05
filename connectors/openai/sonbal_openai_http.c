/* =========================================================================
 * sonbal_openai_http.c
 * Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
 * SPDX-License-Identifier: 0BSD
 * =========================================================================
 */
#define _POSIX_C_SOURCE 200809L

#include "sonbal_openai_http.h"

#include <curl/curl.h>
#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <time.h>

#define OPENAI_PRODUCTION_BASE_URL "https://api.openai.com"
#define HTTP_URL_BYTES 1536U
#define HTTP_HEADER_BYTES 1280U
#define HTTP_CONNECT_TIMEOUT_MS 10000L
#define HTTP_POLL_MARGIN_MS 5000U
#define HTTP_MAX_OPERATION_TIMEOUT_MS 600000L
#define HTTP_RETRY_AFTER_BYTES 128U

static pthread_mutex_t global_lock = PTHREAD_MUTEX_INITIALIZER;
static size_t global_users = 0;

struct response_sink {
  char *body;
  size_t capacity;
  size_t length;
  bool overflow;
  uint64_t headers_received_ns;
  bool retry_after_present;
  bool retry_after_valid;
  uint64_t retry_after_ms;
};

struct transfer_context {
  struct sonbal_openai_http_client *client;
  struct response_sink *sink;
};

static void
secure_zero(
  void *address,
  size_t length)
{
  volatile unsigned char *bytes = address;

  while (length > 0) {
    *bytes++ = 0;
    length--;
  }
}

static bool
bearer_token_value(
  const char *text,
  size_t length)
{
  size_t index;

  if (text == NULL || length == 0)
    return false;

  for (index = 0; index < length; index++) {
    unsigned char byte = (unsigned char)text[index];

    if (byte < 0x21 || byte > 0x7e)
      return false;
  }

  return true;
}

static bool
bounded_text(
  const char *text,
  size_t maximum,
  size_t *length)
{
  size_t value;

  if (text == NULL || maximum == 0)
    return false;

  value = strnlen(text, maximum + 1);
  if (value == 0 || value > maximum)
    return false;

  *length = value;
  return true;
}

static bool
http_field_value(
  const char *text,
  size_t length)
{
  size_t index;

  if (text == NULL || length == 0)
    return false;

  for (index = 0; index < length; index++) {
    unsigned char byte = (unsigned char)text[index];

    if (byte < 0x20 || byte == 0x7f)
      return false;
  }

  return true;
}

static bool
shard_token_value(
  const char *text,
  size_t length)
{
  size_t index;

  if (text == NULL || length == 0 || length > 1024)
    return false;

  for (index = 0; index < length; index++) {
    unsigned char byte = (unsigned char)text[index];

    if (byte < 0x21 || byte > 0x7e || byte == ',')
      return false;
  }

  return true;
}

static bool
allowed_base_url(
  const char *base_url,
  size_t length)
{
  static const char production[] = OPENAI_PRODUCTION_BASE_URL;

  if (length == sizeof production - 1 &&
      memcmp(base_url, production, sizeof production - 1) == 0)
    return true;

#ifdef SONBAL_OPENAI_HTTP_TESTING
  if (length > strlen("http://127.0.0.1:") &&
      strncmp(base_url, "http://127.0.0.1:",
              strlen("http://127.0.0.1:")) == 0)
    return true;

  if (length > strlen("http://[::1]:") &&
      strncmp(base_url, "http://[::1]:",
              strlen("http://[::1]:")) == 0)
    return true;
#endif

  return false;
}

static enum sonbal_openai_http_status
acquire_global(void)
{
  enum sonbal_openai_http_status status = SONBAL_OPENAI_HTTP_OK;

  if (pthread_mutex_lock(&global_lock) != 0)
    return SONBAL_OPENAI_HTTP_INITIALIZATION_FAILED;

  if (global_users == 0 &&
      curl_global_init(CURL_GLOBAL_DEFAULT) != CURLE_OK)
    status = SONBAL_OPENAI_HTTP_INITIALIZATION_FAILED;

  if (status == SONBAL_OPENAI_HTTP_OK)
    global_users++;

  (void)pthread_mutex_unlock(&global_lock);
  return status;
}

static void
release_global(void)
{
  if (pthread_mutex_lock(&global_lock) != 0)
    return;

  if (global_users > 0) {
    global_users--;
    if (global_users == 0)
      curl_global_cleanup();
  }

  (void)pthread_mutex_unlock(&global_lock);
}

static bool
monotonic_now_ns(
  uint64_t *value)
{
  struct timespec now;
  uint64_t seconds;

  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0 ||
      now.tv_sec < 0 || now.tv_nsec < 0 ||
      now.tv_nsec >= 1000000000L)
    return false;

  seconds = (uint64_t)now.tv_sec;
  if (seconds > UINT64_MAX / UINT64_C(1000000000))
    return false;

  *value =
    seconds * UINT64_C(1000000000) + (uint64_t)now.tv_nsec;
  return true;
}

static size_t
write_body(
  char *data,
  size_t size,
  size_t members,
  void *context)
{
  struct response_sink *sink = context;
  size_t bytes;

  if (members != 0 && size > SIZE_MAX / members)
    return 0;

  bytes = size * members;
  if (bytes > sink->capacity - sink->length) {
    sink->overflow = true;
    return 0;
  }

  if (bytes > 0)
    memcpy(sink->body + sink->length, data, bytes);
  sink->length += bytes;
  return bytes;
}

static void
parse_retry_after(
  struct response_sink *sink,
  const char *data,
  size_t bytes)
{
  static const char name[] = "Retry-After:";
  const char *value;
  size_t length;
  size_t index;
  uint64_t seconds = 0;
  bool digits = true;

  if (bytes < sizeof name - 1 ||
      strncasecmp(data, name, sizeof name - 1) != 0)
    return;

  sink->retry_after_present = true;
  sink->retry_after_valid = false;
  sink->retry_after_ms = 0;

  value = data + sizeof name - 1;
  length = bytes - (sizeof name - 1);

  while (length > 0 &&
         (*value == ' ' || *value == '\t')) {
    value++;
    length--;
  }

  while (length > 0 &&
         (value[length - 1] == '\r' ||
          value[length - 1] == '\n' ||
          value[length - 1] == ' ' ||
          value[length - 1] == '\t'))
    length--;

  if (length == 0 || length > HTTP_RETRY_AFTER_BYTES)
    return;

  for (index = 0; index < length; index++) {
    unsigned char byte = (unsigned char)value[index];

    if (byte < '0' || byte > '9') {
      digits = false;
      break;
    }

    if (seconds > (UINT64_MAX - (uint64_t)(byte - '0')) / 10)
      return;

    seconds =
      seconds * UINT64_C(10) + (uint64_t)(byte - '0');
  }

  if (digits) {
    if (seconds > UINT64_MAX / UINT64_C(1000))
      return;

    sink->retry_after_ms = seconds * UINT64_C(1000);
    sink->retry_after_valid = true;
    return;
  }

  {
    char text[HTTP_RETRY_AFTER_BYTES + 1];
    time_t parsed;
    time_t now;

    memcpy(text, value, length);
    text[length] = '\0';

    parsed = curl_getdate(text, NULL);
    if (parsed < 0)
      return;

    now = time(NULL);
    if (now == (time_t)-1 || parsed <= now)
      return;

    {
      uint64_t delta = (uint64_t)(parsed - now);

      if (delta > UINT64_MAX / UINT64_C(1000))
        return;

      sink->retry_after_ms = delta * UINT64_C(1000);
      sink->retry_after_valid = true;
    }
  }
}

static size_t
receive_header(
  char *data,
  size_t size,
  size_t members,
  void *context)
{
  struct response_sink *sink = context;
  size_t bytes;

  if (members != 0 && size > SIZE_MAX / members)
    return 0;

  bytes = size * members;

  if (bytes >= 5 && memcmp(data, "HTTP/", 5) == 0) {
    sink->retry_after_present = false;
    sink->retry_after_valid = false;
    sink->retry_after_ms = 0;
  } else {
    parse_retry_after(sink, data, bytes);
  }

  if ((bytes == 2 && data[0] == '\r' && data[1] == '\n') ||
      (bytes == 1 && data[0] == '\n')) {
    uint64_t receipt;

    if (monotonic_now_ns(&receipt))
      sink->headers_received_ns = receipt;
  }

  return bytes;
}

static int
transfer_progress(
  void *context,
  curl_off_t download_total,
  curl_off_t download_now,
  curl_off_t upload_total,
  curl_off_t upload_now)
{
  struct transfer_context *transfer = context;

  (void)download_total;
  (void)download_now;
  (void)upload_total;
  (void)upload_now;

  return atomic_load_explicit(
    &transfer->client->cancelled, memory_order_acquire) ? 1 : 0;
}

static bool
percent_encode_segment(
  const char *input,
  size_t length,
  char *output,
  size_t capacity,
  size_t *output_length)
{
  static const char digits[] = "0123456789ABCDEF";
  size_t source;
  size_t target = 0;

  for (source = 0; source < length; source++) {
    unsigned char byte = (unsigned char)input[source];
    bool unreserved =
      (byte >= 'a' && byte <= 'z') ||
      (byte >= 'A' && byte <= 'Z') ||
      (byte >= '0' && byte <= '9') ||
      byte == '-' || byte == '.' || byte == '_' || byte == '~';

    if (unreserved) {
      if (target >= capacity)
        return false;
      output[target++] = (char)byte;
    } else {
      if (capacity - target < 3)
        return false;
      output[target++] = '%';
      output[target++] = digits[byte >> 4];
      output[target++] = digits[byte & 0x0f];
    }
  }

  if (target >= capacity)
    return false;

  output[target] = '\0';
  *output_length = target;
  return true;
}

static CURLcode
set_common_options(
  struct sonbal_openai_http_client *client,
  const char *url,
  long timeout_ms,
  struct curl_slist *headers,
  struct transfer_context *transfer)
{
  CURL *easy = client->easy;
  CURLcode code;

#define SETOPT(option, value)                    \
  do {                                           \
    code = curl_easy_setopt(easy, option, value); \
    if (code != CURLE_OK)                        \
      return code;                               \
  } while (0)

  curl_easy_reset(easy);

  SETOPT(CURLOPT_URL, url);
  SETOPT(CURLOPT_HTTPHEADER, headers);
  SETOPT(CURLOPT_HTTPAUTH, (long)CURLAUTH_BEARER);
  SETOPT(CURLOPT_XOAUTH2_BEARER, client->credential);
  SETOPT(CURLOPT_NETRC, (long)CURL_NETRC_IGNORED);
  SETOPT(CURLOPT_NOSIGNAL, 1L);
  SETOPT(CURLOPT_FOLLOWLOCATION, 0L);
  SETOPT(CURLOPT_PROXY, "");
  SETOPT(CURLOPT_SUPPRESS_CONNECT_HEADERS, 1L);
  SETOPT(CURLOPT_SSL_VERIFYPEER, 1L);
  SETOPT(CURLOPT_SSL_VERIFYHOST, 2L);
  SETOPT(CURLOPT_CONNECTTIMEOUT_MS, HTTP_CONNECT_TIMEOUT_MS);
  SETOPT(CURLOPT_TIMEOUT_MS, timeout_ms);
  SETOPT(CURLOPT_TCP_KEEPALIVE, 1L);
  SETOPT(CURLOPT_WRITEFUNCTION, write_body);
  SETOPT(CURLOPT_WRITEDATA, transfer->sink);
  SETOPT(CURLOPT_HEADERFUNCTION, receive_header);
  SETOPT(CURLOPT_HEADERDATA, transfer->sink);
  SETOPT(CURLOPT_NOPROGRESS, 0L);
  SETOPT(CURLOPT_XFERINFOFUNCTION, transfer_progress);
  SETOPT(CURLOPT_XFERINFODATA, transfer);

#ifdef SONBAL_OPENAI_HTTP_TESTING
  SETOPT(CURLOPT_PROTOCOLS_STR, "http,https");
#else
  SETOPT(CURLOPT_PROTOCOLS_STR, "https");
#endif

#undef SETOPT

  return CURLE_OK;
}

static enum sonbal_openai_http_status
perform_request(
  struct sonbal_openai_http_client *client,
  const char *url,
  long timeout_ms,
  struct curl_slist *headers,
  bool post,
  const char *post_body,
  size_t post_body_length,
  char *body,
  size_t body_capacity,
  struct sonbal_openai_http_result *result)
{
  struct response_sink sink;
  struct transfer_context transfer;
  CURLcode code;
  long response_code = 0;

  if (body == NULL || body_capacity == 0 || result == NULL)
    return SONBAL_OPENAI_HTTP_INVALID_ARGUMENT;

  memset(result, 0, sizeof *result);
  memset(&sink, 0, sizeof sink);
  sink.body = body;
  sink.capacity = body_capacity;

  transfer.client = client;
  transfer.sink = &sink;

  code = set_common_options(
    client, url, timeout_ms, headers, &transfer);
  if (code != CURLE_OK) {
    result->status = SONBAL_OPENAI_HTTP_INITIALIZATION_FAILED;
    result->transport_code = (int)code;
    return result->status;
  }

  if (post) {
    curl_off_t post_size;

    if (post_body == NULL) {
      result->status = SONBAL_OPENAI_HTTP_INVALID_ARGUMENT;
      return result->status;
    }

    post_size = (curl_off_t)post_body_length;
    if (post_size < 0 || (size_t)post_size != post_body_length) {
      result->status = SONBAL_OPENAI_HTTP_INVALID_ARGUMENT;
      return result->status;
    }

    code = curl_easy_setopt(client->easy, CURLOPT_POST, 1L);
    if (code == CURLE_OK)
      code = curl_easy_setopt(
        client->easy, CURLOPT_POSTFIELDS, post_body);
    if (code == CURLE_OK)
      code = curl_easy_setopt(
        client->easy,
        CURLOPT_POSTFIELDSIZE_LARGE,
        post_size);
    if (code != CURLE_OK) {
      result->status = SONBAL_OPENAI_HTTP_INITIALIZATION_FAILED;
      result->transport_code = (int)code;
      return result->status;
    }
  }

  code = curl_easy_perform(client->easy);
  result->body_length = sink.length;
  result->headers_received_ns = sink.headers_received_ns;
  result->retry_after_present = sink.retry_after_present;
  result->retry_after_valid = sink.retry_after_valid;
  result->retry_after_ms = sink.retry_after_ms;
  result->transport_code = (int)code;

  if (sink.overflow) {
    result->status = SONBAL_OPENAI_HTTP_BODY_LIMIT;
    return result->status;
  }

  if (code == CURLE_ABORTED_BY_CALLBACK &&
      atomic_load_explicit(
        &client->cancelled, memory_order_acquire)) {
    result->status = SONBAL_OPENAI_HTTP_CANCELLED;
    return result->status;
  }

  if (code != CURLE_OK) {
    result->status = SONBAL_OPENAI_HTTP_TRANSPORT_FAILED;
    return result->status;
  }

  if (curl_easy_getinfo(
        client->easy, CURLINFO_RESPONSE_CODE, &response_code) != CURLE_OK) {
    result->status = SONBAL_OPENAI_HTTP_TRANSPORT_FAILED;
    return result->status;
  }

  result->response_code = response_code;
  result->status = SONBAL_OPENAI_HTTP_OK;
  return result->status;
}

enum sonbal_openai_http_status
sonbal_openai_http_initialize(
  struct sonbal_openai_http_client *client,
  const char *base_url,
  const char *tunnel_id,
  const char *credential,
  size_t credential_length,
  const char *client_name,
  const char *client_version)
{
  size_t base_url_length;
  size_t tunnel_id_length;
  size_t client_name_length;
  size_t client_version_length;
  enum sonbal_openai_http_status status;

  if (client == NULL ||
      !bounded_text(
        base_url,
        SONBAL_OPENAI_HTTP_MAX_BASE_URL_BYTES,
        &base_url_length) ||
      !bounded_text(tunnel_id, 256, &tunnel_id_length) ||
      !bounded_text(
        client_name,
        SONBAL_OPENAI_HTTP_MAX_CLIENT_NAME_BYTES,
        &client_name_length) ||
      !bounded_text(
        client_version,
        SONBAL_OPENAI_HTTP_MAX_CLIENT_VERSION_BYTES,
        &client_version_length) ||
      credential == NULL ||
      credential_length == 0 ||
      credential_length > SONBAL_OPENAI_HTTP_MAX_CREDENTIAL_BYTES ||
      !bearer_token_value(credential, credential_length) ||
      !http_field_value(client_name, client_name_length) ||
      !http_field_value(client_version, client_version_length) ||
      !allowed_base_url(base_url, base_url_length))
    return SONBAL_OPENAI_HTTP_INVALID_ARGUMENT;

  memset(client, 0, sizeof *client);
  atomic_init(&client->cancelled, false);

  memcpy(client->base_url, base_url, base_url_length + 1);
  client->base_url_length = base_url_length;

  memcpy(client->tunnel_id, tunnel_id, tunnel_id_length + 1);
  client->tunnel_id_length = tunnel_id_length;

  memcpy(client->client_name, client_name, client_name_length + 1);
  client->client_name_length = client_name_length;

  memcpy(
    client->client_version, client_version, client_version_length + 1);
  client->client_version_length = client_version_length;

  memcpy(client->credential, credential, credential_length);
  client->credential[credential_length] = '\0';
  client->credential_length = credential_length;

  status = acquire_global();
  if (status != SONBAL_OPENAI_HTTP_OK)
    goto fail;
  client->global_acquired = true;

  client->easy = curl_easy_init();
  if (client->easy == NULL) {
    status = SONBAL_OPENAI_HTTP_INITIALIZATION_FAILED;
    goto fail;
  }

  return SONBAL_OPENAI_HTTP_OK;

fail:
  sonbal_openai_http_finalize(client);
  return status;
}

void
sonbal_openai_http_cancel(
  struct sonbal_openai_http_client *client)
{
  if (client == NULL)
    return;

  atomic_store_explicit(
    &client->cancelled, true, memory_order_release);
}

void
sonbal_openai_http_reset_cancellation(
  struct sonbal_openai_http_client *client)
{
  if (client == NULL)
    return;

  atomic_store_explicit(
    &client->cancelled, false, memory_order_release);
}

enum sonbal_openai_http_status
sonbal_openai_http_poll(
  struct sonbal_openai_http_client *client,
  uint32_t limit,
  uint32_t timeout_ms,
  char *body,
  size_t body_capacity,
  struct sonbal_openai_http_result *result)
{
  char encoded_tunnel[3 * 256 + 1];
  char url[HTTP_URL_BYTES];
  char name_header[HTTP_HEADER_BYTES];
  char version_header[HTTP_HEADER_BYTES];
  char wire_version_header[HTTP_HEADER_BYTES];
  size_t encoded_length;
  struct curl_slist *headers = NULL;
  enum sonbal_openai_http_status status;
  long operation_timeout;
  int written;

  if (client == NULL || client->easy == NULL ||
      limit == 0 || limit > 25 ||
      timeout_ms == 0 ||
      timeout_ms > SONBAL_OPENAI_HTTP_MAX_POLL_TIMEOUT_MS)
    return SONBAL_OPENAI_HTTP_INVALID_ARGUMENT;

  if (!percent_encode_segment(
        client->tunnel_id,
        client->tunnel_id_length,
        encoded_tunnel,
        sizeof encoded_tunnel,
        &encoded_length))
    return SONBAL_OPENAI_HTTP_INVALID_ARGUMENT;
  (void)encoded_length;

  written = snprintf(
    url,
    sizeof url,
    "%s/v1/tunnels/%s/poll?limit=%u&timeout_ms=%u",
    client->base_url,
    encoded_tunnel,
    limit,
    timeout_ms);
  if (written < 0 || (size_t)written >= sizeof url)
    return SONBAL_OPENAI_HTTP_INVALID_ARGUMENT;

  written = snprintf(
    name_header,
    sizeof name_header,
    "X-Tunnel-Client-Name: %s",
    client->client_name);
  if (written < 0 || (size_t)written >= sizeof name_header)
    return SONBAL_OPENAI_HTTP_INVALID_ARGUMENT;

  written = snprintf(
    version_header,
    sizeof version_header,
    "X-Tunnel-Client-Version: %s",
    client->client_version);
  if (written < 0 || (size_t)written >= sizeof version_header)
    return SONBAL_OPENAI_HTTP_INVALID_ARGUMENT;

  written = snprintf(
    wire_version_header,
    sizeof wire_version_header,
    "X-Tunnel-Client-Wire-Protocol-Version: %s",
    SONBAL_OPENAI_HTTP_WIRE_PROTOCOL_VERSION);
  if (written < 0 ||
      (size_t)written >= sizeof wire_version_header)
    return SONBAL_OPENAI_HTTP_INVALID_ARGUMENT;

  headers = curl_slist_append(headers, "Accept: application/json");
  if (headers == NULL)
    return SONBAL_OPENAI_HTTP_INITIALIZATION_FAILED;

  {
    struct curl_slist *next = curl_slist_append(
      headers, name_header);
    if (next == NULL) {
      curl_slist_free_all(headers);
      return SONBAL_OPENAI_HTTP_INITIALIZATION_FAILED;
    }
    headers = next;
  }
  {
    struct curl_slist *next = curl_slist_append(
      headers, version_header);
    if (next == NULL) {
      curl_slist_free_all(headers);
      return SONBAL_OPENAI_HTTP_INITIALIZATION_FAILED;
    }
    headers = next;
  }
  {
    struct curl_slist *next = curl_slist_append(
      headers, wire_version_header);
    if (next == NULL) {
      curl_slist_free_all(headers);
      return SONBAL_OPENAI_HTTP_INITIALIZATION_FAILED;
    }
    headers = next;
  }

  if (timeout_ms >
      (uint32_t)(HTTP_MAX_OPERATION_TIMEOUT_MS - HTTP_POLL_MARGIN_MS))
    operation_timeout = HTTP_MAX_OPERATION_TIMEOUT_MS;
  else
    operation_timeout = (long)timeout_ms + HTTP_POLL_MARGIN_MS;
  status = perform_request(
    client,
    url,
    operation_timeout,
    headers,
    false,
    NULL,
    0,
    body,
    body_capacity,
    result);

  curl_slist_free_all(headers);
  return status;
}

enum sonbal_openai_http_status
sonbal_openai_http_post_response(
  struct sonbal_openai_http_client *client,
  const char *shard_token,
  const char *json_body,
  size_t json_body_length,
  uint32_t timeout_ms,
  char *body,
  size_t body_capacity,
  struct sonbal_openai_http_result *result)
{
  char encoded_tunnel[3 * 256 + 1];
  char url[HTTP_URL_BYTES];
  char shard_header[HTTP_HEADER_BYTES];
  char name_header[HTTP_HEADER_BYTES];
  char version_header[HTTP_HEADER_BYTES];
  char wire_version_header[HTTP_HEADER_BYTES];
  size_t encoded_length;
  size_t shard_length;
  struct curl_slist *headers = NULL;
  enum sonbal_openai_http_status status;
  int written;

  if (client == NULL || client->easy == NULL ||
      json_body == NULL || json_body_length == 0 ||
      timeout_ms == 0 ||
      !bounded_text(shard_token, 1024, &shard_length) ||
      !shard_token_value(shard_token, shard_length))
    return SONBAL_OPENAI_HTTP_INVALID_ARGUMENT;

  if (!percent_encode_segment(
        client->tunnel_id,
        client->tunnel_id_length,
        encoded_tunnel,
        sizeof encoded_tunnel,
        &encoded_length))
    return SONBAL_OPENAI_HTTP_INVALID_ARGUMENT;
  (void)encoded_length;

  written = snprintf(
    url,
    sizeof url,
    "%s/v1/tunnels/%s/response",
    client->base_url,
    encoded_tunnel);
  if (written < 0 || (size_t)written >= sizeof url)
    return SONBAL_OPENAI_HTTP_INVALID_ARGUMENT;

  written = snprintf(
    shard_header,
    sizeof shard_header,
    "X-Tunnel-Shard-Token: %s",
    shard_token);
  if (written < 0 || (size_t)written >= sizeof shard_header)
    return SONBAL_OPENAI_HTTP_INVALID_ARGUMENT;

  written = snprintf(
    name_header,
    sizeof name_header,
    "X-Tunnel-Client-Name: %s",
    client->client_name);
  if (written < 0 || (size_t)written >= sizeof name_header)
    return SONBAL_OPENAI_HTTP_INVALID_ARGUMENT;

  written = snprintf(
    version_header,
    sizeof version_header,
    "X-Tunnel-Client-Version: %s",
    client->client_version);
  if (written < 0 || (size_t)written >= sizeof version_header)
    return SONBAL_OPENAI_HTTP_INVALID_ARGUMENT;

  written = snprintf(
    wire_version_header,
    sizeof wire_version_header,
    "X-Tunnel-Client-Wire-Protocol-Version: %s",
    SONBAL_OPENAI_HTTP_WIRE_PROTOCOL_VERSION);
  if (written < 0 ||
      (size_t)written >= sizeof wire_version_header)
    return SONBAL_OPENAI_HTTP_INVALID_ARGUMENT;

#define APPEND_HEADER(line)                                      \
  do {                                                           \
    struct curl_slist *next = curl_slist_append(headers, line);  \
    if (next == NULL) {                                          \
      curl_slist_free_all(headers);                              \
      return SONBAL_OPENAI_HTTP_INITIALIZATION_FAILED;           \
    }                                                            \
    headers = next;                                              \
  } while (0)

  APPEND_HEADER("Accept: application/json");
  APPEND_HEADER("Content-Type: application/json");
  APPEND_HEADER(shard_header);
  APPEND_HEADER(name_header);
  APPEND_HEADER(version_header);
  APPEND_HEADER(wire_version_header);

#undef APPEND_HEADER

  status = perform_request(
    client,
    url,
    (long)timeout_ms,
    headers,
    true,
    json_body,
    json_body_length,
    body,
    body_capacity,
    result);

  curl_slist_free_all(headers);
  return status;
}

void
sonbal_openai_http_finalize(
  struct sonbal_openai_http_client *client)
{
  if (client == NULL)
    return;

  if (client->easy != NULL) {
    curl_easy_cleanup(client->easy);
    client->easy = NULL;
  }

  if (client->global_acquired) {
    client->global_acquired = false;
    release_global();
  }

  secure_zero(client->credential, sizeof client->credential);
  client->credential_length = 0;
  memset(client->base_url, 0, sizeof client->base_url);
  memset(client->tunnel_id, 0, sizeof client->tunnel_id);
  memset(client->client_name, 0, sizeof client->client_name);
  memset(client->client_version, 0, sizeof client->client_version);
}
