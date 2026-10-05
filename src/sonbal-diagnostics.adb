-- ============================================================================
-- sonbal-diagnostics.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Clair.Process.Memory;
with Clair.Status;

package body Sonbal.Diagnostics is

  use type Clair.Status.Code;

  function observe_memory return Memory_Snapshot is
    usage  : Clair.Process.Memory.Usage;
    status : Clair.Status.Code;
  begin
    status := Clair.Process.Memory.query_current_usage (usage);
    if status /= Clair.Status.OK then
      return
        (state          => Observation_Failed,
         resident_bytes => 0,
         virtual_bytes  => 0);
    end if;

    return
      (state          => Observation_Available,
       resident_bytes => usage.resident_bytes,
       virtual_bytes  => usage.virtual_bytes);
  end observe_memory;

  function observe_runtime
    (runtime : Sonbal.Process_Runtime.Context)
  return Runtime_Snapshot
  is
  begin
    return
      (initialized            => Sonbal.Process_Runtime.is_initialized (runtime),
       active_execution_count =>
         Sonbal.Process_Runtime.active_execution_count (runtime),
       active_work_count      => Sonbal.Process_Runtime.active_work_count (runtime),
       workspace_token_count  =>
         Sonbal.Process_Runtime.workspace_token_count (runtime));
  end observe_runtime;

end Sonbal.Diagnostics;
