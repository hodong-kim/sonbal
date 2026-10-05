-- ============================================================================
-- sonbal-process_admission.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

package body Sonbal.Process_Admission is

  function initialize
    (self  : in out Context;
     limit : Sonbal.Configuration.Work_Slot_Count)
  return Clair.Status.Code
  is
  begin
    if self.initialized then
      return Clair.Status.INVALID_STATE;
    end if;

    self.limit       := Natural(limit);
    self.active      := 0;
    self.stopping    := False;
    self.initialized := True;
    return Clair.Status.OK;
  end initialize;

  function try_acquire
    (self     : in out Context;
     acquired : out Boolean)
  return Clair.Status.Code
  is
  begin
    acquired := False;
    if not self.initialized then
      return Clair.Status.INVALID_STATE;
    elsif self.stopping or else self.active >= self.limit then
      return Clair.Status.OK;
    end if;

    self.active := self.active + 1;
    acquired := True;
    return Clair.Status.OK;
  end try_acquire;

  function release (self : in out Context) return Clair.Status.Code is
  begin
    if not self.initialized or else self.active = 0 then
      return Clair.Status.INVALID_STATE;
    end if;

    self.active := self.active - 1;
    return Clair.Status.OK;
  end release;

  procedure stop (self : in out Context) is
  begin
    if self.initialized then
      self.stopping := True;
    end if;
  end stop;

  function finalize (self : in out Context) return Clair.Status.Code is
  begin
    if not self.initialized or else self.active /= 0 then
      return Clair.Status.INVALID_STATE;
    end if;

    self.limit       := 0;
    self.active      := 0;
    self.initialized := False;
    self.stopping    := False;
    return Clair.Status.OK;
  end finalize;

  function active_count (self : Context) return Natural is
    (self.active);

  function is_initialized (self : Context) return Boolean is
    (self.initialized);

end Sonbal.Process_Admission;
