-- ============================================================================
-- sonbal-process_runtime.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Ada.Command_Line;
with Clair.Process.POSIX;

package body Sonbal.Process_Runtime is

  use type Clair.IO.Descriptor;
  use type Clair.Status.Code;
  use type Sonbal.Process_Execution.Completion_Handler_Access;
  use type Sonbal.Process_Execution.Operation_Access;

  MAXIMUM_CLEANUP_RETRIES : constant Positive := 3;

  procedure clear_sync_record (record_value : in out Sync_Record) is
  begin
    record_value.active := False;
    record_value.cancelling := False;
    record_value.completion_seen := False;
    record_value.operation := null;
    record_value.client := null;
  end clear_sync_record;

  function first_free_sync_record (self : Context) return Natural is
  begin
    for index in 1 .. self.sync_capacity loop
      if not self.sync_records(index).active then
        return index;
      end if;
    end loop;
    return 0;
  end first_free_sync_record;

  function operation_is_registered
    (self      : Context;
     operation : Sonbal.Process_Execution.Operation_Access)
  return Boolean
  is
  begin
    if operation = null then
      return False;
    end if;

    for index in 1 .. self.sync_capacity loop
      if self.sync_records(index).active and then
         self.sync_records(index).operation = operation
      then
        return True;
      end if;
    end loop;
    return False;
  end operation_is_registered;

  function retry_idle_resources
    (record_value : in out Sync_Record) return Boolean
  is
    status : Clair.Status.Code;
  begin
    if not record_value.active or else record_value.operation = null then
      return True;
    elsif Sonbal.Process_Execution.is_active(record_value.operation.all) then
      return False;
    elsif not Sonbal.Process_Execution.has_runtime_resources
      (record_value.operation.all)
    then
      clear_sync_record(record_value);
      return True;
    end if;

    for attempt in 1 .. MAXIMUM_CLEANUP_RETRIES loop
      status := Sonbal.Process_Execution.settle_idle_resources
        (record_value.operation.all);
      if status = Clair.Status.OK then
        clear_sync_record(record_value);
        return True;
      end if;
    end loop;
    return False;
  end retry_idle_resources;

  function request_sync_cancellation
    (record_value : in out Sync_Record) return Boolean
  is
    status       : Clair.Status.Code;
    retry_status : Clair.Status.Code;
  begin
    if not record_value.active or else record_value.operation = null then
      return True;
    elsif not Sonbal.Process_Execution.is_active
      (record_value.operation.all)
    then
      return retry_idle_resources(record_value);
    elsif record_value.cancelling then
      for attempt in 1 .. MAXIMUM_CLEANUP_RETRIES loop
        retry_status := Sonbal.Process_Execution.retry
          (record_value.operation.all);
        if retry_status in Clair.Status.OK | Clair.Status.INVALID_STATE then
          return True;
        end if;
      end loop;
      return False;
    end if;

    for attempt in 1 .. MAXIMUM_CLEANUP_RETRIES loop
      status := Sonbal.Process_Execution.cancel(record_value.operation.all);
      if status = Clair.Status.OK then
        record_value.cancelling := True;
        return True;
      end if;

      retry_status := Sonbal.Process_Execution.retry
        (record_value.operation.all);
      if retry_status /= Clair.Status.OK and then
         retry_status /= Clair.Status.INVALID_STATE
      then
        return False;
      elsif not Sonbal.Process_Execution.is_active(record_value.operation.all)
      then
        return retry_idle_resources(record_value);
      end if;
    end loop;
    return False;
  end request_sync_cancellation;

  function cancel_all_synchronous
    (self : aliased in out Context) return Clair.Status.Code
  is
    ok : Boolean := True;
  begin
    for index in 1 .. self.sync_capacity loop
      if self.sync_records(index).active then
        ok := request_sync_cancellation(self.sync_records(index)) and then ok;
      end if;
    end loop;
    return (if ok then Clair.Status.OK else Clair.Status.INTERNAL_ERROR);
  exception
    when others =>
      return Clair.Status.INTERNAL_ERROR;
  end cancel_all_synchronous;

  procedure fail_closed (self : in out Context) is
  begin
    self.shutting_down := True;
    if Sonbal.Process_Admission.is_initialized(self.admission) then
      Sonbal.Process_Admission.stop(self.admission);
    end if;
    if Sonbal.Workspace_Tokens.is_initialized (self.workspace_tokens) then
      Sonbal.Workspace_Tokens.stop (self.workspace_tokens);
    end if;
  end fail_closed;

  overriding function on_complete
    (handler   : in out Completion_Bridge;
     operation : not null Sonbal.Process_Execution.Operation_Access;
     cause     : Clair.Process.Execution.Event_Loop.Operation_Cause;
     status    : Clair.Status.Code;
     outcome   : Clair.Process.Execution.Result)
  return Clair.Status.Code
  is
    self     : constant Context_Access := handler.owner;
    client   : Sonbal.Process_Execution.Completion_Handler_Access;
    residue  : Boolean;
    retval   : Clair.Status.Code;
  begin
    if self = null or else not self.initialized or else
       handler.index not in 1 .. self.sync_capacity
    then
      return Clair.Status.INVALID_STATE;
    end if;

    declare
      record_value : Sync_Record renames self.sync_records(handler.index);
    begin
      if not record_value.active or else
         record_value.operation /= operation or else
         record_value.client = null or else record_value.completion_seen
      then
        fail_closed(self.all);
        return Clair.Status.INTERNAL_ERROR;
      end if;

      client := record_value.client;
      record_value.completion_seen := True;
      residue := Sonbal.Process_Execution.has_runtime_resources(operation.all);

      begin
        retval := Sonbal.Process_Execution.on_complete
          (handler   => client.all,
           operation => operation,
           cause     => cause,
           status    => status,
           outcome   => outcome);
      exception
        when others =>
          record_value.client := null;
          if not residue then
            clear_sync_record(record_value);
          else
            fail_closed(self.all);
          end if;
          raise;
      end;

      record_value.client := null;
      if not residue then
        clear_sync_record(record_value);
      else
        fail_closed(self.all);
      end if;
      return retval;
    end;
  exception
    when others =>
      if self /= null then
        fail_closed(self.all);
      end if;
      return Clair.Status.INTERNAL_ERROR;
  end on_complete;

  function close_executable_image
    (self : in out Context) return Clair.Status.Code
  is
    status : Clair.Status.Code;
  begin
    if self.executable_image = Clair.IO.INVALID_DESCRIPTOR then
      return Clair.Status.OK;
    end if;

    status := Clair.IO.close (self.executable_image);
    if status = Clair.Status.OK then
      self.executable_image := Clair.IO.INVALID_DESCRIPTOR;
    end if;
    return status;
  end close_executable_image;

  function initialize
    (self           : aliased in out Context;
     event_loop     : aliased in out Clair.Event_Loop.Context;
     max_work_slots : Sonbal.Configuration.Work_Slot_Count)
  return Clair.Status.Code
  is
    status : Clair.Status.Code;
    cleanup_status : Clair.Status.Code;
    primary : Clair.Status.Code := Clair.Status.OK;
  begin
    if self.initialized or else
       self.executable_image /= Clair.IO.INVALID_DESCRIPTOR or else
       Sonbal.Workspace_Tokens.is_initialized (self.workspace_tokens) or else
       Sonbal.Process_Admission.is_initialized (self.admission) or else
       Sonbal.Process_Jobs.is_initialized (self.jobs)
    then
      return Clair.Status.INVALID_STATE;
    end if;

    status := Clair.Process.POSIX.open_current_executable_image
      (self.executable_image);
    if status /= Clair.Status.OK then
      return status;
    end if;

    self.sync_capacity := Natural(max_work_slots);
    for index in 1 .. self.sync_capacity loop
      clear_sync_record(self.sync_records(index));
      self.sync_records(index).bridge.owner := self'unchecked_access;
      self.sync_records(index).bridge.index := index;
    end loop;

    status := Sonbal.Workspace_Tokens.initialize
      (self.workspace_tokens, max_work_slots);
    if status /= Clair.Status.OK then
      self.sync_capacity := 0;
      cleanup_status := close_executable_image (self);
      return
        (if cleanup_status = Clair.Status.OK then status else cleanup_status);
    end if;

    status := Sonbal.Process_Admission.initialize
      (self.admission, max_work_slots);
    if status /= Clair.Status.OK then
      cleanup_status := Sonbal.Workspace_Tokens.finalize (self.workspace_tokens);
      if cleanup_status = Clair.Status.OK then
        cleanup_status := close_executable_image (self);
      end if;
      self.sync_capacity := 0;
      return
        (if cleanup_status = Clair.Status.OK then status else cleanup_status);
    end if;

    status := Sonbal.Process_Jobs.initialize
      (self.jobs,
       event_loop,
       self.workspace_tokens,
       self.admission,
       max_work_slots);
    if status /= Clair.Status.OK then
      cleanup_status := Sonbal.Process_Admission.finalize(self.admission);
      if cleanup_status = Clair.Status.OK then
        cleanup_status := Sonbal.Workspace_Tokens.finalize
          (self.workspace_tokens);
      end if;
      if cleanup_status = Clair.Status.OK then
        cleanup_status := close_executable_image (self);
      end if;
      self.sync_capacity := 0;
      return
        (if cleanup_status = Clair.Status.OK then status else cleanup_status);
    end if;

    self.initialized := True;
    self.shutting_down := False;
    return Clair.Status.OK;
  exception
    when others =>
      if Sonbal.Process_Jobs.is_initialized(self.jobs) and then
         Sonbal.Process_Jobs.is_idle(self.jobs)
      then
        cleanup_status := Sonbal.Process_Jobs.finalize(self.jobs);
        if cleanup_status /= Clair.Status.OK then
          primary := cleanup_status;
        end if;
      end if;

      if Sonbal.Process_Admission.is_initialized(self.admission) and then
         Sonbal.Process_Admission.active_count(self.admission) = 0
      then
        cleanup_status := Sonbal.Process_Admission.finalize(self.admission);
        if primary = Clair.Status.OK and then
           cleanup_status /= Clair.Status.OK
        then
          primary := cleanup_status;
        end if;
      end if;

      if Sonbal.Workspace_Tokens.is_initialized (self.workspace_tokens) and then
         Sonbal.Workspace_Tokens.active_work_count (self.workspace_tokens) = 0
      then
        cleanup_status := Sonbal.Workspace_Tokens.finalize
          (self.workspace_tokens);
        if primary = Clair.Status.OK and then
           cleanup_status /= Clair.Status.OK
        then
          primary := cleanup_status;
        end if;
      end if;

      cleanup_status := close_executable_image (self);
      if primary = Clair.Status.OK and then cleanup_status /= Clair.Status.OK
      then
        primary := cleanup_status;
      end if;

      self.sync_capacity := 0;
      return
        (if primary = Clair.Status.OK
         then Clair.Status.INTERNAL_ERROR
         else primary);
  end initialize;

  function rotate_workspace_token
    (self         : in out Context;
     root         : String;
     operation_id : String;
     result       : out Sonbal.Workspace_Tokens.Rotation_Result)
  return Clair.Status.Code
  is
  begin
    result := (others => <>);
    if not self.initialized or else self.shutting_down then
      return Clair.Status.INVALID_STATE;
    end if;

    return Sonbal.Workspace_Tokens.rotate
      (self.workspace_tokens, root, operation_id, result);
  end rotate_workspace_token;


  function prepare_sync_record
    (self      : aliased in out Context;
     operation : aliased in out Sonbal.Process_Execution.Operation;
     handler   : Sonbal.Process_Execution.Completion_Handler_Access;
     state     : out Sonbal.Process_Execution.Workspace_Start_State;
     index     : out Natural)
  return Clair.Status.Code
  is
  begin
    state := Sonbal.Process_Execution.Workspace_Start_Failed;
    index := 0;

    if not self.initialized or else self.shutting_down then
      return Clair.Status.INVALID_STATE;
    elsif handler = null then
      return Clair.Status.INVALID_ARGUMENT;
    elsif operation_is_registered (self, operation'unchecked_access) then
      return Clair.Status.INVALID_STATE;
    end if;

    index := first_free_sync_record (self);
    if index = 0 then
      state := Sonbal.Process_Execution.Workspace_Start_Execution_Busy;
      return Clair.Status.OK;
    end if;

    self.sync_records(index).active := True;
    self.sync_records(index).cancelling := False;
    self.sync_records(index).completion_seen := False;
    self.sync_records(index).operation := operation'unchecked_access;
    self.sync_records(index).client := handler;
    return Clair.Status.OK;
  end prepare_sync_record;

  function finish_sync_start
    (self      : aliased in out Context;
     index     : Positive;
     operation : aliased in out Sonbal.Process_Execution.Operation;
     status_in : Clair.Status.Code;
     state     : in out Sonbal.Process_Execution.Workspace_Start_State)
  return Clair.Status.Code
  is
    status : Clair.Status.Code := status_in;
    retry_status : Clair.Status.Code;
  begin
    if Sonbal.Process_Execution.is_active (operation) then
      if status = Clair.Status.OK then
        return Clair.Status.OK;
      end if;

      for attempt in 1 .. MAXIMUM_CLEANUP_RETRIES loop
        retry_status := Sonbal.Process_Execution.retry (operation);
        if retry_status = Clair.Status.OK then
          state := Sonbal.Process_Execution.Workspace_Start_Running;
          return Clair.Status.OK;
        end if;
        status := retry_status;
      end loop;

      fail_closed (self);
      if not request_sync_cancellation (self.sync_records(index)) then
        return Clair.Status.INTERNAL_ERROR;
      end if;
      return status;
    elsif Sonbal.Process_Execution.has_runtime_resources (operation) then
      self.sync_records(index).client := null;
      fail_closed (self);
      return status;
    end if;

    clear_sync_record (self.sync_records(index));
    return status;
  end finish_sync_start;

  procedure recover_sync_start_exception
    (self      : aliased in out Context;
     index     : Natural;
     operation : aliased in out Sonbal.Process_Execution.Operation)
  is
  begin
    if index not in 1 .. self.sync_capacity or else
       self.sync_records(index).operation /= operation'unchecked_access
    then
      return;
    end if;

    if Sonbal.Process_Execution.is_active (operation) or else
       Sonbal.Process_Execution.has_runtime_resources (operation)
    then
      self.sync_records(index).client := null;
      fail_closed (self);
    else
      clear_sync_record (self.sync_records(index));
    end if;
  end recover_sync_start_exception;

  function start_synchronous
    (self       : aliased in out Context;
     operation  : aliased in out Sonbal.Process_Execution.Operation;
     workspace_token : String;
     argv       : Sonbal.Process_Arguments.Arguments;
     resolution : Clair.Process.Execution.Executable_Resolution;
     cwd        : String;
     timeout_ms : Natural;
     handler    : Sonbal.Process_Execution.Completion_Handler_Access;
     state      : out Sonbal.Process_Execution.Workspace_Start_State)
  return Clair.Status.Code
  is
    index : Natural := 0;
    status : Clair.Status.Code;
  begin
    status := prepare_sync_record
      (self, operation, handler, state, index);
    if status /= Clair.Status.OK or else index = 0 then
      return status;
    end if;

    status := Sonbal.Process_Execution.start_workspace
      (self             => operation,
       workspace_tokens => self.workspace_tokens,
       admission        => self.admission,
       workspace_token  => workspace_token,
       argv             => argv,
       resolution       => resolution,
       cwd              => cwd,
       timeout_ms       => timeout_ms,
       handler          => self.sync_records(index).bridge'unchecked_access,
       state            => state);

    return finish_sync_start
      (self, Positive(index), operation, status, state);
  exception
    when others =>
      recover_sync_start_exception (self, index, operation);
      state := Sonbal.Process_Execution.Workspace_Start_Failed;
      return Clair.Status.INTERNAL_ERROR;
  end start_synchronous;

  function start_file_read
    (self              : aliased in out Context;
     operation         : aliased in out Sonbal.Process_Execution.Operation;
     workspace_token   : String;
     path              : String;
     offset            : Clair.IO.File_Offset;
     maximum_bytes     : Positive;
     expected_revision : String;
     handler           : Sonbal.Process_Execution.Completion_Handler_Access;
     state             : out Sonbal.Process_Execution.Workspace_Start_State)
  return Clair.Status.Code
  is
    index : Natural := 0;
    status : Clair.Status.Code;
  begin
    status := prepare_sync_record
      (self, operation, handler, state, index);
    if status /= Clair.Status.OK or else index = 0 then
      return status;
    elsif self.executable_image = Clair.IO.INVALID_DESCRIPTOR then
      clear_sync_record (self.sync_records(index));
      return Clair.Status.INVALID_STATE;
    end if;

    status := Sonbal.Process_Execution.start_workspace_read
      (self                  => operation,
       workspace_tokens      => self.workspace_tokens,
       admission             => self.admission,
       executable_descriptor => self.executable_image,
       argument_zero         => Ada.Command_Line.Command_Name,
       workspace_token       => workspace_token,
       path                  => path,
       offset                => offset,
       maximum_bytes         => maximum_bytes,
       expected_revision     => expected_revision,
       handler               => self.sync_records(index).bridge'unchecked_access,
       state                 => state);

    return finish_sync_start
      (self, Positive(index), operation, status, state);
  exception
    when others =>
      recover_sync_start_exception (self, index, operation);
      state := Sonbal.Process_Execution.Workspace_Start_Failed;
      return Clair.Status.INTERNAL_ERROR;
  end start_file_read;

  procedure start_job
    (self       : aliased in out Context;
     workspace_token : String;
     argv       : Sonbal.Process_Arguments.Arguments;
     resolution : Clair.Process.Execution.Executable_Resolution;
     cwd        : String;
     timeout_ms : Natural;
     result     : out Sonbal.Process_Jobs.Start_Result)
  is
  begin
    result := (others => <>);
    if not self.initialized or else self.shutting_down then
      result.state := Sonbal.Process_Jobs.Start_Execution_Failed;
      return;
    end if;

    Sonbal.Process_Jobs.start
      (self.jobs,
       workspace_token,
       argv,
       resolution,
       cwd,
       timeout_ms,
       result);
  end start_job;

  procedure poll_job
    (self   : in out Context;
     job_id : String;
     cursor : String;
     result : out Sonbal.Process_Jobs.Poll_Result)
  is
  begin
    result := (others => <>);
    if not self.initialized then
      return;
    end if;
    Sonbal.Process_Jobs.poll(self.jobs, job_id, cursor, result);
  end poll_job;

  procedure cancel_job
    (self   : aliased in out Context;
     job_id : String;
     result : out Sonbal.Process_Jobs.Cancel_Result)
  is
  begin
    result := (others => <>);
    if not self.initialized then
      return;
    end if;
    Sonbal.Process_Jobs.cancel(self.jobs, job_id, result);
  end cancel_job;

  procedure mark_start_job_response_ready
    (self   : in out Context;
     result : Sonbal.Process_Jobs.Start_Result)
  is
  begin
    if self.initialized then
      Sonbal.Process_Jobs.mark_start_response_ready (self.jobs, result);
    end if;
  end mark_start_job_response_ready;

  procedure mark_poll_job_response_ready
    (self   : in out Context;
     result : Sonbal.Process_Jobs.Poll_Result)
  is
  begin
    if self.initialized then
      Sonbal.Process_Jobs.mark_poll_response_ready (self.jobs, result);
    end if;
  end mark_poll_job_response_ready;

  procedure mark_cancel_job_response_ready
    (self   : in out Context;
     result : Sonbal.Process_Jobs.Cancel_Result)
  is
  begin
    if self.initialized then
      Sonbal.Process_Jobs.mark_cancel_response_ready (self.jobs, result);
    end if;
  end mark_cancel_job_response_ready;

  function begin_shutdown
    (self : aliased in out Context) return Clair.Status.Code
  is
    job_status  : Clair.Status.Code := Clair.Status.OK;
    sync_status : Clair.Status.Code := Clair.Status.OK;
  begin
    if not self.initialized then
      return Clair.Status.INVALID_STATE;
    end if;

    self.shutting_down := True;
    Sonbal.Process_Admission.stop(self.admission);
    Sonbal.Workspace_Tokens.stop (self.workspace_tokens);

    if Sonbal.Process_Jobs.is_initialized(self.jobs) then
      job_status := Sonbal.Process_Jobs.begin_shutdown(self.jobs);
    end if;
    sync_status := cancel_all_synchronous(self);

    if job_status /= Clair.Status.OK or else sync_status /= Clair.Status.OK then
      return Clair.Status.INTERNAL_ERROR;
    end if;
    return Clair.Status.OK;
  exception
    when others =>
      fail_closed(self);
      return Clair.Status.INTERNAL_ERROR;
  end begin_shutdown;

  function is_initialized (self : Context) return Boolean is
    (self.initialized);

  function is_idle (self : Context) return Boolean is
  begin
    if not self.initialized then
      return False;
    end if;

    for index in 1 .. self.sync_capacity loop
      if self.sync_records(index).active then
        return False;
      end if;
    end loop;

    return Sonbal.Process_Jobs.is_initialized(self.jobs) and then
      Sonbal.Process_Jobs.is_idle(self.jobs) and then
      Sonbal.Process_Admission.active_count(self.admission) = 0 and then
      Sonbal.Workspace_Tokens.active_work_count (self.workspace_tokens) = 0;
  end is_idle;

  function active_execution_count (self : Context) return Natural is
  begin
    if not self.initialized or else
       not Sonbal.Process_Admission.is_initialized(self.admission)
    then
      return 0;
    end if;
    return Sonbal.Process_Admission.active_count(self.admission);
  end active_execution_count;

  function active_work_count (self : Context) return Natural is
  begin
    if not self.initialized or else
       not Sonbal.Workspace_Tokens.is_initialized (self.workspace_tokens)
    then
      return 0;
    end if;
    return Sonbal.Workspace_Tokens.active_work_count (self.workspace_tokens);
  end active_work_count;

  function workspace_token_count (self : Context) return Natural is
  begin
    if not self.initialized or else
       not Sonbal.Workspace_Tokens.is_initialized (self.workspace_tokens)
    then
      return 0;
    end if;
    return Sonbal.Workspace_Tokens.token_count (self.workspace_tokens);
  end workspace_token_count;

  function finalize
    (self : aliased in out Context) return Clair.Status.Code
  is
    status  : Clair.Status.Code;
    primary : Clair.Status.Code := Clair.Status.OK;
  begin
    if not self.initialized then
      return Clair.Status.INVALID_STATE;
    end if;

    for index in 1 .. self.sync_capacity loop
      if self.sync_records(index).active and then
         not retry_idle_resources(self.sync_records(index))
      then
        return Clair.Status.INVALID_STATE;
      end if;
    end loop;

    if Sonbal.Process_Admission.is_initialized(self.admission) and then
       Sonbal.Process_Admission.active_count(self.admission) /= 0
    then
      return Clair.Status.INVALID_STATE;
    elsif Sonbal.Workspace_Tokens.is_initialized (self.workspace_tokens) and then
          Sonbal.Workspace_Tokens.active_work_count (self.workspace_tokens) /= 0
    then
      return Clair.Status.INVALID_STATE;
    elsif Sonbal.Process_Jobs.is_initialized(self.jobs) and then
          not Sonbal.Process_Jobs.is_idle(self.jobs)
    then
      return Clair.Status.INVALID_STATE;
    end if;

    if Sonbal.Process_Jobs.is_initialized(self.jobs) then
      status := Sonbal.Process_Jobs.finalize(self.jobs);
      if primary = Clair.Status.OK and then status /= Clair.Status.OK then
        primary := status;
      end if;
    end if;

    if Sonbal.Process_Admission.is_initialized(self.admission) then
      status := Sonbal.Process_Admission.finalize(self.admission);
      if primary = Clair.Status.OK and then status /= Clair.Status.OK then
        primary := status;
      end if;
    end if;

    if Sonbal.Workspace_Tokens.is_initialized (self.workspace_tokens) then
      status := Sonbal.Workspace_Tokens.finalize (self.workspace_tokens);
      if primary = Clair.Status.OK and then status /= Clair.Status.OK then
        primary := status;
      end if;
    end if;

    status := close_executable_image (self);
    if primary = Clair.Status.OK and then status /= Clair.Status.OK then
      primary := status;
    end if;

    if primary /= Clair.Status.OK then
      return primary;
    end if;

    for index in 1 .. self.sync_capacity loop
      clear_sync_record(self.sync_records(index));
      self.sync_records(index).bridge.owner := null;
      self.sync_records(index).bridge.index := 0;
    end loop;
    self.sync_capacity := 0;
    self.initialized := False;
    self.shutting_down := False;
    return Clair.Status.OK;
  exception
    when others =>
      return Clair.Status.INTERNAL_ERROR;
  end finalize;

end Sonbal.Process_Runtime;
