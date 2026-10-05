-- ============================================================================
-- sonbal-diagnostics.ads
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Interfaces;
with Sonbal.Process_Runtime;

package Sonbal.Diagnostics is

  type Observation_State is
    (Observation_Available,
     Observation_Unsupported,
     Observation_Failed);

  type Memory_Snapshot is record
    state          : Observation_State := Observation_Unsupported;
    resident_bytes : Interfaces.Unsigned_64 := 0;
    virtual_bytes  : Interfaces.Unsigned_64 := 0;
  end record;

  --! summary
  --!   Observe current-process resident and virtual memory without mutating
  --!   allocator policy or runtime state.
  --!
  --! notes
  --!   A snapshot is an observation, not a memory-leak verdict. Callers must
  --!   compare repeated snapshots across a defined workload and idle window.
  --!   `resident_bytes` and `virtual_bytes` preserve Clair's native OS-reported
  --!   current-memory semantics; resident bytes are not an exact physical-page
  --!   census, and the two values are not atomic with concurrent memory changes.
  --!   Values are valid only when `state = Observation_Available`.
  function observe_memory return Memory_Snapshot;

  type Runtime_Snapshot is record
    initialized            : Boolean := False;
    active_execution_count : Natural := 0;
    active_work_count      : Natural := 0;
    workspace_token_count  : Natural := 0;
  end record;

  --! summary
  --!   Snapshot existing Sonbal-owned runtime counters without maintaining a
  --!   second diagnostic copy of runtime state.
  --!
  --! notes
  --!   Callers must use the same external synchronization as other accesses to
  --!   `runtime`; this function does not make concurrent runtime mutation
  --!   atomic.
  function observe_runtime
    (runtime : Sonbal.Process_Runtime.Context)
  return Runtime_Snapshot;

end Sonbal.Diagnostics;
