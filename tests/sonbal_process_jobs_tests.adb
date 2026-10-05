-- ============================================================================
-- sonbal_process_jobs_tests.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Ada.Directories;
with Ada.Real_Time;
with Clair.Event_Loop;
with Clair.Process.Execution;
with Clair.Process.Execution.Event_Loop;
with Clair.Status;
with Interfaces;
with Sonbal.Configuration;
with Sonbal.Process_Admission;
with Sonbal.Process_Arguments;
with Sonbal.Process_Jobs;
with Sonbal.Process_Jobs.Tester;
with Sonbal.Process_Execution;
with Sonbal.Workspace_Tokens;
with Sonbal_Test_Support;
with System.Storage_Elements;

package body Sonbal_Process_Jobs_Tests is

  use type Ada.Real_Time.Time;
  use type Clair.Status.Code;
  use type Clair.Process.Execution.Event_Loop.Operation_Cause;
  use type Interfaces.Unsigned_32;
  use type Interfaces.Unsigned_64;
  use type Sonbal.Process_Jobs.Cancel_State;
  use type Sonbal.Process_Jobs.Poll_State;
  use type Sonbal.Process_Jobs.Start_State;
  use type Sonbal.Process_Jobs.Terminal_State;
  use type Sonbal.Process_Execution.Workspace_Start_State;
  use type Sonbal.Workspace_Tokens.Rotation_State;
  use type System.Storage_Elements.Storage_Element;
  use type System.Storage_Elements.Storage_Offset;

  type Owned_Completion is limited new
    Sonbal.Process_Execution.Completion_Handler with record
      call_count : Natural := 0;
      cause      : Clair.Process.Execution.Event_Loop.Operation_Cause :=
        Clair.Process.Execution.Event_Loop.Ordinary_Execution;
      status     : Clair.Status.Code := Clair.Status.INTERNAL_ERROR;
    end record;

  overriding function on_complete
    (handler   : in out Owned_Completion;
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
    base : constant String := Ada.Directories.Full_Name("build/tmp") &
      "/sonbal-jobs-" & name;
  begin
    Ada.Directories.Create_Path("build/tmp");
    if Ada.Directories.Exists(base) then
      Ada.Directories.Delete_Tree(base);
    end if;
    Ada.Directories.Create_Path(base);
    return base;
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

  function rotate_workspace_token
    (workspace_tokens : in out Sonbal.Workspace_Tokens.Context;
     root     : String;
     rotation   : out Sonbal.Workspace_Tokens.Rotation_Result)
  return Clair.Status.Code
  is
    prepared : Sonbal.Workspace_Tokens.Rotation_Result;
    status   : Clair.Status.Code;
  begin
    status := Sonbal.Workspace_Tokens.rotate
      (workspace_tokens, root, "", prepared);
    if status /= Clair.Status.OK or else
       prepared.state /= Sonbal.Workspace_Tokens.Rotation_Prepared
    then
      rotation := prepared;
      return status;
    end if;

    return Sonbal.Workspace_Tokens.rotate
      (workspace_tokens,
       root,
       Sonbal.Workspace_Tokens.image (prepared.operation_id),
       rotation);
  end rotate_workspace_token;

  function initialize_workspace
    (reporter  : in out Clair.Test.Reporter.Context;
     workspace : in out Sonbal.Workspace_Tokens.Context;
     root      : String;
     rotation    : out Sonbal.Workspace_Tokens.Rotation_Result)
  return Boolean
  is
    status : Clair.Status.Code;
  begin
    status := Sonbal.Workspace_Tokens.initialize
      (workspace, Sonbal.Configuration.Work_Slot_Count (1));
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK,
       "job workspace-rotation registry initializes");
    if status /= Clair.Status.OK then
      return False;
    end if;

    status := rotate_workspace_token (workspace, root, rotation);
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK and then
         rotation.state = Sonbal.Workspace_Tokens.Rotation_Rotated,
       "job workspace rotation opens");
    return status = Clair.Status.OK and then
      rotation.state = Sonbal.Workspace_Tokens.Rotation_Rotated;
  end initialize_workspace;

  function stream_text
    (stream : Sonbal.Process_Jobs.Poll_Stream) return String
  is
    result : String (1 .. stream.length);
  begin
    for index in result'range loop
      result(index) := Character'val
        (Integer
           (stream.data
              (stream.data'first +
               System.Storage_Elements.Storage_Offset(index - 1))));
    end loop;
    return result;
  end stream_text;

  function stream_is_zeroes
    (stream : Sonbal.Process_Jobs.Poll_Stream) return Boolean
  is
  begin
    if stream.length = 0 then
      return False;
    end if;

    for index in 1 .. stream.length loop
      if stream.data
        (stream.data'first +
         System.Storage_Elements.Storage_Offset(index - 1)) /= 0
      then
        return False;
      end if;
    end loop;
    return True;
  end stream_is_zeroes;

  function streams_equal
    (left  : Sonbal.Process_Jobs.Poll_Stream;
     right : Sonbal.Process_Jobs.Poll_Stream)
  return Boolean
  is
  begin
    if left.length /= right.length or else
       left.truncated /= right.truncated
    then
      return False;
    end if;

    for index in 1 .. left.length loop
      if left.data
           (left.data'first +
            System.Storage_Elements.Storage_Offset(index - 1)) /=
         right.data
           (right.data'first +
            System.Storage_Elements.Storage_Offset(index - 1))
      then
        return False;
      end if;
    end loop;
    return True;
  end streams_equal;

  procedure wait_terminal
    (loop_context : in out Clair.Event_Loop.Context;
     jobs         : in out Sonbal.Process_Jobs.Context;
     job_id       : String;
     cursor       : String;
     result       : out Sonbal.Process_Jobs.Poll_Result;
     status       : out Clair.Status.Code)
  is
    deadline   : constant Ada.Real_Time.Time :=
      Ada.Real_Time.clock + Ada.Real_Time.Seconds(4);
    dispatched : Boolean := False;
  begin
    status := Clair.Status.OK;
    loop
      Sonbal.Process_Jobs.poll (jobs, job_id, cursor, result);
      Sonbal.Process_Jobs.mark_poll_response_ready (jobs, result);
      exit when result.state /= Sonbal.Process_Jobs.Poll_Running or else
        status /= Clair.Status.OK or else Ada.Real_Time.clock >= deadline;

      status := Clair.Event_Loop.iterate
        (self       => loop_context,
         timeout    => 50,
         dispatched => dispatched);
    end loop;
  end wait_terminal;

  procedure finalize_fixture
    (reporter     : in out Clair.Test.Reporter.Context;
     loop_context : in out Clair.Event_Loop.Context;
     workspace    : in out Sonbal.Workspace_Tokens.Context;
     admission    : in out Sonbal.Process_Admission.Context;
     jobs         : aliased in out Sonbal.Process_Jobs.Context)
  is
    status : Clair.Status.Code;
  begin
    if Sonbal.Process_Jobs.is_initialized(jobs) then
      status := Sonbal.Process_Jobs.begin_shutdown(jobs);
      Sonbal_Test_Support.check
        (reporter,
         status = Clair.Status.OK,
         "job registry begins bounded shutdown");

      declare
        deadline   : constant Ada.Real_Time.Time :=
          Ada.Real_Time.clock + Ada.Real_Time.Seconds(4);
        dispatched : Boolean := False;
      begin
        while not Sonbal.Process_Jobs.is_idle(jobs) and then
              status = Clair.Status.OK and then
              Ada.Real_Time.clock < deadline
        loop
          status := Clair.Event_Loop.iterate
            (self       => loop_context,
             timeout    => 50,
             dispatched => dispatched);
        end loop;
      end;

      Sonbal_Test_Support.check
        (reporter,
         status = Clair.Status.OK and then
           Sonbal.Process_Jobs.is_idle(jobs),
         "job registry settles every live process before finalization");
      if Sonbal.Process_Jobs.is_idle(jobs) then
        status := Sonbal.Process_Jobs.finalize(jobs);
        Sonbal_Test_Support.check
          (reporter,
           status = Clair.Status.OK and then
             not Sonbal.Process_Jobs.is_initialized(jobs),
           "job registry releases retained terminal state");
      end if;
    end if;

    Sonbal_Test_Support.check
      (reporter,
       Sonbal.Process_Admission.active_count(admission) = 0,
       "job registry returns every shared admission count");
    status := Sonbal.Process_Admission.finalize(admission);
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK and then
         not Sonbal.Process_Admission.is_initialized(admission),
       "shared admission finalizes only after settlement");

    Sonbal_Test_Support.check
      (reporter,
       Sonbal.Workspace_Tokens.active_work_count(workspace) = 0,
       "job registry returns every workspace-rotation work ticket");
    status := Sonbal.Workspace_Tokens.finalize(workspace);
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK and then
         not Sonbal.Workspace_Tokens.is_initialized(workspace),
       "job workspace-rotation registry finalizes after settlement");

    status := Clair.Event_Loop.finalize(loop_context);
    Sonbal_Test_Support.check
      (reporter, status = Clair.Status.OK, "job test Event Loop finalizes");
  end finalize_fixture;

  procedure shared_admission_lifecycle
    (reporter : in out Clair.Test.Reporter.Context)
  is
    admission : Sonbal.Process_Admission.Context;
    acquired  : Boolean := True;
    status    : Clair.Status.Code;
  begin
    status := Sonbal.Process_Admission.try_acquire(admission, acquired);
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.INVALID_STATE and then not acquired,
       "uninitialized shared admission fails distinctly from saturation");

    status := Sonbal.Process_Admission.initialize
      (admission, Sonbal.Configuration.Work_Slot_Count(1));
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK and then
         Sonbal.Process_Admission.is_initialized(admission),
       "shared admission initializes one bounded execution slot");

    status := Sonbal.Process_Admission.try_acquire(admission, acquired);
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK and then acquired and then
         Sonbal.Process_Admission.active_count(admission) = 1,
       "shared admission grants one owned execution count");

    status := Sonbal.Process_Admission.try_acquire(admission, acquired);
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK and then not acquired and then
         Sonbal.Process_Admission.active_count(admission) = 1,
       "capacity exhaustion is a normal nonqueued refusal");

    Sonbal.Process_Admission.stop(admission);
    status := Sonbal.Process_Admission.release(admission);
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK and then
         Sonbal.Process_Admission.active_count(admission) = 0,
       "stopped admission still releases existing ownership");

    status := Sonbal.Process_Admission.try_acquire(admission, acquired);
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK and then not acquired,
       "stopped admission rejects new work without an error fallback");

    status := Sonbal.Process_Admission.finalize(admission);
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK and then
         not Sonbal.Process_Admission.is_initialized(admission),
       "active-free shared admission finalizes deterministically");
  end shared_admission_lifecycle;

  procedure lifecycle_cursor_and_eviction
    (reporter : in out Clair.Test.Reporter.Context)
  is
    root         : constant String := prepare_workspace("lifecycle");
    loop_context : aliased Clair.Event_Loop.Context;
    workspace    : aliased Sonbal.Workspace_Tokens.Context;
    admission    : aliased Sonbal.Process_Admission.Context;
    jobs         : aliased Sonbal.Process_Jobs.Context;
    rotation      : Sonbal.Workspace_Tokens.Rotation_Result;
    echo_argv    : constant Sonbal.Process_Arguments.Arguments :=
      Sonbal_Test_Support.Process_Arguments ("/bin/echo", "job-output");
    true_argv    : constant Sonbal.Process_Arguments.Arguments :=
      Sonbal_Test_Support.Process_Arguments ("/usr/bin/true");
    started      : Sonbal.Process_Jobs.Start_Result;
    second       : Sonbal.Process_Jobs.Start_Result;
    blocked      : Sonbal.Process_Jobs.Start_Result;
    polled       : Sonbal.Process_Jobs.Poll_Result;
    replayed     : Sonbal.Process_Jobs.Poll_Result;
    exhausted      : Sonbal.Process_Jobs.Poll_Result;
    old_result     : Sonbal.Process_Jobs.Poll_Result;
    missing_result : Sonbal.Process_Jobs.Poll_Result;
    cancel_result  : Sonbal.Process_Jobs.Cancel_Result;
    status         : Clair.Status.Code;
  begin
    status := Clair.Event_Loop.initialize(loop_context);
    Sonbal_Test_Support.check
      (reporter, status = Clair.Status.OK, "job test Event Loop initializes");
    if status /= Clair.Status.OK then
      return;
    end if;

    if not initialize_workspace(reporter, workspace, root, rotation) then
      status := Clair.Event_Loop.finalize(loop_context);
      cleanup_workspace(root);
      return;
    end if;

    status := Sonbal.Process_Admission.initialize
      (admission, Sonbal.Configuration.Work_Slot_Count(1));
    Sonbal_Test_Support.check
      (reporter, status = Clair.Status.OK, "shared admission initializes");
    if status /= Clair.Status.OK then
      status := Clair.Event_Loop.finalize(loop_context);
      return;
    end if;

    status := Sonbal.Process_Jobs.initialize
      (jobs, loop_context, workspace, admission,
       Sonbal.Configuration.Work_Slot_Count(1));
    Sonbal_Test_Support.check
      (reporter, status = Clair.Status.OK, "bounded job registry initializes");
    if status /= Clair.Status.OK then
      status := Clair.Event_Loop.finalize(loop_context);
      return;
    end if;

    Sonbal.Process_Jobs.start
      (jobs,
       Sonbal.Workspace_Tokens.image(rotation.token),
       echo_argv,
       Clair.Process.Execution.Exact_Path,
       root,
       2_000,
       started);
    declare
      job_id : constant String := Sonbal.Process_Jobs.image(started.job_id);
      cursor : constant String := Sonbal.Process_Jobs.image(started.cursor);
    begin
      Sonbal_Test_Support.check
        (reporter,
         started.state = Sonbal.Process_Jobs.Start_Running and then
           job_id'length = Sonbal.Process_Jobs.MAXIMUM_JOB_ID_BYTES and then
           job_id(job_id'first .. job_id'first + 1) = "j-" and then
           job_id(35 .. 50) = "0000000000000001" and then
           cursor = job_id & ":0:0",
         "start returns instance-bound opaque job identity and initial cursor");

      declare
        forged_id : String := job_id;
        future_id : String := job_id;
      begin
        forged_id(forged_id'last) :=
          (if forged_id(forged_id'last) = '0' then '1' else '0');
        Sonbal.Process_Jobs.poll(jobs, forged_id, cursor, missing_result);
        Sonbal_Test_Support.check
          (reporter,
           missing_result.state = Sonbal.Process_Jobs.Poll_Not_Found,
           "wrong job secret remains not_found without exposing retained data");

        Sonbal.Process_Jobs.cancel(jobs, forged_id, cancel_result);
        Sonbal_Test_Support.check
          (reporter,
           cancel_result.state = Sonbal.Process_Jobs.Cancel_Not_Found,
           "wrong job secret remains not_found for cancellation");

        future_id(35 .. 50) := "ffffffffffffffff";
        Sonbal.Process_Jobs.poll(jobs, future_id, cursor, missing_result);
        Sonbal_Test_Support.check
          (reporter,
           missing_result.state = Sonbal.Process_Jobs.Poll_Not_Found,
           "future current-instance sequence remains not_found");
      end;

      Sonbal.Process_Jobs.poll(jobs, job_id, cursor, polled);
      Sonbal_Test_Support.check
        (reporter,
         polled.state = Sonbal.Process_Jobs.Poll_Running and then
           polled.stdout.length = 0 and then polled.stderr.length = 0 and then
           Sonbal.Process_Jobs.image(polled.next_cursor) = cursor,
         "running poll is bounded and does not advance a hidden cursor");

      Sonbal.Process_Jobs.poll(jobs, job_id, job_id & ":00:0", replayed);
      Sonbal_Test_Support.check
        (reporter,
         replayed.state = Sonbal.Process_Jobs.Poll_Invalid_Cursor,
         "noncanonical cursor spelling is rejected");

      wait_terminal(loop_context, jobs, job_id, cursor, polled, status);
      Sonbal_Test_Support.check
        (reporter,
         status = Clair.Status.OK and then
           polled.state = Sonbal.Process_Jobs.Poll_Terminal and then
           polled.terminal = Sonbal.Process_Jobs.Job_Exited and then
           polled.has_exit_code and then polled.exit_code = 0 and then
           stream_text(polled.stdout) =
             "job-output" & Character'val(10) and then
           polled.stderr.length = 0,
         "terminal poll publishes settled exit state and retained stdout");

      Sonbal.Process_Jobs.poll(jobs, job_id, cursor, replayed);
      Sonbal_Test_Support.check
        (reporter,
         replayed.state = Sonbal.Process_Jobs.Poll_Terminal and then
           stream_text(replayed.stdout) = stream_text(polled.stdout) and then
           Sonbal.Process_Jobs.image(replayed.next_cursor) =
             Sonbal.Process_Jobs.image(polled.next_cursor),
         "repeating one cursor returns the identical retained increment");

      Sonbal.Process_Jobs.poll
        (jobs,
         job_id,
         Sonbal.Process_Jobs.image(polled.next_cursor),
         exhausted);
      Sonbal_Test_Support.check
        (reporter,
         exhausted.state = Sonbal.Process_Jobs.Poll_Terminal and then
           exhausted.stdout.length = 0 and then exhausted.stderr.length = 0,
         "advanced cursor reaches an idempotent empty terminal increment");

      Sonbal.Process_Jobs.start
        (jobs,
         Sonbal.Workspace_Tokens.image(rotation.token),
         true_argv,
         Clair.Process.Execution.Exact_Path,
         root,
         2_000,
         second);
      Sonbal_Test_Support.check
        (reporter,
         second.state = Sonbal.Process_Jobs.Start_Running and then
           Sonbal.Process_Jobs.image(second.job_id) /= job_id,
         "new admission uses separate active capacity with a fresh id");

      Sonbal.Process_Jobs.start
        (jobs,
         Sonbal.Workspace_Tokens.image(rotation.token),
         true_argv,
         Clair.Process.Execution.Exact_Path,
         root,
         2_000,
         blocked);
      Sonbal_Test_Support.check
        (reporter,
         blocked.state = Sonbal.Process_Jobs.Start_Execution_Busy,
         "shared saturation refuses a third job without queuing");

      Sonbal.Process_Jobs.poll(jobs, job_id, cursor, old_result);
      Sonbal_Test_Support.check
        (reporter,
         old_result.state = Sonbal.Process_Jobs.Poll_Terminal and then
           stream_text(old_result.stdout) = stream_text(polled.stdout),
         "busy start does not evict an already retained terminal result");

      declare
        second_id     : constant String :=
          Sonbal.Process_Jobs.image(second.job_id);
        second_cursor : constant String :=
          Sonbal.Process_Jobs.image(second.cursor);
        started_at    : constant Ada.Real_Time.Time := Ada.Real_Time.clock;
      begin
        wait_terminal
          (loop_context, jobs, second_id, second_cursor, replayed, status);
        declare
          settled : constant Boolean :=
            status = Clair.Status.OK and then
            replayed.state = Sonbal.Process_Jobs.Poll_Terminal and then
            replayed.terminal = Sonbal.Process_Jobs.Job_Exited;
          elapsed : constant Duration :=
            Ada.Real_Time.To_Duration(Ada.Real_Time.clock - started_at);
          detail  : constant String :=
            (if settled then
               "next job settles before terminal retention rotation"
             else
               "next job settlement state: status=" &
               Clair.Status.Code'image(status) &
               " poll=" & Sonbal.Process_Jobs.Poll_State'image(replayed.state) &
               " terminal=" &
               Sonbal.Process_Jobs.Terminal_State'image(replayed.terminal) &
               " elapsed=" & Duration'image(elapsed));
        begin
          Sonbal_Test_Support.check (reporter, settled, detail);
        end;
      end;

      Sonbal.Process_Jobs.poll(jobs, job_id, cursor, old_result);
      Sonbal_Test_Support.check
        (reporter,
         old_result.state = Sonbal.Process_Jobs.Poll_Expired,
         "oldest terminal identity becomes expired when retention rotates");

      Sonbal.Process_Jobs.cancel(jobs, job_id, cancel_result);
      Sonbal_Test_Support.check
        (reporter,
         cancel_result.state = Sonbal.Process_Jobs.Cancel_Expired,
         "evicted terminal identity is also expired for cancellation");

      status := Sonbal.Process_Jobs.finalize(jobs);
      Sonbal_Test_Support.check
        (reporter,
         status = Clair.Status.OK and then
           not Sonbal.Process_Jobs.is_initialized(jobs),
         "completed registry finalizes before instance rotation");

      if status = Clair.Status.OK then
        status := Sonbal.Process_Jobs.initialize
          (jobs, loop_context, workspace, admission,
           Sonbal.Configuration.Work_Slot_Count(1));
        Sonbal_Test_Support.check
          (reporter,
           status = Clair.Status.OK,
           "fresh registry mints a new server instance");

        if status = Clair.Status.OK then
          Sonbal.Process_Jobs.poll(jobs, job_id, cursor, old_result);
          Sonbal_Test_Support.check
            (reporter,
             old_result.state = Sonbal.Process_Jobs.Poll_Stale_Instance,
             "prior-lifetime job identity becomes stale_instance");

          Sonbal.Process_Jobs.cancel(jobs, job_id, cancel_result);
          Sonbal_Test_Support.check
            (reporter,
             cancel_result.state =
               Sonbal.Process_Jobs.Cancel_Stale_Instance,
             "prior-lifetime cancellation reports stale_instance");
        end if;
      end if;
    end;

    finalize_fixture(reporter, loop_context, workspace, admission, jobs);
    cleanup_workspace(root);
  end lifecycle_cursor_and_eviction;

  procedure live_capture_cursor_continuity
    (reporter : in out Clair.Test.Reporter.Context)
  is
    root         : constant String := prepare_workspace("live");
    loop_context : aliased Clair.Event_Loop.Context;
    workspace    : aliased Sonbal.Workspace_Tokens.Context;
    admission    : aliased Sonbal.Process_Admission.Context;
    jobs         : aliased Sonbal.Process_Jobs.Context;
    rotation      : Sonbal.Workspace_Tokens.Rotation_Result;
    live_argv    : constant Sonbal.Process_Arguments.Arguments :=
      Sonbal_Test_Support.Process_Arguments
        ("/bin/sh",
         "-c",
         "dd if=/dev/zero bs=65536 count=1 2>/dev/null; " &
         "printf live-err >&2; sleep 3");
    started      : Sonbal.Process_Jobs.Start_Result;
    observed     : Sonbal.Process_Jobs.Poll_Result;
    replayed     : Sonbal.Process_Jobs.Poll_Result;
    advanced     : Sonbal.Process_Jobs.Poll_Result;
    invalid      : Sonbal.Process_Jobs.Poll_Result;
    terminal     : Sonbal.Process_Jobs.Poll_Result;
    status       : Clair.Status.Code;
    dispatched   : Boolean := False;
    saw_live     : Boolean := False;
    deadline     : Ada.Real_Time.Time;
  begin
    status := Clair.Event_Loop.initialize(loop_context);
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK,
       "live-capture Event Loop initializes");
    if status /= Clair.Status.OK then
      return;
    end if;

    if not initialize_workspace(reporter, workspace, root, rotation) then
      status := Clair.Event_Loop.finalize(loop_context);
      cleanup_workspace(root);
      return;
    end if;

    status := Sonbal.Process_Admission.initialize
      (admission, Sonbal.Configuration.Work_Slot_Count(1));
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK,
       "live-capture admission initializes");
    if status /= Clair.Status.OK then
      status := Clair.Event_Loop.finalize(loop_context);
      return;
    end if;

    status := Sonbal.Process_Jobs.initialize
      (jobs, loop_context, workspace, admission,
       Sonbal.Configuration.Work_Slot_Count(1));
    Sonbal_Test_Support.check
      (reporter, status = Clair.Status.OK, "live-capture registry initializes");
    if status /= Clair.Status.OK then
      status := Sonbal.Process_Admission.finalize(admission);
      status := Clair.Event_Loop.finalize(loop_context);
      return;
    end if;

    Sonbal.Process_Jobs.start
      (jobs,
       Sonbal.Workspace_Tokens.image(rotation.token),
       live_argv,
       Clair.Process.Execution.Exact_Path,
       root,
       6_000,
       started);
    Sonbal_Test_Support.check
      (reporter,
       started.state = Sonbal.Process_Jobs.Start_Running,
       "live-capture job starts asynchronously");

    declare
      job_id : constant String := Sonbal.Process_Jobs.image(started.job_id);
      cursor : constant String := Sonbal.Process_Jobs.image(started.cursor);
    begin
      deadline := Ada.Real_Time.clock + Ada.Real_Time.Seconds(2);
      while not saw_live and then
            status = Clair.Status.OK and then
            Ada.Real_Time.clock < deadline
      loop
        status := Clair.Event_Loop.iterate
          (self       => loop_context,
           timeout    => 25,
           dispatched => dispatched);
        exit when status /= Clair.Status.OK;

        Sonbal.Process_Jobs.poll(jobs, job_id, cursor, observed);
        saw_live :=
          observed.state = Sonbal.Process_Jobs.Poll_Running and then
          observed.stdout.length =
            Sonbal.Process_Jobs.POLL_STREAM_BYTES and then
          observed.stdout.truncated and then
          stream_is_zeroes(observed.stdout) and then
          stream_text(observed.stderr) = "live-err" and then
          not observed.stderr.truncated;
      end loop;

      Sonbal_Test_Support.check
        (reporter,
         status = Clair.Status.OK and then saw_live,
         "running poll observes binary stdout and stderr before completion");

      if saw_live then
        Sonbal.Process_Jobs.poll(jobs, job_id, cursor, replayed);
        Sonbal_Test_Support.check
          (reporter,
           replayed.state = Sonbal.Process_Jobs.Poll_Running and then
             streams_equal(replayed.stdout, observed.stdout) and then
             streams_equal(replayed.stderr, observed.stderr) and then
             Sonbal.Process_Jobs.image(replayed.next_cursor) =
               Sonbal.Process_Jobs.image(observed.next_cursor),
           "same live cursor replays the identical bounded increment");

        declare
          next_cursor : constant String :=
            Sonbal.Process_Jobs.image(observed.next_cursor);
        begin
          Sonbal.Process_Jobs.poll(jobs, job_id, next_cursor, advanced);
          Sonbal_Test_Support.check
            (reporter,
             advanced.state = Sonbal.Process_Jobs.Poll_Running and then
               advanced.stdout.length =
                 Sonbal.Process_Jobs.POLL_STREAM_BYTES and then
               advanced.stdout.truncated and then
               stream_is_zeroes(advanced.stdout) and then
               advanced.stderr.length = 0 and then
               Sonbal.Process_Jobs.image(advanced.next_cursor) =
                 job_id & ":16384:8",
             "advanced live cursor reads the next retained prefix slice");

          Sonbal.Process_Jobs.poll
            (jobs, job_id, job_id & ":32768:9", invalid);
          Sonbal_Test_Support.check
            (reporter,
             invalid.state = Sonbal.Process_Jobs.Poll_Invalid_Cursor,
             "running poll rejects a cursor beyond a retained stream");

          wait_terminal
            (loop_context, jobs, job_id, next_cursor, terminal, status);
          Sonbal_Test_Support.check
            (reporter,
             status = Clair.Status.OK and then
               terminal.state = Sonbal.Process_Jobs.Poll_Terminal and then
               terminal.terminal = Sonbal.Process_Jobs.Job_Exited and then
               terminal.has_exit_code and then terminal.exit_code = 0 and then
               streams_equal(terminal.stdout, advanced.stdout) and then
               streams_equal(terminal.stderr, advanced.stderr) and then
               Sonbal.Process_Jobs.image(terminal.next_cursor) =
                 Sonbal.Process_Jobs.image(advanced.next_cursor),
             "running cursor remains byte-stable across terminal publication");
        end;
      end if;
    end;

    finalize_fixture(reporter, loop_context, workspace, admission, jobs);
    cleanup_workspace(root);
  end live_capture_cursor_continuity;

  procedure token_rotation_replacement_fences_new_work_only
    (reporter : in out Clair.Test.Reporter.Context)
  is
    root            : constant String := prepare_workspace ("rotation-replace");
    loop_context    : aliased Clair.Event_Loop.Context;
    workspace       : aliased Sonbal.Workspace_Tokens.Context;
    admission       : aliased Sonbal.Process_Admission.Context;
    jobs            : aliased Sonbal.Process_Jobs.Context;
    sync_process    : aliased Sonbal.Process_Execution.Operation;
    delayed_process : aliased Sonbal.Process_Execution.Operation;
    sync_handler    : aliased Owned_Completion;
    delayed_handler : aliased Owned_Completion;
    first_rotation      : Sonbal.Workspace_Tokens.Rotation_Result;
    second_rotation     : Sonbal.Workspace_Tokens.Rotation_Result;
    job_started     : Sonbal.Process_Jobs.Start_Result;
    stale_job       : Sonbal.Process_Jobs.Start_Result;
    job_poll        : Sonbal.Process_Jobs.Poll_Result;
    job_cancel      : Sonbal.Process_Jobs.Cancel_Result;
    sleep_argv      : constant Sonbal.Process_Arguments.Arguments :=
      Sonbal_Test_Support.Process_Arguments ("/bin/sleep", "30");
    true_argv       : constant Sonbal.Process_Arguments.Arguments :=
      Sonbal_Test_Support.Process_Arguments ("/usr/bin/true");
    start_state   : Sonbal.Process_Execution.Workspace_Start_State;
    status          : Clair.Status.Code;
    dispatched      : Boolean := False;
    deadline        : Ada.Real_Time.Time;
  begin
    status := Clair.Event_Loop.initialize (loop_context);
    Sonbal_Test_Support.check
      (reporter, status = Clair.Status.OK, "rotation Event Loop initializes");
    if status /= Clair.Status.OK then
      cleanup_workspace (root);
      return;
    end if;

    status := Sonbal.Workspace_Tokens.initialize
      (workspace, Sonbal.Configuration.Work_Slot_Count (2));
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK,
       "workspace rotation registry initializes");
    if status = Clair.Status.OK then
      status := rotate_workspace_token (workspace, root, first_rotation);
    end if;
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK and then
         first_rotation.state = Sonbal.Workspace_Tokens.Rotation_Rotated,
       "first workspace rotation opens");

    if status = Clair.Status.OK then
      status := Sonbal.Process_Admission.initialize
        (admission, Sonbal.Configuration.Work_Slot_Count (2));
    end if;
    Sonbal_Test_Support.check
      (reporter, status = Clair.Status.OK, "rotation admission initializes");
    if status = Clair.Status.OK then
      status := Sonbal.Process_Jobs.initialize
        (jobs,
         loop_context,
         workspace,
         admission,
         Sonbal.Configuration.Work_Slot_Count (2));
    end if;
    Sonbal_Test_Support.check
      (reporter, status = Clair.Status.OK, "workspace rotation job registry initializes");
    if status = Clair.Status.OK then
      status := Sonbal.Process_Execution.initialize
        (sync_process, loop_context);
    end if;
    if status = Clair.Status.OK then
      status := Sonbal.Process_Execution.initialize
        (delayed_process, loop_context);
    end if;
    Sonbal_Test_Support.check
      (reporter, status = Clair.Status.OK, "workspace process slots initialize");
    if status /= Clair.Status.OK then
      cleanup_workspace (root);
      return;
    end if;

    declare
      old_token : constant String :=
        Sonbal.Workspace_Tokens.image (first_rotation.token);
    begin
      status := Sonbal.Process_Execution.start_workspace
        (self              => sync_process,
         workspace_tokens       => workspace,
         admission         => admission,
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
             Sonbal.Process_Execution.Workspace_Start_Running and then
           Sonbal.Process_Execution.is_active (sync_process) and then
           Sonbal.Process_Admission.active_count (admission) = 1 and then
           Sonbal.Workspace_Tokens.active_work_count (workspace) = 1,
         "first rotation starts synchronous work");

      Sonbal.Process_Jobs.start
        (jobs,
         old_token,
         sleep_argv,
         Clair.Process.Execution.Exact_Path,
         root,
         30_000,
         job_started);
      Sonbal_Test_Support.check
        (reporter,
         job_started.state = Sonbal.Process_Jobs.Start_Running and then
           Sonbal.Process_Admission.active_count (admission) = 2 and then
           Sonbal.Workspace_Tokens.active_work_count (workspace) = 2,
         "first rotation starts one server-owned job");

      delay until
        Ada.Real_Time.Clock +
          Ada.Real_Time.Milliseconds
            (Sonbal.Workspace_Tokens.ROTATE_WORKSPACE_TOKEN_COOLDOWN_MS + 50);
      status := rotate_workspace_token (workspace, root, second_rotation);
      Sonbal_Test_Support.check
        (reporter,
         status = Clair.Status.OK and then
           second_rotation.state = Sonbal.Workspace_Tokens.Rotation_Rotated and then
           Sonbal.Workspace_Tokens.image (second_rotation.token) /=
             old_token and then
           Sonbal.Process_Execution.is_active (sync_process) and then
           Sonbal.Process_Admission.active_count (admission) = 2 and then
           Sonbal.Workspace_Tokens.active_work_count (workspace) = 2,
         "new rotation invalidates old token without cancelling accepted work");

      status := Sonbal.Process_Execution.start_workspace
        (self              => delayed_process,
         workspace_tokens       => workspace,
         admission         => admission,
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
           not Sonbal.Process_Execution.has_runtime_resources
             (delayed_process) and then
           Sonbal.Process_Admission.active_count (admission) = 2 and then
           Sonbal.Workspace_Tokens.active_work_count (workspace) = 2,
         "old synchronous request is stale before process admission");

      Sonbal.Process_Jobs.start
        (jobs,
         old_token,
         true_argv,
         Clair.Process.Execution.Exact_Path,
         root,
         2_000,
         stale_job);
      Sonbal_Test_Support.check
        (reporter,
         stale_job.state = Sonbal.Process_Jobs.Start_Stale_Workspace_Token and then
           Sonbal.Process_Admission.active_count (admission) = 2 and then
           Sonbal.Workspace_Tokens.active_work_count (workspace) = 2,
         "old job request is stale without consuming extra capacity");

      Sonbal.Process_Jobs.poll
        (jobs,
         Sonbal.Process_Jobs.image (job_started.job_id),
         Sonbal.Process_Jobs.image (job_started.cursor),
         job_poll);
      Sonbal_Test_Support.check
        (reporter,
         job_poll.state = Sonbal.Process_Jobs.Poll_Running and then
           Sonbal.Process_Execution.is_active (sync_process),
         "rotation replacement leaves accepted sync and job work running");

      status := Sonbal.Process_Execution.cancel (sync_process);
      Sonbal_Test_Support.check
        (reporter,
         status = Clair.Status.OK,
         "accepted sync work cancels normally");
      Sonbal.Process_Jobs.cancel
        (jobs, Sonbal.Process_Jobs.image (job_started.job_id), job_cancel);
      Sonbal_Test_Support.check
        (reporter,
         job_cancel.state = Sonbal.Process_Jobs.Cancel_Cancelling,
         "accepted job cancels through normal job authority");

      deadline := Ada.Real_Time.Clock + Ada.Real_Time.Seconds (5);
      loop
        Sonbal.Process_Jobs.poll
          (jobs,
           Sonbal.Process_Jobs.image (job_started.job_id),
           Sonbal.Process_Jobs.image (job_started.cursor),
           job_poll);
        exit when
          not Sonbal.Process_Execution.is_active (sync_process) and then
          job_poll.state = Sonbal.Process_Jobs.Poll_Terminal;
        exit when Ada.Real_Time.Clock >= deadline;
        status := Clair.Event_Loop.iterate
          (self       => loop_context,
           timeout    => 50,
           dispatched => dispatched);
        exit when status /= Clair.Status.OK;
      end loop;

      Sonbal_Test_Support.check
        (reporter,
         status = Clair.Status.OK and then
           sync_handler.call_count = 1 and then
           job_poll.state = Sonbal.Process_Jobs.Poll_Terminal and then
           Sonbal.Process_Admission.active_count (admission) = 0 and then
           Sonbal.Workspace_Tokens.active_work_count (workspace) = 0,
         "accepted old-token work settles exactly once after replacement");

      status := Sonbal.Process_Execution.start_workspace
        (self              => delayed_process,
         workspace_tokens       => workspace,
         admission         => admission,
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
         "current rotation starts new work after old work settles");

      deadline := Ada.Real_Time.Clock + Ada.Real_Time.Seconds (3);
      while Sonbal.Process_Execution.is_active (delayed_process) and then
            Ada.Real_Time.Clock < deadline and then status = Clair.Status.OK
      loop
        status := Clair.Event_Loop.iterate
          (self       => loop_context,
           timeout    => 50,
           dispatched => dispatched);
      end loop;
      Sonbal_Test_Support.check
        (reporter,
         status = Clair.Status.OK and then
           not Sonbal.Process_Execution.is_active (delayed_process) and then
           delayed_handler.call_count = 1 and then
           Sonbal.Workspace_Tokens.active_work_count (workspace) = 0,
         "current-token work completes normally");

    end;

    status := Sonbal.Process_Jobs.begin_shutdown (jobs);
    Sonbal_Test_Support.check
      (reporter, status = Clair.Status.OK, "rotation jobs stop cleanly");
    status := Sonbal.Process_Jobs.finalize (jobs);
    Sonbal_Test_Support.check
      (reporter, status = Clair.Status.OK, "rotation job registry finalizes");
    status := Sonbal.Process_Execution.finalize (sync_process);
    Sonbal_Test_Support.check
      (reporter, status = Clair.Status.OK, "sync process finalizes");
    status := Sonbal.Process_Execution.finalize (delayed_process);
    Sonbal_Test_Support.check
      (reporter, status = Clair.Status.OK, "replacement process finalizes");
    status := Sonbal.Process_Admission.finalize (admission);
    Sonbal_Test_Support.check
      (reporter, status = Clair.Status.OK, "rotation admission finalizes");
    status := Sonbal.Workspace_Tokens.finalize (workspace);
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK,
       "workspace rotation registry finalizes");
    status := Clair.Event_Loop.finalize (loop_context);
    Sonbal_Test_Support.check
      (reporter, status = Clair.Status.OK, "rotation Event Loop finalizes");
    cleanup_workspace (root);
  end token_rotation_replacement_fences_new_work_only;

  procedure capacity_cancel_and_settlement
    (reporter : in out Clair.Test.Reporter.Context)
  is
    root         : constant String := prepare_workspace("cancel");
    loop_context : aliased Clair.Event_Loop.Context;
    workspace    : aliased Sonbal.Workspace_Tokens.Context;
    admission    : aliased Sonbal.Process_Admission.Context;
    jobs         : aliased Sonbal.Process_Jobs.Context;
    rotation      : Sonbal.Workspace_Tokens.Rotation_Result;
    sleep_argv   : constant Sonbal.Process_Arguments.Arguments :=
      Sonbal_Test_Support.Process_Arguments ("/bin/sleep", "30");
    true_argv    : constant Sonbal.Process_Arguments.Arguments :=
      Sonbal_Test_Support.Process_Arguments ("/usr/bin/true");
    started      : Sonbal.Process_Jobs.Start_Result;
    rejected     : Sonbal.Process_Jobs.Start_Result;
    cancelled    : Sonbal.Process_Jobs.Cancel_Result;
    again        : Sonbal.Process_Jobs.Cancel_Result;
    terminal     : Sonbal.Process_Jobs.Poll_Result;
    status       : Clair.Status.Code;
  begin
    status := Clair.Event_Loop.initialize(loop_context);
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK,
       "cancel test Event Loop initializes");
    if status /= Clair.Status.OK then
      return;
    end if;

    if not initialize_workspace(reporter, workspace, root, rotation) then
      status := Clair.Event_Loop.finalize(loop_context);
      cleanup_workspace(root);
      return;
    end if;

    status := Sonbal.Process_Admission.initialize
      (admission, Sonbal.Configuration.Work_Slot_Count(1));
    Sonbal_Test_Support.check
      (reporter, status = Clair.Status.OK, "shared admission initializes");
    if status /= Clair.Status.OK then
      status := Clair.Event_Loop.finalize(loop_context);
      return;
    end if;

    status := Sonbal.Process_Jobs.initialize
      (jobs, loop_context, workspace, admission,
       Sonbal.Configuration.Work_Slot_Count(1));
    if status /= Clair.Status.OK then
      Sonbal_Test_Support.check
        (reporter, False, "cancel job registry initializes");
      status := Clair.Event_Loop.finalize(loop_context);
      return;
    end if;

    Sonbal.Process_Jobs.start
      (jobs,
       Sonbal.Workspace_Tokens.image(rotation.token),
       sleep_argv,
       Clair.Process.Execution.Exact_Path,
       root,
       30_000,
       started);
    Sonbal.Process_Jobs.start
      (jobs,
       Sonbal.Workspace_Tokens.image(rotation.token),
       true_argv,
       Clair.Process.Execution.Exact_Path,
       root,
       2_000,
       rejected);
    Sonbal_Test_Support.check
      (reporter,
       started.state = Sonbal.Process_Jobs.Start_Running and then
         rejected.state = Sonbal.Process_Jobs.Start_Execution_Busy,
       "active-job capacity rejects overload without a hidden queue");

    declare
      job_id : constant String := Sonbal.Process_Jobs.image(started.job_id);
      cursor : constant String := Sonbal.Process_Jobs.image(started.cursor);
    begin
      Sonbal.Process_Jobs.cancel(jobs, job_id, cancelled);
      Sonbal.Process_Jobs.cancel(jobs, job_id, again);
      Sonbal_Test_Support.check
        (reporter,
         cancelled.state = Sonbal.Process_Jobs.Cancel_Cancelling and then
           again.state = Sonbal.Process_Jobs.Cancel_Cancelling,
         "cancellation request is bounded and idempotent while settling");

      wait_terminal(loop_context, jobs, job_id, cursor, terminal, status);
      Sonbal_Test_Support.check
        (reporter,
         status = Clair.Status.OK and then
           terminal.state = Sonbal.Process_Jobs.Poll_Terminal and then
           terminal.terminal = Sonbal.Process_Jobs.Job_Cancelled,
         "terminal poll, not cancel acknowledgement, proves settlement");

      Sonbal.Process_Jobs.cancel(jobs, job_id, again);
      Sonbal_Test_Support.check
        (reporter,
         again.state = Sonbal.Process_Jobs.Cancel_Already_Terminal,
         "cancelling an already settled job is an idempotent terminal result");
    end;

    finalize_fixture(reporter, loop_context, workspace, admission, jobs);
    cleanup_workspace(root);
  end capacity_cancel_and_settlement;

  procedure diagnostic_trace_is_bounded_and_ordered
    (reporter : in out Clair.Test.Reporter.Context)
  is
    root         : constant String := prepare_workspace ("trace");
    loop_context : aliased Clair.Event_Loop.Context;
    workspace    : aliased Sonbal.Workspace_Tokens.Context;
    admission    : aliased Sonbal.Process_Admission.Context;
    jobs         : aliased Sonbal.Process_Jobs.Context;
    rotation     : Sonbal.Workspace_Tokens.Rotation_Result;
    sleep_argv   : constant Sonbal.Process_Arguments.Arguments :=
      Sonbal_Test_Support.Process_Arguments ("/bin/sleep", "30");
    delayed_exit_argv : constant Sonbal.Process_Arguments.Arguments :=
      Sonbal_Test_Support.Process_Arguments ("/bin/sleep", "1");
    started      : Sonbal.Process_Jobs.Start_Result;
    polled       : Sonbal.Process_Jobs.Poll_Result;
    cancelled    : Sonbal.Process_Jobs.Cancel_Result;
    terminal     : Sonbal.Process_Jobs.Poll_Result;
    status       : Clair.Status.Code;

    function find_kind
      (kind  : String;
       after : Natural := 0) return Natural
    is
    begin
      if Sonbal.Process_Jobs.Tester.trace_event_count (jobs) = 0 then
        return 0;
      end if;

      for position in
        Positive'Max (1, after + 1) ..
        Sonbal.Process_Jobs.Tester.trace_event_count (jobs)
      loop
        if Sonbal.Process_Jobs.Tester.trace_event_kind
          (jobs, position) = kind
        then
          return position;
        end if;
      end loop;
      return 0;
    end find_kind;

    function find_kind_outcome
      (kind    : String;
       outcome : String;
       after   : Natural := 0) return Natural
    is
    begin
      if Sonbal.Process_Jobs.Tester.trace_event_count (jobs) = 0 then
        return 0;
      end if;

      for position in
        Positive'Max (1, after + 1) ..
        Sonbal.Process_Jobs.Tester.trace_event_count (jobs)
      loop
        if Sonbal.Process_Jobs.Tester.trace_event_kind
          (jobs, position) = kind and then
           Sonbal.Process_Jobs.Tester.trace_event_outcome
             (jobs, position) = outcome
        then
          return position;
        end if;
      end loop;
      return 0;
    end find_kind_outcome;

    function retained_trace_is_ordered return Boolean is
      count            : constant Natural :=
        Sonbal.Process_Jobs.Tester.trace_event_count (jobs);
      previous_ordinal : Interfaces.Unsigned_64 := 0;
      previous_time    : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
      ordinal          : Interfaces.Unsigned_64;
      event_time       : Ada.Real_Time.Time;
    begin
      if count = 0 then
        return False;
      end if;

      for position in 1 .. count loop
        ordinal := Sonbal.Process_Jobs.Tester.trace_event_ordinal
          (jobs, position);
        event_time := Sonbal.Process_Jobs.Tester.trace_event_time
          (jobs, position);
        if ordinal = 0 or else
           (position > 1 and then
            (ordinal <= previous_ordinal or else event_time < previous_time))
        then
          return False;
        end if;
        previous_ordinal := ordinal;
        previous_time := event_time;
      end loop;
      return True;
    end retained_trace_is_ordered;

    start_request       : Natural;
    launch_accepted     : Natural;
    start_result         : Natural;
    start_response_ready : Natural;
    poll_request         : Natural;
    poll_result          : Natural;
    poll_response_ready  : Natural;
    cancel_request      : Natural;
    cancel_result        : Natural;
    cancel_response_ready : Natural;
    terminal_observed   : Natural;
    cancellation_settled : Natural;
    terminal_published  : Natural;
    terminal_evicted    : Natural;
    expired_response_ready : Natural;
    correlation         : Interfaces.Unsigned_64 := 0;
  begin
    status := Clair.Event_Loop.initialize (loop_context);
    Sonbal_Test_Support.check
      (reporter, status = Clair.Status.OK, "trace Event Loop initializes");
    if status /= Clair.Status.OK then
      cleanup_workspace (root);
      return;
    end if;

    if not initialize_workspace (reporter, workspace, root, rotation) then
      status := Clair.Event_Loop.finalize (loop_context);
      cleanup_workspace (root);
      return;
    end if;

    status := Sonbal.Process_Admission.initialize
      (admission, Sonbal.Configuration.Work_Slot_Count (1));
    Sonbal_Test_Support.check
      (reporter,
       status = Clair.Status.OK,
       "trace shared admission initializes");
    if status /= Clair.Status.OK then
      status := Sonbal.Workspace_Tokens.finalize (workspace);
      status := Clair.Event_Loop.finalize (loop_context);
      cleanup_workspace (root);
      return;
    end if;

    status := Sonbal.Process_Jobs.initialize
      (jobs,
       loop_context,
       workspace,
       admission,
       Sonbal.Configuration.Work_Slot_Count (1));
    Sonbal_Test_Support.check
      (reporter, status = Clair.Status.OK, "trace job registry initializes");
    if status /= Clair.Status.OK then
      status := Sonbal.Process_Admission.finalize (admission);
      status := Sonbal.Workspace_Tokens.finalize (workspace);
      status := Clair.Event_Loop.finalize (loop_context);
      cleanup_workspace (root);
      return;
    end if;

    Sonbal.Process_Jobs.Tester.enable_trace (jobs);

    Sonbal.Process_Jobs.start
      (jobs,
       Sonbal.Workspace_Tokens.image (rotation.token),
       sleep_argv,
       Clair.Process.Execution.Exact_Path,
       root,
       30_000,
       started);
    Sonbal.Process_Jobs.mark_start_response_ready (jobs, started);
    Sonbal_Test_Support.check
      (reporter,
       started.state = Sonbal.Process_Jobs.Start_Running,
       "trace fixture starts one live job");
    if started.state /= Sonbal.Process_Jobs.Start_Running then
      finalize_fixture (reporter, loop_context, workspace, admission, jobs);
      cleanup_workspace (root);
      return;
    end if;

    declare
      job_id : constant String := Sonbal.Process_Jobs.image (started.job_id);
      cursor : constant String := Sonbal.Process_Jobs.image (started.cursor);
    begin
      Sonbal.Process_Jobs.poll (jobs, job_id, cursor, polled);
      Sonbal.Process_Jobs.mark_poll_response_ready (jobs, polled);
      Sonbal_Test_Support.check
        (reporter,
         polled.state = Sonbal.Process_Jobs.Poll_Running,
         "trace fixture records one running poll");

      Sonbal.Process_Jobs.cancel (jobs, job_id, cancelled);
      Sonbal.Process_Jobs.mark_cancel_response_ready (jobs, cancelled);
      Sonbal_Test_Support.check
        (reporter,
         cancelled.state = Sonbal.Process_Jobs.Cancel_Cancelling,
         "trace fixture records cancellation request");

      start_request := find_kind ("start_request");
      launch_accepted := find_kind ("launch_accepted", start_request);
      start_result := find_kind ("start_result", launch_accepted);
      start_response_ready := find_kind ("start_response_ready", start_result);
      poll_request := find_kind ("poll_request", start_response_ready);
      poll_result := find_kind ("poll_result", poll_request);
      poll_response_ready := find_kind ("poll_response_ready", poll_result);
      cancel_request := find_kind ("cancel_request", poll_response_ready);
      cancel_result := find_kind ("cancel_result", cancel_request);
      cancel_response_ready :=
        find_kind ("cancel_response_ready", cancel_result);

      -- Avoid polling here: each poll emits three trace events and can fill
      -- the bounded ring before the ordering checks on a fast wakeup loop.
      declare
        deadline : constant Ada.Real_Time.Time :=
          Ada.Real_Time.Clock + Ada.Real_Time.Seconds (4);
        dispatched : Boolean := False;
      begin
        loop
          terminal_published :=
            find_kind ("terminal_published", cancel_response_ready);
          exit when terminal_published /= 0 or else
            status /= Clair.Status.OK or else
            Ada.Real_Time.Clock >= deadline;

          status := Clair.Event_Loop.iterate
            (self       => loop_context,
             timeout    => 50,
             dispatched => dispatched);
        end loop;
      end;

      Sonbal.Process_Jobs.poll (jobs, job_id, cursor, terminal);
      Sonbal.Process_Jobs.mark_poll_response_ready (jobs, terminal);
      Sonbal_Test_Support.check
        (reporter,
         status = Clair.Status.OK and then
           terminal.state = Sonbal.Process_Jobs.Poll_Terminal and then
           terminal.terminal = Sonbal.Process_Jobs.Job_Cancelled,
         "trace fixture reaches cancelled terminal publication");

      terminal_observed :=
        find_kind ("terminal_observed", cancel_response_ready);
      cancellation_settled :=
        find_kind ("cancellation_settled", terminal_observed);

      if start_request /= 0 then
        correlation :=
          Sonbal.Process_Jobs.Tester.trace_event_correlation
            (jobs, Positive (start_request));
      end if;

      Sonbal_Test_Support.check
        (reporter,
         start_request /= 0 and then
           launch_accepted > start_request and then
           start_result > launch_accepted and then
           start_response_ready > start_result and then
           poll_request > start_response_ready and then
           poll_result > poll_request and then
           poll_response_ready > poll_result and then
           cancel_request > poll_response_ready and then
           cancel_result > cancel_request and then
           cancel_response_ready > cancel_result and then
           terminal_observed > cancel_response_ready and then
           cancellation_settled > terminal_observed and then
           terminal_published > cancellation_settled,
         "trace events separate runtime results from response-ready " &
           "boundaries");

      Sonbal_Test_Support.check
        (reporter,
         correlation /= 0 and then
           Sonbal.Process_Jobs.Tester.trace_event_correlation
             (jobs, Positive (terminal_published)) = correlation and then
           retained_trace_is_ordered,
         "trace events keep one non-authority correlation and monotonic order");

      declare
        second_started  : Sonbal.Process_Jobs.Start_Result;
        second_terminal : Sonbal.Process_Jobs.Poll_Result;
        second_terminal_published : Natural := 0;
        second_poll_request : Natural := 0;
        second_correlation : Interfaces.Unsigned_64 := 0;
        deadline : constant Ada.Real_Time.Time :=
          Ada.Real_Time.Clock + Ada.Real_Time.Seconds (4);
        dispatched : Boolean := False;
      begin
        Sonbal.Process_Jobs.start
          (jobs,
           Sonbal.Workspace_Tokens.image (rotation.token),
           delayed_exit_argv,
           Clair.Process.Execution.Exact_Path,
           root,
           5_000,
           second_started);
        Sonbal.Process_Jobs.mark_start_response_ready (jobs, second_started);
        second_correlation := second_started.diagnostic_correlation;
        Sonbal_Test_Support.check
          (reporter,
           second_started.state = Sonbal.Process_Jobs.Start_Running and then
             second_correlation /= 0,
           "trace fixture starts retention-replacement job");

        if second_started.state = Sonbal.Process_Jobs.Start_Running then
          loop
            second_terminal_published :=
              find_kind ("terminal_published", terminal_published);
            exit when second_terminal_published /= 0 or else
              status /= Clair.Status.OK or else
              Ada.Real_Time.Clock >= deadline;

            status := Clair.Event_Loop.iterate
              (self       => loop_context,
               timeout    => 50,
               dispatched => dispatched);
          end loop;

          Sonbal_Test_Support.check
            (reporter,
             status = Clair.Status.OK and then
               second_terminal_published > terminal_published and then
               Sonbal.Process_Jobs.Tester.trace_event_correlation
                 (jobs, Positive (second_terminal_published)) =
                   second_correlation,
             "child terminal publication does not require polling");

          declare
            second_job_id : constant String :=
              Sonbal.Process_Jobs.image (second_started.job_id);
            second_cursor : constant String :=
              Sonbal.Process_Jobs.image (second_started.cursor);
          begin
            Sonbal.Process_Jobs.poll
              (jobs, second_job_id, second_cursor, second_terminal);
            Sonbal.Process_Jobs.mark_poll_response_ready
              (jobs, second_terminal);
            second_poll_request :=
              find_kind ("poll_request", second_terminal_published);

            Sonbal_Test_Support.check
              (reporter,
               second_terminal.state =
                 Sonbal.Process_Jobs.Poll_Terminal and then
               second_terminal.terminal =
                 Sonbal.Process_Jobs.Job_Exited and then
               second_poll_request > second_terminal_published,
               "first replacement poll observes already-published child exit");
          end;
        end if;
      end;

      terminal_evicted := find_kind ("terminal_evicted", terminal_published);
      Sonbal.Process_Jobs.poll (jobs, job_id, cursor, polled);
      Sonbal.Process_Jobs.mark_poll_response_ready (jobs, polled);
      expired_response_ready := find_kind_outcome
        ("poll_response_ready", "expired", terminal_evicted);
      Sonbal_Test_Support.check
        (reporter,
         terminal_evicted > terminal_published,
         "trace records retained terminal eviction");
      Sonbal_Test_Support.check
        (reporter,
         terminal_evicted /= 0 and then
           Sonbal.Process_Jobs.Tester.trace_event_correlation
             (jobs, Positive (terminal_evicted)) = correlation,
         "terminal eviction preserves non-authority correlation");
      Sonbal_Test_Support.check
        (reporter,
         polled.state = Sonbal.Process_Jobs.Poll_Expired,
         "evicted job lookup reports expired");
      Sonbal_Test_Support.check
        (reporter,
         expired_response_ready > terminal_evicted and then
           Sonbal.Process_Jobs.Tester.trace_event_outcome
             (jobs, Positive (expired_response_ready)) = "expired",
         "expired lookup records response-ready timing");

      for iteration in
        1 .. Sonbal.Process_Jobs.Tester.trace_capacity + 8
      loop
        Sonbal.Process_Jobs.poll (jobs, job_id, cursor, polled);
        Sonbal.Process_Jobs.mark_poll_response_ready (jobs, polled);
      end loop;

      Sonbal_Test_Support.check
        (reporter,
         Sonbal.Process_Jobs.Tester.trace_event_count (jobs) =
           Sonbal.Process_Jobs.Tester.trace_capacity and then
         Sonbal.Process_Jobs.Tester.trace_overwrite_count (jobs) > 0 and then
         retained_trace_is_ordered,
         "trace storage remains fixed-size under repeated polling");
    end;

    finalize_fixture (reporter, loop_context, workspace, admission, jobs);
    cleanup_workspace (root);
  end diagnostic_trace_is_bounded_and_ordered;

  procedure shutdown_settles_live_jobs
    (reporter : in out Clair.Test.Reporter.Context)
  is
    root         : constant String := prepare_workspace("shutdown");
    loop_context : aliased Clair.Event_Loop.Context;
    workspace    : aliased Sonbal.Workspace_Tokens.Context;
    admission    : aliased Sonbal.Process_Admission.Context;
    jobs         : aliased Sonbal.Process_Jobs.Context;
    rotation      : Sonbal.Workspace_Tokens.Rotation_Result;
    sleep_argv   : constant Sonbal.Process_Arguments.Arguments :=
      Sonbal_Test_Support.Process_Arguments ("/bin/sleep", "30");
    started      : Sonbal.Process_Jobs.Start_Result;
    status       : Clair.Status.Code;
  begin
    status := Clair.Event_Loop.initialize(loop_context);
    if status /= Clair.Status.OK then
      Sonbal_Test_Support.check
        (reporter, False, "shutdown Event Loop initializes");
      cleanup_workspace(root);
      return;
    end if;
    if not initialize_workspace(reporter, workspace, root, rotation) then
      status := Clair.Event_Loop.finalize(loop_context);
      cleanup_workspace(root);
      return;
    end if;
    status := Sonbal.Process_Admission.initialize
      (admission, Sonbal.Configuration.Work_Slot_Count(1));
    Sonbal_Test_Support.check
      (reporter, status = Clair.Status.OK, "shared admission initializes");
    if status /= Clair.Status.OK then
      status := Clair.Event_Loop.finalize(loop_context);
      return;
    end if;

    status := Sonbal.Process_Jobs.initialize
      (jobs, loop_context, workspace, admission,
       Sonbal.Configuration.Work_Slot_Count(1));
    if status /= Clair.Status.OK then
      Sonbal_Test_Support.check
        (reporter, False, "shutdown registry initializes");
      status := Clair.Event_Loop.finalize(loop_context);
      return;
    end if;

    Sonbal.Process_Jobs.start
      (jobs,
       Sonbal.Workspace_Tokens.image(rotation.token),
       sleep_argv,
       Clair.Process.Execution.Exact_Path,
       root,
       30_000,
       started);
    Sonbal_Test_Support.check
      (reporter,
       started.state = Sonbal.Process_Jobs.Start_Running,
       "shutdown fixture starts one live job");

    finalize_fixture(reporter, loop_context, workspace, admission, jobs);
    cleanup_workspace(root);
  end shutdown_settles_live_jobs;

  procedure run (reporter : in out Clair.Test.Reporter.Context) is
  begin
    Clair.Test.Reporter.run_scenario
      (reporter,
       "shared admission lifecycle",
       shared_admission_lifecycle'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "lifecycle cursor and bounded terminal retention",
       lifecycle_cursor_and_eviction'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "live capture cursor continuity",
       live_capture_cursor_continuity'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "rotation replacement fences new work only",
       token_rotation_replacement_fences_new_work_only'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "capacity cancel and settlement",
       capacity_cancel_and_settlement'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "bounded monotonic job diagnostics",
       diagnostic_trace_is_bounded_and_ordered'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "shutdown settles live jobs",
       shutdown_settles_live_jobs'access);
  end run;

end Sonbal_Process_Jobs_Tests;
