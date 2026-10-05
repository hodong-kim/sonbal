/* =========================================================================
 * sonbal_openai_protocol.c
 * Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
 * SPDX-License-Identifier: 0BSD
 * =========================================================================
 */
#include "sonbal_openai_protocol.h"

#include <limits.h>
#include <string.h>

#define JSON_MAX_DEPTH 64U
#define JSON_KEY_BYTES 64U

enum parse_result {
  PARSE_OK = 0,
  PARSE_JSON = 1,
  PARSE_LIMIT = 2
};

struct cursor {
  const unsigned char *data;
  size_t length;
  size_t position;
};

static void
skip_space (struct cursor *cursor)
{
  while (cursor->position < cursor->length) {
    unsigned char byte = cursor->data[cursor->position];

    if (byte != ' ' && byte != '\t' && byte != '\n' && byte != '\r')
      return;
    cursor->position++;
  }
}

static int
hex_value (unsigned char byte)
{
  if (byte >= '0' && byte <= '9')
    return (int)(byte - '0');
  if (byte >= 'a' && byte <= 'f')
    return 10 + (int)(byte - 'a');
  if (byte >= 'A' && byte <= 'F')
    return 10 + (int)(byte - 'A');
  return -1;
}

static enum parse_result
append_decoded (
  char *output,
  size_t capacity,
  size_t *length,
  bool *overflow,
  const unsigned char *bytes,
  size_t count)
{
  size_t index;

  for (index = 0; index < count; index++) {
    if (output == NULL) {
      (*length)++;
      continue;
    }

    if (capacity > 0 && *length < capacity - 1)
      output[*length] = (char)bytes[index];
    else
      *overflow = true;
    (*length)++;
  }

  return PARSE_OK;
}

static enum parse_result
append_codepoint (
  char *output,
  size_t capacity,
  size_t *length,
  bool *overflow,
  uint32_t codepoint)
{
  unsigned char bytes[4];
  size_t count;

  if (codepoint <= UINT32_C(0x7f)) {
    bytes[0] = (unsigned char)codepoint;
    count = 1;
  } else if (codepoint <= UINT32_C(0x7ff)) {
    bytes[0] = (unsigned char)(UINT32_C(0xc0) | (codepoint >> 6));
    bytes[1] = (unsigned char)(UINT32_C(0x80) | (codepoint & 0x3f));
    count = 2;
  } else if (codepoint <= UINT32_C(0xffff)) {
    if (codepoint >= UINT32_C(0xd800) &&
        codepoint <= UINT32_C(0xdfff))
      return PARSE_JSON;

    bytes[0] = (unsigned char)(UINT32_C(0xe0) | (codepoint >> 12));
    bytes[1] =
      (unsigned char)(UINT32_C(0x80) | ((codepoint >> 6) & 0x3f));
    bytes[2] = (unsigned char)(UINT32_C(0x80) | (codepoint & 0x3f));
    count = 3;
  } else if (codepoint <= UINT32_C(0x10ffff)) {
    bytes[0] = (unsigned char)(UINT32_C(0xf0) | (codepoint >> 18));
    bytes[1] =
      (unsigned char)(UINT32_C(0x80) | ((codepoint >> 12) & 0x3f));
    bytes[2] =
      (unsigned char)(UINT32_C(0x80) | ((codepoint >> 6) & 0x3f));
    bytes[3] = (unsigned char)(UINT32_C(0x80) | (codepoint & 0x3f));
    count = 4;
  } else {
    return PARSE_JSON;
  }

  return append_decoded(
    output, capacity, length, overflow, bytes, count);
}

static enum parse_result
read_hex_quad (struct cursor *cursor, uint32_t *value)
{
  unsigned index;
  uint32_t result = 0;

  if (cursor->length - cursor->position < 4)
    return PARSE_JSON;

  for (index = 0; index < 4; index++) {
    int digit = hex_value(cursor->data[cursor->position + index]);

    if (digit < 0)
      return PARSE_JSON;
    result = (result << 4) | (uint32_t)digit;
  }

  cursor->position += 4;
  *value = result;
  return PARSE_OK;
}

