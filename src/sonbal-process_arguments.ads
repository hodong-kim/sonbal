-- ============================================================================
-- sonbal-process_arguments.ads
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

package Sonbal.Process_Arguments is

  MAXIMUM_ARGUMENT_COUNT           : constant Positive := 65;
  MAXIMUM_ARGV_BYTES               : constant Positive := 32_768;
  MAXIMUM_ARGUMENT_BYTES           : constant Positive := MAXIMUM_ARGV_BYTES;
  MAXIMUM_WORKING_DIRECTORY_BYTES  : constant Positive := 4_096;

  type Arguments is private;

  type Append_State is
    (Append_Accepted,
     Append_Count_Exceeded,
     Append_Bytes_Exceeded,
     Append_Empty_Executable,
     Append_Contains_Nul);

  --! summary Reset one bounded argv value to its invalid empty state.
  procedure clear (self : out Arguments);

  --! summary Append one validated argv item.
  --! contract:
  --!   The first item must be nonempty. Later empty items are accepted.
  --!   Embedded NUL is rejected. Count and aggregate byte limits are checked
  --!   before mutation. A non-accepted append has no side effects.
  function append
    (self     : in out Arguments;
     argument : String)
  return Append_State;

  --! summary True only when at least one valid executable argument exists.
  function is_valid (self : Arguments) return Boolean;

  function count (self : Arguments) return Natural;
  function total_bytes (self : Arguments) return Natural;

  function argument_at
    (self  : Arguments;
     index : Positive)
  return String
    with Pre => index <= count (self);

private

  type Argument_Slice is record
    first  : Natural range 0 .. MAXIMUM_ARGV_BYTES := 0;
    length : Natural range 0 .. MAXIMUM_ARGUMENT_BYTES := 0;
  end record;

  type Argument_Slices is array
    (Positive range 1 .. MAXIMUM_ARGUMENT_COUNT) of Argument_Slice;

  type Arguments is record
    data         : String (1 .. MAXIMUM_ARGV_BYTES) :=
      [others => Character'Val (0)];
    stored_bytes : Natural range 0 .. MAXIMUM_ARGV_BYTES := 0;
    item_count   : Natural range 0 .. MAXIMUM_ARGUMENT_COUNT := 0;
    slices       : Argument_Slices;
  end record;

end Sonbal.Process_Arguments;
