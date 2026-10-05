-- ============================================================================
-- sonbal-workspace_tokens-tester.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

package body Sonbal.Workspace_Tokens.Tester is

  function next_generation
    (self : Context)
  return Interfaces.Unsigned_64
  is
    (self.next_generation);

  function retained_token_slot_count
    (self : Context)
  return Natural
  is
    count : Natural := 0;
  begin
    if self.tokens = null then
      return 0;
    end if;

    for index in 1 .. self.capacity loop
      if self.tokens(index).root_length /= 0 then
        count := count + 1;
      end if;
    end loop;
    return count;
  end retained_token_slot_count;

  function retained_rotation_operation_count
    (self : Context)
  return Natural
  is
    count : Natural := 0;
  begin
    if self.rotation_operations = null then
      return 0;
    end if;

    for index in 1 .. self.capacity loop
      if self.rotation_operations(index).state /= Operation_Empty then
        count := count + 1;
      end if;
    end loop;
    return count;
  end retained_rotation_operation_count;

end Sonbal.Workspace_Tokens.Tester;