static enum parse_result
copy_utf8_sequence (
  struct cursor *cursor,
  char *output,
  size_t capacity,
  size_t *length,
  bool *overflow)
{
  unsigned char first;
  unsigned char bytes[4];
  size_t count;
  size_t index;
  uint32_t codepoint;

  if (cursor->position >= cursor->length)
    return PARSE_JSON;

  first = cursor->data[cursor->position];

  if (first >= 0xc2 && first <= 0xdf) {
    count = 2;
    codepoint = first & 0x1f;
  } else if (first >= 0xe0 && first <= 0xef) {
    count = 3;
    codepoint = first & 0x0f;
  } else if (first >= 0xf0 && first <= 0xf4) {
    count = 4;
    codepoint = first & 0x07;
  } else {
    return PARSE_JSON;
  }

  if (cursor->length - cursor->position < count)
    return PARSE_JSON;

  bytes[0] = first;
  for (index = 1; index < count; index++) {
    unsigned char byte = cursor->data[cursor->position + index];

    if ((byte & 0xc0) != 0x80)
      return PARSE_JSON;
    bytes[index] = byte;
    codepoint = (codepoint << 6) | (byte & 0x3f);
  }

  if ((count == 3 && codepoint < UINT32_C(0x800)) ||
      (count == 4 && codepoint < UINT32_C(0x10000)) ||
      codepoint > UINT32_C(0x10ffff) ||
      (codepoint >= UINT32_C(0xd800) &&
       codepoint <= UINT32_C(0xdfff)))
    return PARSE_JSON;

  cursor->position += count;
  return append_decoded(
    output, capacity, length, overflow, bytes, count);
}

static enum parse_result
read_string (
  struct cursor *cursor,
  char *output,
  size_t capacity,
  size_t *decoded_length,
  bool *overflow)
{
  size_t length = 0;
  bool did_overflow = false;

  skip_space(cursor);
  if (cursor->position >= cursor->length ||
      cursor->data[cursor->position] != '"')
    return PARSE_JSON;

  cursor->position++;

  while (cursor->position < cursor->length) {
    unsigned char byte = cursor->data[cursor->position++];

    if (byte == '"') {
      if (output != NULL && capacity > 0) {
        size_t terminator = length < capacity ? length : capacity - 1;
        output[terminator] = '\0';
      }
      *decoded_length = length;
      *overflow = did_overflow;
      return PARSE_OK;
    }

    if (byte < 0x20)
      return PARSE_JSON;

    if (byte == '\\') {
      unsigned char escaped;
      unsigned char translated;
      uint32_t codepoint;
      enum parse_result status;

      if (cursor->position >= cursor->length)
        return PARSE_JSON;
      escaped = cursor->data[cursor->position++];

      switch (escaped) {
        case '"':
        case '\\':
        case '/':
          translated = escaped;
          status = append_decoded(
            output, capacity, &length, &did_overflow,
            &translated, 1);
          break;
        case 'b':
          translated = '\b';
          status = append_decoded(
            output, capacity, &length, &did_overflow,
            &translated, 1);
          break;
        case 'f':
          translated = '\f';
          status = append_decoded(
            output, capacity, &length, &did_overflow,
            &translated, 1);
          break;
        case 'n':
          translated = '\n';
          status = append_decoded(
            output, capacity, &length, &did_overflow,
            &translated, 1);
          break;
        case 'r':
          translated = '\r';
          status = append_decoded(
            output, capacity, &length, &did_overflow,
            &translated, 1);
          break;
        case 't':
          translated = '\t';
          status = append_decoded(
            output, capacity, &length, &did_overflow,
            &translated, 1);
          break;
        case 'u': {
          uint32_t first;

          status = read_hex_quad(cursor, &first);
          if (status != PARSE_OK)
            return status;

          if (first >= UINT32_C(0xd800) &&
              first <= UINT32_C(0xdbff)) {
            uint32_t second;

            if (cursor->length - cursor->position < 6 ||
                cursor->data[cursor->position] != '\\' ||
                cursor->data[cursor->position + 1] != 'u')
              return PARSE_JSON;
            cursor->position += 2;

            status = read_hex_quad(cursor, &second);
            if (status != PARSE_OK ||
                second < UINT32_C(0xdc00) ||
                second > UINT32_C(0xdfff))
              return PARSE_JSON;

            codepoint =
              UINT32_C(0x10000) +
              ((first - UINT32_C(0xd800)) << 10) +
              (second - UINT32_C(0xdc00));
          } else if (first >= UINT32_C(0xdc00) &&
                     first <= UINT32_C(0xdfff)) {
            return PARSE_JSON;
          } else {
            codepoint = first;
          }

          status = append_codepoint(
            output, capacity, &length, &did_overflow, codepoint);
          break;
        }
        default:
          return PARSE_JSON;
      }

      if (status != PARSE_OK)
        return status;
    } else if (byte < 0x80) {
      enum parse_result status = append_decoded(
        output, capacity, &length, &did_overflow, &byte, 1);

      if (status != PARSE_OK)
        return status;
    } else {
      cursor->position--;
      if (copy_utf8_sequence(
            cursor, output, capacity, &length, &did_overflow) !=
          PARSE_OK)
        return PARSE_JSON;
    }
  }

  return PARSE_JSON;
}

