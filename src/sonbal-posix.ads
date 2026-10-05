-- ============================================================================
-- sonbal-posix.ads
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Clair.Unix.File;

package Sonbal.POSIX is

  subtype File_Creation_Mask is Clair.Unix.File.Permission_Mode range
    0 .. Clair.Unix.File.Permission_Mode(8#0777#);

  --! summary Set the process-global POSIX file creation mask.
  --! notes
  --!   This is intentionally Sonbal-owned because current Clair does not expose
  --!   process-global umask mutation. Call only during single-threaded server
  --!   startup/teardown, never while concurrent work can create filesystem
  --!   objects.
  function set_file_creation_mask
    (mask : File_Creation_Mask) return File_Creation_Mask;

end Sonbal.POSIX;
