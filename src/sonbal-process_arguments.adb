-- ============================================================================
-- sonbal-process_arguments.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

package body Sonbal.Process_Arguments is

  function contains_nul (value : String) return Boolean is
  begin
    for item of value loop
      if item = Character'Val (0) then
        return True;
      end if;
    end loop;
    return False;
  end contains_nul;

  procedure clear (self : out Arguments) is
  begin
    self :=
      (data         => [others => Character'Val (0)],
       stored_bytes => 0,
       item_count   => 0,
       slices       => [others => <>]);
  end clear;

  function append
    (self     : in out Arguments;
     argument : String)
  return Append_State
  is
    next_index : Positive;
    first      : Natural;
  begin
    if self.item_count = MAXIMUM_ARGUMENT_COUNT then
      return Append_Count_Exceeded;
    elsif argument'Length > MAXIMUM_ARGUMENT_BYTES or else
          argument'Length > MAXIMUM_ARGV_BYTES - self.stored_bytes
    then
      return Append_Bytes_Exceeded;
    elsif self.item_count = 0 and then argument'Length = 0 then
      return Append_Empty_Executable;
    elsif contains_nul (argument) then
      return Append_Contains_Nul;
    end if;

    next_index := self.item_count + 1;

    if argument'Length = 0 then
      self.slices (next_index) := (first => 0, length => 0);
    else
      first := self.stored_bytes + 1;
      self.data (first .. first + argument'Length - 1) := argument;
      self.slices (next_index) :=
        (first => first, length => argument'Length);
      self.stored_bytes := self.stored_bytes + argument'Length;
    end if;

    self.item_count := next_index;
    return Append_Accepted;
  end append;

  function is_valid (self : Arguments) return Boolean is
  begin
    return self.item_count > 0 and then
      self.slices (1).length > 0;
  end is_valid;

  function count (self : Arguments) return Natural is
  begin
    return self.item_count;
  end count;

  function total_bytes (self : Arguments) return Natural is
  begin
    return self.stored_bytes;
  end total_bytes;

  function argument_at
    (self  : Arguments;
     index : Positive)
  return String
  is
    item : constant Argument_Slice := self.slices (index);
  begin
    if item.length = 0 then
      return "";
    end if;

    return self.data (item.first .. item.first + item.length - 1);
  end argument_at;

end Sonbal.Process_Arguments;