static bool
consume_literal (struct cursor *cursor, const char *literal)
{
  size_t length = strlen(literal);

  if (cursor->length - cursor->position < length)
    return false;
  if (memcmp(cursor->data + cursor->position, literal, length) != 0)
    return false;

  cursor->position += length;
  return true;
}

static enum parse_result
skip_number (struct cursor *cursor)
{
  size_t start;

  skip_space(cursor);
  start = cursor->position;

  if (cursor->position < cursor->length &&
      cursor->data[cursor->position] == '-')
    cursor->position++;

  if (cursor->position >= cursor->length)
    return PARSE_JSON;

  if (cursor->data[cursor->position] == '0') {
    cursor->position++;
    if (cursor->position < cursor->length &&
        cursor->data[cursor->position] >= '0' &&
        cursor->data[cursor->position] <= '9')
      return PARSE_JSON;
  } else if (cursor->data[cursor->position] >= '1' &&
             cursor->data[cursor->position] <= '9') {
    do {
      cursor->position++;
    } while (cursor->position < cursor->length &&
             cursor->data[cursor->position] >= '0' &&
             cursor->data[cursor->position] <= '9');
  } else {
    return PARSE_JSON;
  }

  if (cursor->position < cursor->length &&
      cursor->data[cursor->position] == '.') {
    cursor->position++;
    if (cursor->position >= cursor->length ||
        cursor->data[cursor->position] < '0' ||
        cursor->data[cursor->position] > '9')
      return PARSE_JSON;

    do {
      cursor->position++;
    } while (cursor->position < cursor->length &&
             cursor->data[cursor->position] >= '0' &&
             cursor->data[cursor->position] <= '9');
  }

  if (cursor->position < cursor->length &&
      (cursor->data[cursor->position] == 'e' ||
       cursor->data[cursor->position] == 'E')) {
    cursor->position++;
    if (cursor->position < cursor->length &&
        (cursor->data[cursor->position] == '+' ||
         cursor->data[cursor->position] == '-'))
      cursor->position++;

    if (cursor->position >= cursor->length ||
        cursor->data[cursor->position] < '0' ||
        cursor->data[cursor->position] > '9')
      return PARSE_JSON;

    do {
      cursor->position++;
    } while (cursor->position < cursor->length &&
             cursor->data[cursor->position] >= '0' &&
             cursor->data[cursor->position] <= '9');
  }

  return cursor->position > start ? PARSE_OK : PARSE_JSON;
}

static enum parse_result
skip_value (struct cursor *cursor, unsigned depth);

static enum parse_result
skip_array (struct cursor *cursor, unsigned depth)
{
  skip_space(cursor);
  if (cursor->position >= cursor->length ||
      cursor->data[cursor->position] != '[')
    return PARSE_JSON;

  if (depth >= JSON_MAX_DEPTH)
    return PARSE_LIMIT;

  cursor->position++;
  skip_space(cursor);
  if (cursor->position < cursor->length &&
      cursor->data[cursor->position] == ']') {
    cursor->position++;
    return PARSE_OK;
  }

  for (;;) {
    enum parse_result status = skip_value(cursor, depth + 1);

    if (status != PARSE_OK)
      return status;

    skip_space(cursor);
    if (cursor->position >= cursor->length)
      return PARSE_JSON;
    if (cursor->data[cursor->position] == ']') {
      cursor->position++;
      return PARSE_OK;
    }
    if (cursor->data[cursor->position] != ',')
      return PARSE_JSON;
    cursor->position++;
  }
}

