-- ============================================================================
-- sonbal_process_runtime_tests.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Ada.Directories;
with Ada.Real_Time;
with Clair.Event_Loop;
with Clair.Process.Execution;
with Clair.Process.Execution.Event_Loop;
with Clair.Status;
with Sonbal.Configuration;
with Sonbal.Diagnostics;
with Sonbal.Process_Arguments;
with Sonbal.Process_Execution;
with Sonbal.Process_Jobs;
with Sonbal.Process_Runtime;
with Sonbal.Workspace_Tokens;
with Sonbal_Test_Support;

package body Sonbal_Process_Runtime_Tests is

  use type Ada.Real_Time.Time;
  use type Clair.Process.Execution.Event_Loop.Operation_Cause;
  use type Clair.Status.Code;
  use type Sonbal.Process_Execution.Workspace_Start_State;
  use type Sonbal.Process_Jobs.Poll_State;
  use type Sonbal.Process_Jobs.Cancel_State;
  use type Sonbal.Process_Jobs.Start_State;
  use type Sonbal.Workspace_Tokens.Rotation_State;

  type Completion is limited new
    Sonbal.Process_Execution.Completion_Handler with record
      call_count : Natural := 0;
      cause      : Clair.Process.Execution.Event_Loop.Operation_Cause :=
        Clair.Process.Execution.Event_Loop.Ordinary_Execution;
      status     : Clair.Status.Code := Clair.Status.INTERNAL_ERROR;
    end record;

  overriding function on_complete
    (handler   : in out Completion;
     operation : not null Sonbal.Process_Execution.Operation_Access;
     cause     : Clair.Process.Execution.Event_Loop.Operation_Cause;
     status    : Clair.Status.Code;
     outcome   : Clair.Process.Execution.Result)
  return Clair.Status.Code
  is
    pragma Unreferenced (operation, outcome);
  begin
    handler.call_count := handler.call_count + 1;
    handler.cause := cause;
    handler.status := status;
    return Clair.Status.OK;
  end on_complete;

  function prepare_workspace (name : String) return String is
    root : constant String := Ada.Directories.Full_Name("build/tmp") &
      "/sonbal-runtime-" & name;
  begin
    Ada.Directories.Create_Path("build/tmp");
    if Ada.Directories.Exists(root) then
      Ada.Directories.Delete_Tree(root);
    end if;
    Ada.Directories.Create_Path(root);
    return root;
  end prepare_workspace;

  procedure cleanup_workspace (root : String) is
  begin
    if Ada.Directories.Exists(root) then
      Ada.Directories.Delete_Tree(root);
    end if;
  exception
    when others =>
      null;
  end cleanup_workspace;

  function rotate_runtime_workspace
    (runtime : in out Sonbal.Process_Runtime.Context;
     root    : String;
     result  : out Sonbal.Workspace_Tokens.Rotation_Result)
  return Clair.Status.Code
  is
    prepared : Sonbal.Workspace_Tokens.Rotation_Result;
    status   : Clair.Status.Code;
  begin
    status := Sonbal.Process_Runtime.rotate_workspace_token
      (runtime, root, "", prepared);
    if status /= Clair.Status.OK or else
       prepared.state /= Sonbal.Workspace_Tokens.Rotation_Prepared
    then
      result := prepared;
      return status;
    end if;

    return Sonbal.Process_Runtime.rotate_workspace_token
      (runtime,
       root,
       Sonbal.Workspace_Tokens.image (prepared.operation_id),
       result);
  end rotate_runtime_workspace;

  procedure drive_until
    (loop_context : in out Clair.Event_Loop.Context;
     deadline     : Ada.Real_Time.Time;
     done         : not null access function return Boolean;
     status       : out Clair.Status.Code)
  is
    dispatched : Boolean := False;
  begin
    status := Clair.Status.OK;
    while not done.all and then
          status = Clair.Status.OK and then
          Ada.Real_Time.clock < deadline
    loop
      status := Clair.Event_Loop.iterate
        (self       => loop_context,
         timeout    => 50,
         dispatched => dispatched);
    end loop;
  end drive_until;

  procedure token_rotation_coordinates_real_work
    (reporter : in out Clair.Test.Reporter.Context)
  is
    root            : constant String := prepare_workspace ("rotation");
    loop_context    : aliased Clair.Event_Loop.Context;
    runtime         : aliased Sonbal.Process_Runtime.Context;
    sync_process    : aliased Sonbal.Process_Execution.Operation;
    delayed_process : aliased Sonbal.Process_Execution.Operation;
    sync_handler    : aliased Completion;
    delayed_handler : aliased Completion;
    first_rotation      : Sonbal.Workspace_Tokens.Rotation_Result;
    second_rotation     : Sonbal.Workspace_Tokens.Rotation_Result;
    started_job     : Sonbal.Process_Jobs.Start_Result;
    stale_job       : Sonbal.Process_Jobs.Start_Result;
    polled          : Sonbal.Process_Jobs.Poll_Result;
    cancelled       : Sonbal.Process_Jobs.Cancel_Result;
    sleep_argv      : constant Sonbal.Process_Arguments.Arguments :=
      Sonbal_Test_Support.Process_Arguments ("/bin/sleep", "30");
    true_argv       : constant Sonbal.Process_Arguments.Arguments :=
      Sonbal_Test_Support.Process_Arguments ("/usr/bin/true");
    start_state   : Sonbal.Process_Execution.Workspace_Start_State;
    status          : Clair.Status.Code;
    deadline        : Ada.Real_Time.Time;
  begin
    status := Clair.Event_Loop.initialize (loop_context);
    Sonbal_Test_Support.check
      (reporter, status = Clair.Status.OK, "runtime Event Loop initializes");
    if status /= Clair.Status.OK then
      cleanup_workspace (root);
      return;
    end if;

    status := Sonbal.Process_Runtime.initialize
      (runtime, loop_context, Sonbal.Configuration.Work_Slot_Count (2));
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK and then
         Sonbal.Process_Runtime.is_initialized (runtime),
       "server process runtime initializes one rotation/admission domain");
    if status /= Clair.Status.OK then
      status := Clair.Event_Loop.finalize (loop_context);
      cleanup_workspace (root);
      return;
    end if;

    status := Sonbal.Process_Execution.initialize (sync_process, loop_context);
    if status = Clair.Status.OK then
      status := Sonbal.Process_Execution.initialize
        (delayed_process, loop_context);
    end if;
    Sonbal_Test_Support.check
      (reporter, status = Clair.Status.OK, "runtime process slots initialize");
    if status /= Clair.Status.OK then
      cleanup_workspace (root);
      return;
    end if;

    status := rotate_runtime_workspace (runtime, root, first_rotation);
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK and then
         first_rotation.state = Sonbal.Workspace_Tokens.Rotation_Rotated and then
         Sonbal.Process_Runtime.workspace_token_count (runtime) = 1,
       "runtime opens one canonical workspace rotation");

    declare
      old_token : constant String :=
        Sonbal.Workspace_Tokens.image (first_rotation.token);
    begin
      status := Sonbal.Process_Runtime.start_synchronous
        (self              => runtime,
         operation         => sync_process,
         workspace_token => old_token,
         argv              => sleep_argv,
         resolution        => Clair.Process.Execution.Exact_Path,
         cwd               => root,
         timeout_ms        => 30_000,
         handler           => sync_handler'unchecked_access,
         state             => start_state);
      Sonbal_Test_Support.check
        (reporter,
         status = Clair.Status.OK and then
           start_state =
             Sonbal.Process_Execution.Workspace_Start_Running,
         "runtime starts synchronous execution under current workspace token");

      Sonbal.Process_Runtime.start_job
        (runtime,
         old_token,
         sleep_argv,
         Clair.Process.Execution.Exact_Path,
         root,
         30_000,
         started_job);
      Sonbal_Test_Support.check
        (reporter,
         started_job.state = Sonbal.Process_Jobs.Start_Running and then
           Sonbal.Process_Runtime.active_execution_count (runtime) = 2 and then
           Sonbal.Process_Runtime.active_work_count (runtime) = 2,
         "synchronous execution and job share bounded capacity");

      delay until
        Ada.Real_Time.Clock +
          Ada.Real_Time.Milliseconds
            (Sonbal.Workspace_Tokens.ROTATE_WORKSPACE_TOKEN_COOLDOWN_MS + 50);
      status := rotate_runtime_workspace (runtime, root, second_rotation);
      Sonbal_Test_Support.check
        (reporter,
         status = Clair.Status.OK and then
           second_rotation.state = Sonbal.Workspace_Tokens.Rotation_Rotated and then
           Sonbal.Workspace_Tokens.image (second_rotation.token) /=
             old_token and then
           Sonbal.Process_Runtime.active_execution_count (runtime) = 2 and then
           Sonbal.Process_Runtime.active_work_count (runtime) = 2,
         "new rotation does not cancel already accepted runtime work");

      status := Sonbal.Process_Runtime.start_synchronous
        (self              => runtime,
         operation         => delayed_process,
         workspace_token => old_token,
         argv              => true_argv,
         resolution        => Clair.Process.Execution.Exact_Path,
         cwd               => root,
         timeout_ms        => 2_000,
         handler           => delayed_handler'unchecked_access,
         state             => start_state);
      Sonbal_Test_Support.check
        (reporter,
         status = Clair.Status.OK and then
           start_state =
             Sonbal.Process_Execution.Workspace_Start_Stale_Token and then
           not Sonbal.Process_Execution.is_active (delayed_process) and then
           Sonbal.Process_Runtime.active_execution_count (runtime) = 2,
         "delayed old-token synchronous start is rejected before admission");

      Sonbal.Process_Runtime.start_job
        (runtime,
         old_token,
         true_argv,
         Clair.Process.Execution.Exact_Path,
         root,
         2_000,
         stale_job);
      Sonbal_Test_Support.check
        (reporter,
         stale_job.state = Sonbal.Process_Jobs.Start_Stale_Workspace_Token and then
           Sonbal.Process_Runtime.active_execution_count (runtime) = 2 and then
           Sonbal.Process_Runtime.active_work_count (runtime) = 2,
         "delayed old-token job start is rejected before admission");

      Sonbal.Process_Runtime.poll_job
        (runtime,
         Sonbal.Process_Jobs.image (started_job.job_id),
         Sonbal.Process_Jobs.image (started_job.cursor),
         polled);
      Sonbal_Test_Support.check
        (reporter,
         polled.state = Sonbal.Process_Jobs.Poll_Running and then
           Sonbal.Process_Execution.is_active (sync_process),
         "accepted old-token work remains live after replacement");

      status := Sonbal.Process_Execution.cancel (sync_process);
      Sonbal_Test_Support.check
        (reporter, status = Clair.Status.OK, "sync process cancels normally");
      Sonbal.Process_Runtime.cancel_job
        (runtime, Sonbal.Process_Jobs.image (started_job.job_id), cancelled);
      Sonbal_Test_Support.check
        (reporter,
         cancelled.state = Sonbal.Process_Jobs.Cancel_Cancelling,
         "server-owned job cancels through job authority");

      declare
        job_id : constant String :=
          Sonbal.Process_Jobs.image (started_job.job_id);
        cursor : constant String :=
          Sonbal.Process_Jobs.image (started_job.cursor);
        function settled return Boolean is
        begin
          Sonbal.Process_Runtime.poll_job (runtime, job_id, cursor, polled);
          return sync_handler.call_count = 1 and then
            polled.state = Sonbal.Process_Jobs.Poll_Terminal;
        end settled;
      begin
        deadline := Ada.Real_Time.Clock + Ada.Real_Time.Seconds (5);
        drive_until (loop_context, deadline, settled'access, status);
      end;

      Sonbal_Test_Support.check
        (reporter,
         status = Clair.Status.OK and then
           sync_handler.call_count = 1 and then
           polled.state = Sonbal.Process_Jobs.Poll_Terminal and then
           Sonbal.Process_Runtime.active_execution_count (runtime) = 0 and then
           Sonbal.Process_Runtime.active_work_count (runtime) = 0,
         "old-token work settles normally after explicit cancellation");

      status := Sonbal.Process_Runtime.start_synchronous
        (self              => runtime,
         operation         => delayed_process,
         workspace_token =>
           Sonbal.Workspace_Tokens.image (second_rotation.token),
         argv              => true_argv,
         resolution        => Clair.Process.Execution.Exact_Path,
         cwd               => root,
         timeout_ms        => 2_000,
         handler           => delayed_handler'unchecked_access,
         state             => start_state);
      Sonbal_Test_Support.check
        (reporter,
         status = Clair.Status.OK and then
           start_state = Sonbal.Process_Execution.Workspace_Start_Running,
         "replacement rotation starts new work");

      declare
        function replacement_settled return Boolean is
          (delayed_handler.call_count = 1);
      begin
        deadline := Ada.Real_Time.Clock + Ada.Real_Time.Seconds (3);
        drive_until
          (loop_context, deadline, replacement_settled'access, status);
      end;
      Sonbal_Test_Support.check
        (reporter,
         status = Clair.Status.OK and then
           delayed_handler.call_count = 1 and then
           Sonbal.Process_Runtime.active_execution_count (runtime) = 0 and then
           Sonbal.Process_Runtime.active_work_count (runtime) = 0,
         "replacement rotation work settles exactly once");

      Sonbal_Test_Support.check
        (reporter,
         Sonbal.Process_Runtime.workspace_token_count (runtime) = 1,
         "replacement workspace token remains current until superseded or shutdown");
    end;

    status := Sonbal.Process_Runtime.begin_shutdown (runtime);
    Sonbal_Test_Support.check
      (reporter, status = Clair.Status.OK, "runtime begins clean shutdown");
    status := Sonbal.Process_Runtime.finalize (runtime);
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK and then
         not Sonbal.Process_Runtime.is_initialized (runtime),
       "idle runtime finalizes all shared registries");
    status := Sonbal.Process_Execution.finalize (sync_process);
    Sonbal_Test_Support.check
      (reporter, status = Clair.Status.OK, "runtime sync operation finalizes");
    status := Sonbal.Process_Execution.finalize (delayed_process);
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK,
       "runtime delayed operation finalizes");
    status := Clair.Event_Loop.finalize (loop_context);
    Sonbal_Test_Support.check
      (reporter, status = Clair.Status.OK, "runtime Event Loop finalizes");
    cleanup_workspace (root);
  end token_rotation_coordinates_real_work;

  procedure mixed_saturation_and_shutdown
    (reporter : in out Clair.Test.Reporter.Context)
  is
    root         : constant String := prepare_workspace("saturation");
    loop_context : aliased Clair.Event_Loop.Context;
    runtime      : aliased Sonbal.Process_Runtime.Context;
    first_sync   : aliased Sonbal.Process_Execution.Operation;
    excess_sync  : aliased Sonbal.Process_Execution.Operation;
    first_handler : aliased Completion;
    excess_handler : aliased Completion;
    rotation      : Sonbal.Workspace_Tokens.Rotation_Result;
    first_job    : Sonbal.Process_Jobs.Start_Result;
    excess_job   : Sonbal.Process_Jobs.Start_Result;
    sleep_argv   : constant Sonbal.Process_Arguments.Arguments :=
      Sonbal_Test_Support.Process_Arguments ("/bin/sleep", "30");
    true_argv    : constant Sonbal.Process_Arguments.Arguments :=
      Sonbal_Test_Support.Process_Arguments ("/usr/bin/true");
    start_state  : Sonbal.Process_Execution.Workspace_Start_State;
    status       : Clair.Status.Code;
    deadline     : Ada.Real_Time.Time;
  begin
    status := Clair.Event_Loop.initialize(loop_context);
    if status /= Clair.Status.OK then
      Sonbal_Test_Support.check
        (reporter, False, "saturation Event Loop starts");
      cleanup_workspace(root);
      return;
    end if;
    status := Sonbal.Process_Runtime.initialize
      (runtime, loop_context, Sonbal.Configuration.Work_Slot_Count(2));
    Sonbal_Test_Support.check
      (reporter, status = Clair.Status.OK, "saturation runtime initializes");
    status := Sonbal.Process_Execution.initialize(first_sync, loop_context);
    Sonbal_Test_Support.check
      (reporter, status = Clair.Status.OK, "first sync slot initializes");
    status := Sonbal.Process_Execution.initialize(excess_sync, loop_context);
    Sonbal_Test_Support.check
      (reporter, status = Clair.Status.OK, "excess sync slot initializes");
    status := rotate_runtime_workspace(runtime, root, rotation);
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK and then
         rotation.state = Sonbal.Workspace_Tokens.Rotation_Rotated,
       "saturation workspace is rotation");

    declare
      workspace_token : constant String :=
        Sonbal.Workspace_Tokens.image (rotation.token);
    begin
      status := Sonbal.Process_Runtime.start_synchronous
        (runtime,
         first_sync,
         workspace_token,
         sleep_argv,
         Clair.Process.Execution.Exact_Path,
         root,
         30_000,
         first_handler'unchecked_access,
         start_state);
      Sonbal.Process_Runtime.start_job
        (runtime,
         workspace_token,
         sleep_argv,
         Clair.Process.Execution.Exact_Path,
         root,
         30_000,
         first_job);
      Sonbal_Test_Support.check
        (reporter,
         status = Clair.Status.OK and then
           start_state =
             Sonbal.Process_Execution.Workspace_Start_Running and then
           first_job.state = Sonbal.Process_Jobs.Start_Running and then
           Sonbal.Process_Runtime.active_execution_count(runtime) = 2,
         "mixed sync and job traffic fills exactly one shared capacity");

      status := Sonbal.Process_Runtime.start_synchronous
        (runtime,
         excess_sync,
         workspace_token,
         true_argv,
         Clair.Process.Execution.Exact_Path,
         root,
         2_000,
         excess_handler'unchecked_access,
         start_state);
      Sonbal.Process_Runtime.start_job
        (runtime,
         workspace_token,
         true_argv,
         Clair.Process.Execution.Exact_Path,
         root,
         2_000,
         excess_job);
      Sonbal_Test_Support.check
        (reporter,
         status = Clair.Status.OK and then
           start_state =
             Sonbal.Process_Execution.Workspace_Start_Execution_Busy and then
           excess_job.state = Sonbal.Process_Jobs.Start_Execution_Busy and then
           not Sonbal.Process_Execution.is_active(excess_sync) and then
           Sonbal.Process_Runtime.active_execution_count(runtime) = 2 and then
           Sonbal.Process_Runtime.active_work_count(runtime) = 2,
         "mixed overload is refused without a hidden queue or extra ticket");
    end;

    status := Sonbal.Process_Runtime.begin_shutdown(runtime);
    Sonbal_Test_Support.check
      (reporter, status = Clair.Status.OK, "saturated runtime starts shutdown");

    declare
      function settled return Boolean is
        (Sonbal.Process_Runtime.is_idle(runtime));
    begin
      deadline := Ada.Real_Time.clock + Ada.Real_Time.Seconds(5);
      drive_until(loop_context, deadline, settled'access, status);
    end;
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK and then
         Sonbal.Process_Runtime.is_idle(runtime) and then
         Sonbal.Process_Runtime.active_execution_count(runtime) = 0 and then
         Sonbal.Process_Runtime.active_work_count(runtime) = 0,
       "shutdown settles mixed saturated execution resources");

    status := rotate_runtime_workspace(runtime, root, rotation);
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.INVALID_STATE,
       "stopped runtime refuses new workspace-rotation admission");

    status := Sonbal.Process_Runtime.finalize(runtime);
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK,
       "settled saturated runtime finalizes");
    status := Sonbal.Process_Execution.finalize(first_sync);
    Sonbal_Test_Support.check
      (reporter, status = Clair.Status.OK, "first sync slot finalizes");
    status := Sonbal.Process_Execution.finalize(excess_sync);
    Sonbal_Test_Support.check
      (reporter, status = Clair.Status.OK, "excess sync slot finalizes");
    status := Clair.Event_Loop.finalize(loop_context);
    Sonbal_Test_Support.check
      (reporter, status = Clair.Status.OK, "saturation Event Loop finalizes");
    cleanup_workspace(root);
  end mixed_saturation_and_shutdown;

  procedure diagnostics_track_repeated_runtime_settlement
    (reporter : in out Clair.Test.Reporter.Context)
  is
    root         : constant String := prepare_workspace ("diagnostics");
    loop_context : aliased Clair.Event_Loop.Context;
    runtime      : aliased Sonbal.Process_Runtime.Context;
    operation    : aliased Sonbal.Process_Execution.Operation;
    handler      : aliased Completion;
    rotation      : Sonbal.Workspace_Tokens.Rotation_Result;
    true_argv    : constant Sonbal.Process_Arguments.Arguments :=
      Sonbal_Test_Support.Process_Arguments ("/usr/bin/true");
    start_state  : Sonbal.Process_Execution.Workspace_Start_State;
    status       : Clair.Status.Code;
    deadline     : Ada.Real_Time.Time;
    valid        : Boolean := True;
  begin
    status := Clair.Event_Loop.initialize (loop_context);
    Sonbal_Test_Support.check
      (reporter, status = Clair.Status.OK, "diagnostic soak Event Loop initializes");
    if status /= Clair.Status.OK then
      cleanup_workspace (root);
      return;
    end if;

    status := Sonbal.Process_Runtime.initialize
      (runtime, loop_context, Sonbal.Configuration.Work_Slot_Count (1));
    Sonbal_Test_Support.check
      (reporter, status = Clair.Status.OK, "diagnostic soak runtime initializes");
    if status /= Clair.Status.OK then
      status := Clair.Event_Loop.finalize (loop_context);
      cleanup_workspace (root);
      return;
    end if;

    status := Sonbal.Process_Execution.initialize (operation, loop_context);
    Sonbal_Test_Support.check
      (reporter, status = Clair.Status.OK, "diagnostic soak operation initializes");
    if status /= Clair.Status.OK then
      status := Sonbal.Process_Runtime.finalize (runtime);
      status := Clair.Event_Loop.finalize (loop_context);
      cleanup_workspace (root);
      return;
    end if;

    status := rotate_runtime_workspace (runtime, root, rotation);
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK and then
         rotation.state = Sonbal.Workspace_Tokens.Rotation_Rotated,
       "diagnostic soak workspace is rotation");

    if status = Clair.Status.OK and then
       rotation.state = Sonbal.Workspace_Tokens.Rotation_Rotated
    then
      declare
        workspace_token : constant String :=
          Sonbal.Workspace_Tokens.image (rotation.token);
      begin
        for iteration in 1 .. 32 loop
          status := Sonbal.Process_Runtime.start_synchronous
            (self       => runtime,
             operation  => operation,
             workspace_token => workspace_token,
             argv       => true_argv,
             resolution => Clair.Process.Execution.Exact_Path,
             cwd        => root,
             timeout_ms => 2_000,
             handler    => handler'unchecked_access,
             state      => start_state);
          if status /= Clair.Status.OK or else
             start_state /= Sonbal.Process_Execution.Workspace_Start_Running
          then
            valid := False;
            exit;
          end if;

          declare
            function settled return Boolean is
              (handler.call_count = iteration);
          begin
            deadline := Ada.Real_Time.clock + Ada.Real_Time.Seconds (2);
            drive_until (loop_context, deadline, settled'access, status);
          end;

          declare
            snapshot : constant Sonbal.Diagnostics.Runtime_Snapshot :=
              Sonbal.Diagnostics.observe_runtime (runtime);
          begin
            valid := valid and then
              status = Clair.Status.OK and then
              handler.call_count = iteration and then
              handler.status = Clair.Status.OK and then
              handler.cause =
                Clair.Process.Execution.Event_Loop.Ordinary_Execution and then
              not Sonbal.Process_Execution.is_active (operation) and then
              snapshot.initialized and then
              snapshot.active_execution_count = 0 and then
              snapshot.active_work_count = 0 and then
              snapshot.workspace_token_count = 1;
          end;
          exit when not valid;
        end loop;

        Sonbal_Test_Support.check
          (reporter,
           valid,
           "repeated runtime work returns diagnostic counters to plateau");

        if valid then
          declare
            snapshot : constant Sonbal.Diagnostics.Runtime_Snapshot :=
              Sonbal.Diagnostics.observe_runtime (runtime);
          begin
            Sonbal_Test_Support.check
              (reporter,
               snapshot.active_execution_count = 0 and then
                 snapshot.active_work_count = 0 and then
                 snapshot.workspace_token_count = 1,
               "diagnostic soak retains one bounded current workspace token");
          end;
        end if;
      end;
    end if;

    status := Sonbal.Process_Runtime.begin_shutdown (runtime);
    Sonbal_Test_Support.check
      (reporter, status = Clair.Status.OK, "diagnostic soak begins shutdown");
    if status = Clair.Status.OK then
      declare
        function settled return Boolean is
          (Sonbal.Process_Runtime.is_idle (runtime));
      begin
        deadline := Ada.Real_Time.clock + Ada.Real_Time.Seconds (5);
        drive_until (loop_context, deadline, settled'access, status);
      end;
      Sonbal_Test_Support.check
        (reporter,
         status = Clair.Status.OK and then Sonbal.Process_Runtime.is_idle (runtime),
         "diagnostic soak shutdown settles runtime resources");
    end if;
    status := Sonbal.Process_Runtime.finalize (runtime);
    Sonbal_Test_Support.check
      (reporter, status = Clair.Status.OK, "diagnostic soak runtime finalizes");
    status := Sonbal.Process_Execution.finalize (operation);
    Sonbal_Test_Support.check
      (reporter, status = Clair.Status.OK, "diagnostic soak operation finalizes");
    status := Clair.Event_Loop.finalize (loop_context);
    Sonbal_Test_Support.check
      (reporter, status = Clair.Status.OK, "diagnostic soak Event Loop finalizes");
    cleanup_workspace (root);
  end diagnostics_track_repeated_runtime_settlement;

  procedure run (reporter : in out Clair.Test.Reporter.Context) is
  begin
    Clair.Test.Reporter.run_scenario
      (reporter,
       "rotation replacement coordinates real work",
       token_rotation_coordinates_real_work'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "mixed saturation and shutdown",
       mixed_saturation_and_shutdown'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "diagnostics track repeated runtime settlement",
       diagnostics_track_repeated_runtime_settlement'access);
  end run;

end Sonbal_Process_Runtime_Tests;
