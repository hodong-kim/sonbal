/* =========================================================================
 * sonbal_connector_host_test_support.c
 * Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
 * SPDX-License-Identifier: 0BSD
 * =========================================================================
 */
#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#define WATCH_FD_ENV "SONBAL_CONNECTOR_TEST_WATCH_FD"

static int
set_nonblocking (int fd)
{
  int flags = fcntl(fd, F_GETFL, 0);

  if (flags < 0)
    return -1;

  return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

int
sonbal_connector_host_test_watch_begin (int *read_fd, int *write_fd)
{
  int fds[2] = {-1, -1};
  char text[32];
  int saved_errno;

  if (read_fd == NULL || write_fd == NULL || getenv(WATCH_FD_ENV) != NULL)
  {
    errno = EINVAL;
    return -1;
  }

  if (pipe(fds) != 0)
    return -1;

  if (set_nonblocking(fds[0]) != 0 || set_nonblocking(fds[1]) != 0)
    goto fail;

  if (snprintf(text, sizeof text, "%d", fds[0]) <= 0 ||
      setenv(WATCH_FD_ENV, text, 1) != 0)
    goto fail;

  *read_fd = fds[0];
  *write_fd = fds[1];
  return 0;

fail:
  saved_errno = errno;
  (void) close(fds[0]);
  (void) close(fds[1]);
  errno = saved_errno;
  return -1;
}

int
sonbal_connector_host_test_watch_end (void)
{
  return unsetenv(WATCH_FD_ENV);
}