static enum parse_result
skip_object (struct cursor *cursor, unsigned depth)
{
  char key[JSON_KEY_BYTES + 1];
  size_t key_length;
  bool key_overflow;

  skip_space(cursor);
  if (cursor->position >= cursor->length ||
      cursor->data[cursor->position] != '{')
    return PARSE_JSON;

  if (depth >= JSON_MAX_DEPTH)
    return PARSE_LIMIT;

  cursor->position++;
  skip_space(cursor);
  if (cursor->position < cursor->length &&
      cursor->data[cursor->position] == '}') {
    cursor->position++;
    return PARSE_OK;
  }

  for (;;) {
    enum parse_result status = read_string(
      cursor, key, sizeof key, &key_length, &key_overflow);

    (void)key_length;
    (void)key_overflow;
    if (status != PARSE_OK)
      return status;

    skip_space(cursor);
    if (cursor->position >= cursor->length ||
        cursor->data[cursor->position] != ':')
      return PARSE_JSON;
    cursor->position++;

    status = skip_value(cursor, depth + 1);
    if (status != PARSE_OK)
      return status;

    skip_space(cursor);
    if (cursor->position >= cursor->length)
      return PARSE_JSON;
    if (cursor->data[cursor->position] == '}') {
      cursor->position++;
      return PARSE_OK;
    }
    if (cursor->data[cursor->position] != ',')
      return PARSE_JSON;
    cursor->position++;
  }
}

static enum parse_result
skip_value (struct cursor *cursor, unsigned depth)
{
  skip_space(cursor);
  if (cursor->position >= cursor->length)
    return PARSE_JSON;

  switch (cursor->data[cursor->position]) {
    case '"': {
      size_t length;
      bool overflow;
      return read_string(cursor, NULL, 0, &length, &overflow);
    }
    case '{':
      return skip_object(cursor, depth);
    case '[':
      return skip_array(cursor, depth);
    case 't':
      return consume_literal(cursor, "true") ? PARSE_OK : PARSE_JSON;
    case 'f':
      return consume_literal(cursor, "false") ? PARSE_OK : PARSE_JSON;
    case 'n':
      return consume_literal(cursor, "null") ? PARSE_OK : PARSE_JSON;
    default:
      return skip_number(cursor);
  }
}

static bool
key_equals (
  const char *key,
  size_t key_length,
  bool overflow,
  const char *expected)
{
  size_t expected_length = strlen(expected);

  return !overflow &&
    key_length == expected_length &&
    memcmp(key, expected, expected_length) == 0;
}

static enum parse_result
read_bounded_string (
  struct cursor *cursor,
  char *target,
  size_t capacity,
  size_t *length)
{
  bool overflow;
  enum parse_result status = read_string(
    cursor, target, capacity, length, &overflow);

  if (status != PARSE_OK)
    return status;
  return overflow ? PARSE_LIMIT : PARSE_OK;
}

static enum parse_result
read_bounded_uint32 (
  struct cursor *cursor,
  uint32_t minimum,
  uint32_t maximum,
  uint32_t *value)
{
  size_t start;
  size_t end;
  size_t index;
  uint64_t result = 0;
  enum parse_result status;

  skip_space(cursor);
  start = cursor->position;
  status = skip_number(cursor);
  if (status != PARSE_OK)
    return status;
  end = cursor->position;

  if (end == start)
    return PARSE_JSON;

  for (index = start; index < end; index++) {
    unsigned char byte = cursor->data[index];

    uint64_t digit;

    if (byte < '0' || byte > '9')
      return PARSE_JSON;

    digit = (uint64_t)(byte - '0');
    if (result > ((uint64_t)maximum - digit) / UINT64_C(10))
      return PARSE_LIMIT;
    result = (result * UINT64_C(10)) + digit;
  }

  if (result < minimum)
    return PARSE_LIMIT;

  *value = (uint32_t)result;
  return PARSE_OK;
}

bool
sonbal_openai_parse_response_timeout (
  const char *text,
  size_t length,
  uint64_t *nanoseconds)
{
  size_t index = 0;
  uint64_t value = 0;
  uint64_t multiplier;

  if (text == NULL || nanoseconds == NULL || length < 2)
    return false;

  while (index < length && text[index] >= '0' && text[index] <= '9') {
    uint64_t digit = (uint64_t)(text[index] - '0');

    if (value > (UINT64_MAX - digit) / UINT64_C(10))
      return false;
    value = value * UINT64_C(10) + digit;
    index++;
  }

  if (index == 0 || index >= length)
    return false;

  if (length - index == 2 &&
      text[index] == 'n' && text[index + 1] == 's') {
    multiplier = UINT64_C(1);
  } else if (length - index == 2 &&
             text[index] == 'u' && text[index + 1] == 's') {
    multiplier = UINT64_C(1000);
  } else if (length - index == 2 &&
             text[index] == 'm' && text[index + 1] == 's') {
    multiplier = UINT64_C(1000000);
  } else if (length - index == 1 && text[index] == 's') {
    multiplier = UINT64_C(1000000000);
  } else if (length - index == 1 && text[index] == 'm') {
    multiplier = UINT64_C(60000000000);
  } else if (length - index == 1 && text[index] == 'h') {
    multiplier = UINT64_C(3600000000000);
  } else {
    return false;
  }

  if (value > UINT64_MAX / multiplier)
    return false;

  *nanoseconds = value * multiplier;
  return true;
}

