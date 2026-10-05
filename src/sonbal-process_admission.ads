-- ============================================================================
-- sonbal-process_admission.ads
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Clair.Status;
with Sonbal.Configuration;

package Sonbal.Process_Admission is

  type Context is limited private;
  type Context_Access is access all Context;

  --! summary Initialize one owner-thread execution admission counter.
  --! contract:
  --!   `limit` is the complete shared process-execution ceiling. All calls on
  --!   one context are serialized by the owning Event Loop thread.
  function initialize
    (self  : in out Context;
     limit : Sonbal.Configuration.Work_Slot_Count)
  return Clair.Status.Code;

  --! summary Attempt one bounded execution admission without queuing.
  --! outputs:
  --!   `acquired` is true only when this call owns one count that must later be
  --!   released exactly once. Normal capacity exhaustion or stopped admission
  --!   returns `OK` with `acquired = False`.
  --! returns:
  --!   `INVALID_STATE` when the context has not been initialized.
  function try_acquire
    (self     : in out Context;
     acquired : out Boolean)
  return Clair.Status.Code;

  --! summary Release exactly one previously acquired execution count.
  function release (self : in out Context) return Clair.Status.Code;

  --! summary Permanently stop new admission for this initialized lifetime.
  procedure stop (self : in out Context);

  --! summary Reset one stopped or active-free admission context.
  --! contract:
  --!   No acquired execution count may remain.
  function finalize (self : in out Context) return Clair.Status.Code;

  function active_count (self : Context) return Natural;
  function is_initialized (self : Context) return Boolean;

private
  type Context is limited record
    limit       : Natural range
      0 .. Sonbal.Configuration.ABSOLUTE_MAX_WORK_SLOTS := 0;
    active      : Natural range
      0 .. Sonbal.Configuration.ABSOLUTE_MAX_WORK_SLOTS := 0;
    initialized : Boolean := False;
    stopping    : Boolean := False;
  end record;

end Sonbal.Process_Admission;
