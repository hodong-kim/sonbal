-- ============================================================================
-- sonbal-posix.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Clair.Platform;

package body Sonbal.POSIX is

  function native_umask
    (mask : Clair.Platform.mode_t) return Clair.Platform.mode_t
  with Import,
       Convention    => C,
       External_Name => "umask";

  function set_file_creation_mask
    (mask : File_Creation_Mask) return File_Creation_Mask
  is
    previous : constant Clair.Platform.mode_t :=
      native_umask(Clair.Platform.mode_t(mask));
  begin
    return File_Creation_Mask(previous);
  end set_file_creation_mask;

end Sonbal.POSIX;