static enum parse_result
read_timeout (
  struct cursor *cursor,
  struct sonbal_openai_timeout *timeout)
{
  char text[SONBAL_OPENAI_MAX_TIMEOUT_TEXT_BYTES + 1];
  size_t length;
  bool overflow;

  skip_space(cursor);

  if (cursor->position < cursor->length &&
      cursor->data[cursor->position] == 'n') {
    if (!consume_literal(cursor, "null"))
      return PARSE_JSON;
    timeout->present = false;
    timeout->valid = false;
    timeout->nanoseconds = 0;
    return PARSE_OK;
  }

  if (cursor->position >= cursor->length ||
      cursor->data[cursor->position] != '"') {
    enum parse_result status = skip_value(cursor, 0);

    if (status != PARSE_OK)
      return status;
    timeout->present = true;
    timeout->valid = false;
    timeout->nanoseconds = 0;
    return PARSE_OK;
  }

  if (read_string(
        cursor, text, sizeof text, &length, &overflow) != PARSE_OK)
    return PARSE_JSON;

  timeout->present = true;
  timeout->valid =
    !overflow &&
    sonbal_openai_parse_response_timeout(
      text, length, &timeout->nanoseconds);
  if (!timeout->valid)
    timeout->nanoseconds = 0;

  return PARSE_OK;
}

static enum parse_result
parse_command (
  struct cursor *cursor,
  size_t maximum_jsonrpc_bytes,
  struct sonbal_openai_command *command)
{
  enum {
    SEEN_REQUEST_ID = 1U << 0,
    SEEN_SHARD_TOKEN = 1U << 1,
    SEEN_COMMAND_TYPE = 1U << 2,
    SEEN_CHANNEL = 1U << 3,
    SEEN_CREATED_AT = 1U << 4,
    SEEN_TIMEOUT = 1U << 5,
    SEEN_HEADERS = 1U << 6,
    SEEN_JSONRPC = 1U << 7
  };

  unsigned seen = 0;
  char key[JSON_KEY_BYTES + 1];
  char command_type[JSON_KEY_BYTES + 1];
  size_t key_length;
  size_t command_type_length = 0;
  bool key_overflow;
  bool command_type_overflow = false;

  memset(command, 0, sizeof *command);
  memcpy(command->channel, "main", 4);
  command->channel_length = 4;

  skip_space(cursor);
  if (cursor->position >= cursor->length ||
      cursor->data[cursor->position] != '{')
    return PARSE_JSON;
  cursor->position++;

  skip_space(cursor);
  if (cursor->position < cursor->length &&
      cursor->data[cursor->position] == '}')
    return PARSE_JSON;

  for (;;) {
    enum parse_result status = read_string(
      cursor, key, sizeof key, &key_length, &key_overflow);

    if (status != PARSE_OK)
      return status;

    skip_space(cursor);
    if (cursor->position >= cursor->length ||
        cursor->data[cursor->position] != ':')
      return PARSE_JSON;
    cursor->position++;

    if (key_equals(
          key, key_length, key_overflow, "request_id")) {
      if ((seen & SEEN_REQUEST_ID) != 0)
        return PARSE_JSON;
      seen |= SEEN_REQUEST_ID;
      status = read_bounded_string(
        cursor,
        command->request_id,
        sizeof command->request_id,
        &command->request_id_length);
    } else if (key_equals(
                 key, key_length, key_overflow, "shard_token")) {
      if ((seen & SEEN_SHARD_TOKEN) != 0)
        return PARSE_JSON;
      seen |= SEEN_SHARD_TOKEN;
      status = read_bounded_string(
        cursor,
        command->shard_token,
        sizeof command->shard_token,
        &command->shard_token_length);
    } else if (key_equals(
                 key, key_length, key_overflow, "command_type")) {
      if ((seen & SEEN_COMMAND_TYPE) != 0)
        return PARSE_JSON;
      seen |= SEEN_COMMAND_TYPE;
      status = read_string(
        cursor,
        command_type,
        sizeof command_type,
        &command_type_length,
        &command_type_overflow);
      if (status == PARSE_OK && command_type_overflow)
        status = PARSE_LIMIT;
    } else if (key_equals(
                 key, key_length, key_overflow, "channel")) {
      if ((seen & SEEN_CHANNEL) != 0)
        return PARSE_JSON;
      seen |= SEEN_CHANNEL;
      status = read_bounded_string(
        cursor,
        command->channel,
        sizeof command->channel,
        &command->channel_length);
    } else if (key_equals(
                 key, key_length, key_overflow, "created_at")) {
      if ((seen & SEEN_CREATED_AT) != 0)
        return PARSE_JSON;
      seen |= SEEN_CREATED_AT;
      status = read_bounded_string(
        cursor,
        command->created_at,
        sizeof command->created_at,
        &command->created_at_length);
      if (status == PARSE_OK && command->created_at_length == 0)
        status = PARSE_JSON;
    } else if (key_equals(
                 key, key_length, key_overflow, "response_timeout")) {
      if ((seen & SEEN_TIMEOUT) != 0)
        return PARSE_JSON;
      seen |= SEEN_TIMEOUT;
      status = read_timeout(cursor, &command->response_timeout);
    } else if (key_equals(
                 key, key_length, key_overflow, "headers")) {
      size_t start;
      unsigned char first;

      if ((seen & SEEN_HEADERS) != 0)
        return PARSE_JSON;
      seen |= SEEN_HEADERS;
      skip_space(cursor);
      start = cursor->position;
      if (start >= cursor->length)
        return PARSE_JSON;
      first = cursor->data[start];
      status = skip_value(cursor, 0);
      if (status == PARSE_OK) {
        if (first != '{')
          return PARSE_JSON;
        command->headers = (const char *)cursor->data + start;
        command->headers_length = cursor->position - start;
      }
    } else if (key_equals(
                 key, key_length, key_overflow, "jsonrpc")) {
      size_t start;
      unsigned char first;

      if ((seen & SEEN_JSONRPC) != 0)
        return PARSE_JSON;
      seen |= SEEN_JSONRPC;
      skip_space(cursor);
      start = cursor->position;
      if (start >= cursor->length)
        return PARSE_JSON;
      first = cursor->data[start];
      status = skip_value(cursor, 0);
      if (status == PARSE_OK) {
        size_t raw_length = cursor->position - start;

        if (first != '{')
          return PARSE_JSON;
        if (raw_length > maximum_jsonrpc_bytes)
          return PARSE_LIMIT;
        command->jsonrpc = (const char *)cursor->data + start;
        command->jsonrpc_length = raw_length;
      }
    } else {
      status = skip_value(cursor, 0);
    }

    if (status != PARSE_OK)
      return status;

    skip_space(cursor);
    if (cursor->position >= cursor->length)
      return PARSE_JSON;
    if (cursor->data[cursor->position] == '}') {
      cursor->position++;
      break;
    }
    if (cursor->data[cursor->position] != ',')
      return PARSE_JSON;
    cursor->position++;
  }

  if ((seen & (SEEN_REQUEST_ID |
               SEEN_SHARD_TOKEN |
               SEEN_CREATED_AT)) !=
      (SEEN_REQUEST_ID |
       SEEN_SHARD_TOKEN |
       SEEN_CREATED_AT))
    return PARSE_JSON;

  if ((seen & SEEN_COMMAND_TYPE) == 0) {
    if ((seen & SEEN_JSONRPC) == 0)
      return PARSE_JSON;
    memcpy(command_type, "jsonrpc", sizeof "jsonrpc");
    command_type_length = strlen("jsonrpc");
  }

  if (command_type_length == strlen("jsonrpc") &&
      memcmp(command_type, "jsonrpc", command_type_length) == 0) {
    command->kind = SONBAL_OPENAI_COMMAND_JSONRPC;
    if ((seen & SEEN_JSONRPC) == 0)
      return PARSE_JSON;
  } else if (
    command_type_length == strlen("session_termination") &&
    memcmp(
      command_type, "session_termination", command_type_length) == 0) {
    command->kind = SONBAL_OPENAI_COMMAND_SESSION_TERMINATION;
    command->jsonrpc = NULL;
    command->jsonrpc_length = 0;
  } else {
    command->kind = SONBAL_OPENAI_COMMAND_UNKNOWN;
    command->jsonrpc = NULL;
    command->jsonrpc_length = 0;
  }

  return PARSE_OK;
}

enum sonbal_openai_protocol_status
sonbal_openai_parse_poll_response (
  const char *json,
  size_t length,
  size_t maximum_jsonrpc_bytes,
  sonbal_openai_command_callback callback,
  void *context,
  size_t *command_count)
{
  struct cursor cursor;
  char key[JSON_KEY_BYTES + 1];
  size_t key_length;
  bool key_overflow;
  bool commands_seen = false;
  size_t count = 0;

  if (json == NULL || callback == NULL || command_count == NULL ||
      maximum_jsonrpc_bytes == 0)
    return SONBAL_OPENAI_PROTOCOL_INVALID_ENVELOPE;

  *command_count = 0;
  cursor.data = (const unsigned char *)json;
  cursor.length = length;
  cursor.position = 0;

  skip_space(&cursor);
  if (cursor.position >= cursor.length ||
      cursor.data[cursor.position] != '{')
    return SONBAL_OPENAI_PROTOCOL_INVALID_JSON;
  cursor.position++;

  skip_space(&cursor);
  if (cursor.position < cursor.length &&
      cursor.data[cursor.position] == '}')
    return SONBAL_OPENAI_PROTOCOL_INVALID_ENVELOPE;

  for (;;) {
    enum parse_result status = read_string(
      &cursor, key, sizeof key, &key_length, &key_overflow);

    if (status != PARSE_OK)
      return status == PARSE_LIMIT ?
        SONBAL_OPENAI_PROTOCOL_LIMIT_EXCEEDED :
        SONBAL_OPENAI_PROTOCOL_INVALID_JSON;

    skip_space(&cursor);
    if (cursor.position >= cursor.length ||
        cursor.data[cursor.position] != ':')
      return SONBAL_OPENAI_PROTOCOL_INVALID_JSON;
    cursor.position++;

    if (key_equals(
          key, key_length, key_overflow, "commands")) {
      if (commands_seen)
        return SONBAL_OPENAI_PROTOCOL_INVALID_ENVELOPE;
      commands_seen = true;

      skip_space(&cursor);
      if (cursor.position >= cursor.length ||
          cursor.data[cursor.position] != '[')
        return SONBAL_OPENAI_PROTOCOL_INVALID_ENVELOPE;
      cursor.position++;

      skip_space(&cursor);
      if (cursor.position >= cursor.length)
        return SONBAL_OPENAI_PROTOCOL_INVALID_JSON;

      if (cursor.data[cursor.position] == ']') {
        cursor.position++;
      } else {
        for (;;) {
          struct sonbal_openai_command command;

          status = parse_command(
            &cursor, maximum_jsonrpc_bytes, &command);
          if (status != PARSE_OK) {
            if (status == PARSE_LIMIT)
              return SONBAL_OPENAI_PROTOCOL_LIMIT_EXCEEDED;
            if (cursor.position >= cursor.length)
              return SONBAL_OPENAI_PROTOCOL_INVALID_JSON;
            return SONBAL_OPENAI_PROTOCOL_INVALID_ENVELOPE;
          }

          if (!callback(&command, context))
            return SONBAL_OPENAI_PROTOCOL_LIMIT_EXCEEDED;
          count++;

          skip_space(&cursor);
          if (cursor.position >= cursor.length)
            return SONBAL_OPENAI_PROTOCOL_INVALID_JSON;
          if (cursor.data[cursor.position] == ']') {
            cursor.position++;
            break;
          }
          if (cursor.data[cursor.position] != ',')
            return SONBAL_OPENAI_PROTOCOL_INVALID_JSON;
          cursor.position++;
        }
      }
    } else {
      status = skip_value(&cursor, 0);
      if (status != PARSE_OK)
        return status == PARSE_LIMIT ?
          SONBAL_OPENAI_PROTOCOL_LIMIT_EXCEEDED :
          SONBAL_OPENAI_PROTOCOL_INVALID_JSON;
    }

    skip_space(&cursor);
    if (cursor.position >= cursor.length)
      return SONBAL_OPENAI_PROTOCOL_INVALID_JSON;
    if (cursor.data[cursor.position] == '}') {
      cursor.position++;
      break;
    }
    if (cursor.data[cursor.position] != ',')
      return SONBAL_OPENAI_PROTOCOL_INVALID_JSON;
    cursor.position++;
  }

  skip_space(&cursor);
  if (cursor.position != cursor.length)
    return SONBAL_OPENAI_PROTOCOL_INVALID_JSON;
  if (!commands_seen)
    return SONBAL_OPENAI_PROTOCOL_INVALID_ENVELOPE;

  *command_count = count;
  return SONBAL_OPENAI_PROTOCOL_OK;
}

enum sonbal_openai_protocol_status
sonbal_openai_parse_configuration (
  const char *json,
  size_t length,
  struct sonbal_openai_configuration *configuration)
{
  enum {
    SEEN_TUNNEL_ID = 1U << 0,
    SEEN_POLL_LIMIT = 1U << 1,
    SEEN_POLL_TIMEOUT = 1U << 2
  };

  struct cursor cursor;
  char key[JSON_KEY_BYTES + 1];
  size_t key_length;
  bool key_overflow;
  unsigned seen = 0;

  if (json == NULL || configuration == NULL ||
      length == 0 || length > SONBAL_OPENAI_MAX_CONFIG_BYTES)
    return SONBAL_OPENAI_PROTOCOL_INVALID_ENVELOPE;

  memset(configuration, 0, sizeof *configuration);
  configuration->poll_limit = SONBAL_OPENAI_DEFAULT_POLL_LIMIT;
  configuration->poll_timeout_ms =
    SONBAL_OPENAI_DEFAULT_POLL_TIMEOUT_MS;

  cursor.data = (const unsigned char *)json;
  cursor.length = length;
  cursor.position = 0;

  skip_space(&cursor);
  if (cursor.position >= cursor.length ||
      cursor.data[cursor.position] != '{')
    return SONBAL_OPENAI_PROTOCOL_INVALID_JSON;
  cursor.position++;

  skip_space(&cursor);
  if (cursor.position < cursor.length &&
      cursor.data[cursor.position] == '}')
    return SONBAL_OPENAI_PROTOCOL_INVALID_ENVELOPE;

  for (;;) {
    enum parse_result status = read_string(
      &cursor, key, sizeof key, &key_length, &key_overflow);

    if (status != PARSE_OK)
      return SONBAL_OPENAI_PROTOCOL_INVALID_JSON;

    skip_space(&cursor);
    if (cursor.position >= cursor.length ||
        cursor.data[cursor.position] != ':')
      return SONBAL_OPENAI_PROTOCOL_INVALID_JSON;
    cursor.position++;

    if (key_equals(
          key, key_length, key_overflow, "tunnel_id")) {
      if ((seen & SEEN_TUNNEL_ID) != 0)
        return SONBAL_OPENAI_PROTOCOL_INVALID_ENVELOPE;
      seen |= SEEN_TUNNEL_ID;
      status = read_bounded_string(
        &cursor,
        configuration->tunnel_id,
        sizeof configuration->tunnel_id,
        &configuration->tunnel_id_length);
      if (status != PARSE_OK ||
          configuration->tunnel_id_length == 0)
        return SONBAL_OPENAI_PROTOCOL_INVALID_ENVELOPE;
    } else if (key_equals(
                 key, key_length, key_overflow, "poll_limit")) {
      if ((seen & SEEN_POLL_LIMIT) != 0)
        return SONBAL_OPENAI_PROTOCOL_INVALID_ENVELOPE;
      seen |= SEEN_POLL_LIMIT;
      status = read_bounded_uint32(
        &cursor,
        1,
        SONBAL_OPENAI_MAX_POLL_LIMIT,
        &configuration->poll_limit);
      if (status != PARSE_OK)
        return SONBAL_OPENAI_PROTOCOL_INVALID_ENVELOPE;
    } else if (key_equals(
                 key, key_length, key_overflow, "poll_timeout_ms")) {
      if ((seen & SEEN_POLL_TIMEOUT) != 0)
        return SONBAL_OPENAI_PROTOCOL_INVALID_ENVELOPE;
      seen |= SEEN_POLL_TIMEOUT;
      status = read_bounded_uint32(
        &cursor,
        1,
        SONBAL_OPENAI_MAX_POLL_TIMEOUT_MS,
        &configuration->poll_timeout_ms);
      if (status != PARSE_OK)
        return SONBAL_OPENAI_PROTOCOL_INVALID_ENVELOPE;
    } else {
      return SONBAL_OPENAI_PROTOCOL_INVALID_ENVELOPE;
    }

    skip_space(&cursor);
    if (cursor.position >= cursor.length)
      return SONBAL_OPENAI_PROTOCOL_INVALID_JSON;
    if (cursor.data[cursor.position] == '}') {
      cursor.position++;
      break;
    }
    if (cursor.data[cursor.position] != ',')
      return SONBAL_OPENAI_PROTOCOL_INVALID_JSON;
    cursor.position++;
  }

  skip_space(&cursor);
  if (cursor.position != cursor.length)
    return SONBAL_OPENAI_PROTOCOL_INVALID_JSON;
  if ((seen & SEEN_TUNNEL_ID) == 0)
    return SONBAL_OPENAI_PROTOCOL_INVALID_ENVELOPE;

  return SONBAL_OPENAI_PROTOCOL_OK;
}
