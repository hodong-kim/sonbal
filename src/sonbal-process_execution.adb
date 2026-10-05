-- ============================================================================
-- sonbal-process_execution.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Ada.Real_Time;
with Clair.Process.Execution.POSIX;
with Sonbal.File_Read;
with System.Address_To_Access_Conversions;

package body Sonbal.Process_Execution is

  package Completion_Bridge_Conversions is new
    System.Address_To_Access_Conversions (Completion_Bridge);
  use type Completion_Bridge_Conversions.Object_Pointer;

  use type Clair.IO.Descriptor;
  use type Clair.Process.Execution.Event_Loop.Binding_Access;
  use type Clair.Status.Code;
  use type Sonbal.Process_Admission.Context_Access;
  use type Sonbal.Workspace_Tokens.Context_Access;

  MAXIMUM_ADDITIONAL_ARGUMENT_COUNT : constant Natural :=
    Sonbal.Process_Arguments.MAXIMUM_ARGUMENT_COUNT - 1;
  MAXIMUM_ARGUMENT_BYTES : constant Natural :=
    Sonbal.Process_Arguments.MAXIMUM_ARGV_BYTES;
  CHILD_PATH_KEY : constant String := "PATH";
  CHILD_PATH : constant String := "/usr/local/bin:/usr/bin:/bin";
  MAXIMUM_ENVIRONMENT_OPERATION_COUNT : constant Natural := 1;
  MAXIMUM_ENVIRONMENT_OPERATION_BYTES : constant Natural :=
    CHILD_PATH_KEY'length + CHILD_PATH'length;
  MAXIMUM_EFFECTIVE_ENVIRONMENT_BYTES : constant Natural :=
    MAXIMUM_ENVIRONMENT_OPERATION_BYTES + 2;
  MAXIMUM_TEXT_BYTES : constant Natural :=
    Sonbal.Process_Arguments.MAXIMUM_ARGUMENT_BYTES;
  MAXIMUM_CAPTURE_BYTES : constant Natural := 32_768;
  MAXIMUM_TIMEOUT_MS : constant Natural := MAXIMUM_OPERATION_TIMEOUT_MS;

  GRACEFUL_PERIOD : constant Ada.Real_Time.Time_Span :=
    Ada.Real_Time.Milliseconds (1_000);
  OUTPUT_DRAIN_TIMEOUT : constant Ada.Real_Time.Time_Span :=
    Ada.Real_Time.Milliseconds (1_000);

  function contains_nul (value : String) return Boolean is
  begin
    for item of value loop
      if item = Character'val (0) then
        return True;
      end if;
    end loop;

    return False;
  end contains_nul;

  function argv_is_valid
    (value : Sonbal.Process_Arguments.Arguments)
  return Boolean
  is
  begin
    return Sonbal.Process_Arguments.is_valid (value);
  end argv_is_valid;

  function cwd_is_valid (value : String) return Boolean is
  begin
    return value'length in
      1 .. Sonbal.Process_Arguments.MAXIMUM_WORKING_DIRECTORY_BYTES and then
      value(value'first) = '/' and then
      not contains_nul (value);
  end cwd_is_valid;

  function configure_common
    (argv       : Sonbal.Process_Arguments.Arguments;
     cwd        : String;
     timeout_ms : Natural;
     command    : in out Clair.Process.Execution.Command)
  return Clair.Status.Code
  is
    limits : Clair.Process.Execution.Resource_Limits :=
      Clair.Process.Execution.default_resource_limits;
    timeout : Clair.Process.Execution.Timeout_Policy;
    status : Clair.Status.Code;
  begin
    if not argv_is_valid (argv) or else
       not cwd_is_valid (cwd) or else
       timeout_ms not in 1 .. MAXIMUM_TIMEOUT_MS
    then
      return Clair.Status.INVALID_ARGUMENT;
    end if;

    limits.maximum_additional_argument_count :=
      MAXIMUM_ADDITIONAL_ARGUMENT_COUNT;
    limits.maximum_argument_bytes := MAXIMUM_ARGUMENT_BYTES;
    limits.maximum_environment_operation_count :=
      MAXIMUM_ENVIRONMENT_OPERATION_COUNT;
    limits.maximum_environment_operation_bytes :=
      MAXIMUM_ENVIRONMENT_OPERATION_BYTES;
    limits.maximum_effective_environment_bytes :=
      MAXIMUM_EFFECTIVE_ENVIRONMENT_BYTES;
    limits.maximum_text_bytes := MAXIMUM_TEXT_BYTES;
    limits.standard_output_capture_bytes := MAXIMUM_CAPTURE_BYTES;
    limits.standard_error_capture_bytes := MAXIMUM_CAPTURE_BYTES;

    status := Clair.Process.Execution.set_resource_limits (command, limits);
    if status /= Clair.Status.OK then
      return status;
    end if;

    for index in 2 .. Sonbal.Process_Arguments.count (argv) loop
      status := Clair.Process.Execution.add_argument
        (command, Sonbal.Process_Arguments.argument_at (argv, index));
      if status /= Clair.Status.OK then
        return status;
      end if;
    end loop;

    Clair.Process.Execution.set_environment_mode
      (command, Clair.Process.Execution.Empty_Environment);

    status := Clair.Process.Execution.set_environment_value
      (command, CHILD_PATH_KEY, CHILD_PATH);
    if status /= Clair.Status.OK then
      return status;
    end if;

    status := Clair.Process.Execution.set_working_directory (command, cwd);
    if status /= Clair.Status.OK then
      return status;
    end if;

    status := Clair.Process.Execution.set_standard_input_route
      (command, (kind => Clair.Process.Execution.Null_Input));
    if status /= Clair.Status.OK then
      return status;
    end if;

    status := Clair.Process.Execution.set_standard_output_route
      (command, (kind => Clair.Process.Execution.Capture_Output));
    if status /= Clair.Status.OK then
      return status;
    end if;

    status := Clair.Process.Execution.set_standard_error_route
      (command, (kind => Clair.Process.Execution.Capture_Output));
    if status /= Clair.Status.OK then
      return status;
    end if;

    Clair.Process.Execution.set_process_tree_ownership
      (command, Clair.Process.Execution.Strict_Ownership);

    timeout :=
      (mode            => Clair.Process.Execution.Timeout_Enabled,
       interval        => Ada.Real_Time.Milliseconds (timeout_ms),
       graceful_period => GRACEFUL_PERIOD,
       scope           => Clair.Process.Execution.Process_Tree);

    status := Clair.Process.Execution.set_timeout_policy (command, timeout);
    if status /= Clair.Status.OK then
      return status;
    end if;

    status := Clair.Process.Execution.set_output_drain_timeout
      (command, OUTPUT_DRAIN_TIMEOUT);
    if status /= Clair.Status.OK then
      return status;
    end if;

    return Clair.Status.OK;
  end configure_common;

  function configure_command
    (argv       : Sonbal.Process_Arguments.Arguments;
     resolution : Clair.Process.Execution.Executable_Resolution;
     cwd        : String;
     timeout_ms : Natural;
     command    : in out Clair.Process.Execution.Command)
  return Clair.Status.Code
  is
    status : Clair.Status.Code;
  begin
    if not argv_is_valid (argv) then
      return Clair.Status.INVALID_ARGUMENT;
    end if;

    status := Clair.Process.Execution.set_executable
      (self       => command,
       path       => Sonbal.Process_Arguments.argument_at (argv, 1),
       resolution => resolution);
    if status /= Clair.Status.OK then
      return status;
    end if;

    status := configure_common (argv, cwd, timeout_ms, command);
    if status /= Clair.Status.OK then
      return status;
    end if;

    return Clair.Process.Execution.validate (command);
  end configure_command;

  function configure_descriptor_command
    (argv                  : Sonbal.Process_Arguments.Arguments;
     executable_descriptor : Clair.IO.Descriptor;
     cwd                   : String;
     timeout_ms            : Natural;
     command               : in out Clair.Process.Execution.Command)
  return Clair.Status.Code
  is
    status : Clair.Status.Code;
  begin
    if not argv_is_valid (argv) or else
       executable_descriptor = Clair.IO.INVALID_DESCRIPTOR
    then
      return Clair.Status.INVALID_ARGUMENT;
    end if;

    status := Clair.Process.Execution.POSIX.set_executable_descriptor
      (command, executable_descriptor);
    if status /= Clair.Status.OK then
      return status;
    end if;

    status := Clair.Process.Execution.set_argument_zero
      (command, Sonbal.Process_Arguments.argument_at (argv, 1));
    if status /= Clair.Status.OK then
      return status;
    end if;

    status := configure_common (argv, cwd, timeout_ms, command);
    if status /= Clair.Status.OK then
      return status;
    end if;

    return Clair.Process.Execution.validate (command);
  end configure_descriptor_command;

  function is_initialized (self : Operation) return Boolean is
    (self.initialized);

  function is_active (self : Operation) return Boolean is
    (self.active);

  function has_runtime_resources (self : Operation) return Boolean is
    (self.admission_owned or else
     Sonbal.Workspace_Tokens.is_valid (self.work_ticket));

  function release_runtime_resources
    (self : aliased in out Operation)
  return Clair.Status.Code
  is
    workspace_tokens_ref : constant Sonbal.Workspace_Tokens.Context_Access :=
      self.workspace_tokens;
    admission_ref : constant Sonbal.Process_Admission.Context_Access :=
      self.admission;
    admission_status : Clair.Status.Code := Clair.Status.OK;
    workspace_token_status   : Clair.Status.Code := Clair.Status.OK;
  begin
    if self.admission_owned then
      if self.admission = null then
        admission_status := Clair.Status.INVALID_STATE;
      else
        admission_status :=
          Sonbal.Process_Admission.release (self.admission.all);
        if admission_status = Clair.Status.OK then
          self.admission_owned := False;
        end if;
      end if;
    end if;

    if Sonbal.Workspace_Tokens.is_valid (self.work_ticket) then
      if self.workspace_tokens = null then
        workspace_token_status := Clair.Status.INVALID_STATE;
      else
        workspace_token_status := Sonbal.Workspace_Tokens.end_work
          (self.workspace_tokens.all, self.work_ticket);
      end if;
    end if;

    if not self.admission_owned then
      self.admission := null;
    end if;
    if not Sonbal.Workspace_Tokens.is_valid (self.work_ticket) then
      self.workspace_tokens := null;
    end if;

    if admission_status /= Clair.Status.OK or else
       workspace_token_status /= Clair.Status.OK
    then
      if admission_ref /= null then
        Sonbal.Process_Admission.stop (admission_ref.all);
      end if;
      if workspace_tokens_ref /= null then
        Sonbal.Workspace_Tokens.stop (workspace_tokens_ref.all);
      end if;
      return
        (if admission_status /= Clair.Status.OK
         then admission_status
         else workspace_token_status);
    end if;

    return Clair.Status.OK;
  end release_runtime_resources;

  function settle_idle_resources
    (self : aliased in out Operation)
  return Clair.Status.Code
  is
  begin
    if not self.initialized or else self.active then
      return Clair.Status.INVALID_STATE;
    end if;

    return release_runtime_resources (self);
  end settle_idle_resources;

  type Observed_Stream is (Observed_Standard_Output, Observed_Standard_Error);

  function observe_stream
    (self      : Operation;
     stream    : Observed_Stream;
     offset    : Natural;
     buffer    : in out System.Storage_Elements.Storage_Array;
     length    : out Natural;
     copied    : out Natural;
     truncated : out Boolean)
  return Clair.Status.Code
  is
    observed_length    : Natural := 0;
    observed_copied    : Natural := 0;
    observed_truncated : Boolean := False;
    status             : Clair.Status.Code;
  begin
    length := 0;
    copied := 0;
    truncated := False;

    if not self.initialized or else not self.active then
      return Clair.Status.INVALID_STATE;
    end if;

    case stream is
      when Observed_Standard_Output =>
        status :=
          Clair.Process.Execution.Event_Loop.get_standard_output_length
            (self.binding, observed_length);
      when Observed_Standard_Error =>
        status := Clair.Process.Execution.Event_Loop.get_standard_error_length
          (self.binding, observed_length);
    end case;
    if status /= Clair.Status.OK then
      return status;
    end if;

    case stream is
      when Observed_Standard_Output =>
        status :=
          Clair.Process.Execution.Event_Loop.is_standard_output_truncated
            (self.binding, observed_truncated);
      when Observed_Standard_Error =>
        status :=
          Clair.Process.Execution.Event_Loop.is_standard_error_truncated
            (self.binding, observed_truncated);
    end case;
    if status /= Clair.Status.OK then
      return status;
    elsif offset > observed_length then
      return Clair.Status.INVALID_ARGUMENT;
    end if;

    case stream is
      when Observed_Standard_Output =>
        status := Clair.Process.Execution.Event_Loop.copy_standard_output
          (self.binding, offset, buffer, observed_copied);
      when Observed_Standard_Error =>
        status := Clair.Process.Execution.Event_Loop.copy_standard_error
          (self.binding, offset, buffer, observed_copied);
    end case;
    if status /= Clair.Status.OK then
      return status;
    end if;

    length := observed_length;
    copied := observed_copied;
    truncated := observed_truncated;
    return Clair.Status.OK;
  end observe_stream;

  function observe_standard_output
    (self      : Operation;
     offset    : Natural;
     buffer    : in out System.Storage_Elements.Storage_Array;
     length    : out Natural;
     copied    : out Natural;
     truncated : out Boolean)
  return Clair.Status.Code is
  begin
    return observe_stream
      (self,
       Observed_Standard_Output,
       offset,
       buffer,
       length,
       copied,
       truncated);
  end observe_standard_output;

  function observe_standard_error
    (self      : Operation;
     offset    : Natural;
     buffer    : in out System.Storage_Elements.Storage_Array;
     length    : out Natural;
     copied    : out Natural;
     truncated : out Boolean)
  return Clair.Status.Code is
  begin
    return observe_stream
      (self,
       Observed_Standard_Error,
       offset,
       buffer,
       length,
       copied,
       truncated);
  end observe_standard_error;

  function initialize
    (self         : aliased in out Operation;
     loop_context : aliased in out Clair.Event_Loop.Context)
  return Clair.Status.Code
  is
    status : Clair.Status.Code;
  begin
    if self.initialized then
      return Clair.Status.INVALID_STATE;
    end if;

    status := Clair.Process.Execution.Event_Loop.initialize
      (self.binding, loop_context);
    if status /= Clair.Status.OK then
      return status;
    end if;

    self.bridge.owner := self'unchecked_access;
    self.initialized := True;
    return Clair.Status.OK;
  end initialize;

  function finalize
    (self : aliased in out Operation)
  return Clair.Status.Code
  is
    status : Clair.Status.Code;
  begin
    if not self.initialized or else self.active then
      return Clair.Status.INVALID_STATE;
    end if;

    status := release_runtime_resources(self);
    if status /= Clair.Status.OK then
      return status;
    end if;

    status := Clair.Process.Execution.Event_Loop.finalize (self.binding);
    if status /= Clair.Status.OK then
      return status;
    end if;

    self.bridge.owner := null;
    self.client := null;
    self.cancelling := False;
    self.initialized := False;
    return Clair.Status.OK;
  end finalize;

  function start_configured
    (self    : aliased in out Operation;
     command : Clair.Process.Execution.Command;
     handler : Completion_Handler_Access)
  return Clair.Status.Code
  is
    status : Clair.Status.Code;
    retry_status : Clair.Status.Code;
  begin
    if not self.initialized or else self.active then
      return Clair.Status.INVALID_STATE;
    elsif handler = null then
      return Clair.Status.INVALID_ARGUMENT;
    end if;

    self.client := handler;
    self.active := True;
    self.cancelling := False;

    status := Clair.Process.Execution.Event_Loop.execute
      (self              => self.binding,
       execution_command => command,
       callback          => completion_callback'access,
       callback_context  => self.bridge'address);
    if status = Clair.Status.OK then
      return Clair.Status.OK;
    end if;

    retry_status := Clair.Process.Execution.Event_Loop.retry (self.binding);
    if retry_status = Clair.Status.OK then
      return Clair.Status.OK;
    elsif retry_status = Clair.Status.INVALID_STATE then
      self.active := False;
      self.cancelling := False;
      self.client := null;
      return status;
    end if;

    return retry_status;
  end start_configured;

  function start_core
    (self       : aliased in out Operation;
     argv       : Sonbal.Process_Arguments.Arguments;
     resolution : Clair.Process.Execution.Executable_Resolution;
     cwd        : String;
     timeout_ms : Natural;
     handler    : Completion_Handler_Access)
  return Clair.Status.Code
  is
    command : Clair.Process.Execution.Command :=
      Clair.Process.Execution.empty_command;
    status : Clair.Status.Code;
  begin
    status := configure_command
      (argv, resolution, cwd, timeout_ms, command);
    if status /= Clair.Status.OK then
      return status;
    end if;

    return start_configured (self, command, handler);
  end start_core;

  function start_descriptor_core
    (self                  : aliased in out Operation;
     argv                  : Sonbal.Process_Arguments.Arguments;
     executable_descriptor : Clair.IO.Descriptor;
     cwd                   : String;
     timeout_ms            : Natural;
     handler               : Completion_Handler_Access)
  return Clair.Status.Code
  is
    command : Clair.Process.Execution.Command :=
      Clair.Process.Execution.empty_command;
    status : Clair.Status.Code;
  begin
    status := configure_descriptor_command
      (argv,
       executable_descriptor,
       cwd,
       timeout_ms,
       command);
    if status /= Clair.Status.OK then
      return status;
    end if;

    return start_configured (self, command, handler);
  end start_descriptor_core;

  function start
    (self       : aliased in out Operation;
     argv       : Sonbal.Process_Arguments.Arguments;
     resolution : Clair.Process.Execution.Executable_Resolution;
     cwd        : String;
     timeout_ms : Natural;
     handler    : Completion_Handler_Access)
  return Clair.Status.Code
  is
  begin
    if has_runtime_resources(self) then
      return Clair.Status.INVALID_STATE;
    end if;

    return start_core
      (self, argv, resolution, cwd, timeout_ms, handler);
  end start;

  function adopt_workspace_work
    (self             : aliased in out Operation;
     workspace_tokens : aliased in out Sonbal.Workspace_Tokens.Context;
     work             : Sonbal.Workspace_Tokens.Work_Result;
     state            : out Workspace_Start_State;
     accepted         : out Boolean)
  return Clair.Status.Code
  is
  begin
    accepted := False;
    case work.state is
      when Sonbal.Workspace_Tokens.Work_Stale_Token =>
        state := Workspace_Start_Stale_Token;
      when Sonbal.Workspace_Tokens.Work_Outside_Workspace =>
        state := Workspace_Start_Outside_Workspace;
      when Sonbal.Workspace_Tokens.Work_Capacity_Exceeded =>
        state := Workspace_Start_Execution_Busy;
      when Sonbal.Workspace_Tokens.Work_Accepted =>
        self.workspace_tokens := workspace_tokens'unchecked_access;
        self.work_ticket := work.ticket;
        accepted := True;
    end case;
    return Clair.Status.OK;
  end adopt_workspace_work;

  function acquire_admission
    (self      : aliased in out Operation;
     admission : aliased in out Sonbal.Process_Admission.Context;
     state     : out Workspace_Start_State;
     acquired  : out Boolean)
  return Clair.Status.Code
  is
    cleanup_status : Clair.Status.Code;
    status : Clair.Status.Code;
  begin
    acquired := False;
    status := Sonbal.Process_Admission.try_acquire (admission, acquired);
    if status /= Clair.Status.OK then
      cleanup_status := release_runtime_resources (self);
      return
        (if cleanup_status = Clair.Status.OK then status else cleanup_status);
    elsif not acquired then
      cleanup_status := release_runtime_resources (self);
      if cleanup_status /= Clair.Status.OK then
        return cleanup_status;
      end if;
      state := Workspace_Start_Execution_Busy;
      return Clair.Status.OK;
    end if;

    self.admission := admission'unchecked_access;
    self.admission_owned := True;
    return Clair.Status.OK;
  end acquire_admission;

  function start_workspace
    (self              : aliased in out Operation;
     workspace_tokens  : aliased in out Sonbal.Workspace_Tokens.Context;
     admission         : aliased in out Sonbal.Process_Admission.Context;
     workspace_token   : String;
     argv              : Sonbal.Process_Arguments.Arguments;
     resolution        : Clair.Process.Execution.Executable_Resolution;
     cwd               : String;
     timeout_ms        : Natural;
     handler           : Completion_Handler_Access;
     state             : out Workspace_Start_State)
  return Clair.Status.Code
  is
    work : Sonbal.Workspace_Tokens.Work_Result;
    work_accepted : Boolean := False;
    admission_acquired : Boolean := False;
    status : Clair.Status.Code;
    cleanup_status : Clair.Status.Code;
  begin
    state := Workspace_Start_Failed;
    if not self.initialized or else self.active or else
       has_runtime_resources (self)
    then
      return Clair.Status.INVALID_STATE;
    elsif handler = null then
      return Clair.Status.INVALID_ARGUMENT;
    end if;

    status := Sonbal.Workspace_Tokens.begin_process_work
      (workspace_tokens, workspace_token, cwd, work);
    if status /= Clair.Status.OK then
      return status;
    end if;

    status := adopt_workspace_work
      (self, workspace_tokens, work, state, work_accepted);
    if status /= Clair.Status.OK or else not work_accepted then
      return status;
    end if;

    status := acquire_admission
      (self, admission, state, admission_acquired);
    if status /= Clair.Status.OK or else not admission_acquired then
      return status;
    end if;

    status := start_core
      (self,
       argv,
       resolution,
       Sonbal.Workspace_Tokens.image (work.working_directory),
       timeout_ms,
       handler);
    if status = Clair.Status.OK and then self.active then
      state := Workspace_Start_Running;
      return Clair.Status.OK;
    elsif self.active then
      return status;
    end if;

    cleanup_status := release_runtime_resources (self);
    return
      (if cleanup_status = Clair.Status.OK then status else cleanup_status);
  exception
    when others =>
      if self.initialized and then
         not self.active and then
         has_runtime_resources (self)
      then
        cleanup_status := release_runtime_resources (self);
        if cleanup_status /= Clair.Status.OK then
          state := Workspace_Start_Failed;
          return cleanup_status;
        end if;
      end if;
      state := Workspace_Start_Failed;
      return Clair.Status.INTERNAL_ERROR;
  end start_workspace;

  function start_workspace_read
    (self                  : aliased in out Operation;
     workspace_tokens      : aliased in out Sonbal.Workspace_Tokens.Context;
     admission             : aliased in out Sonbal.Process_Admission.Context;
     executable_descriptor : Clair.IO.Descriptor;
     argument_zero         : String;
     workspace_token       : String;
     path                  : String;
     offset                : Clair.IO.File_Offset;
     maximum_bytes         : Positive;
     expected_revision     : String;
     handler               : Completion_Handler_Access;
     state                 : out Workspace_Start_State)
  return Clair.Status.Code
  is
    work : Sonbal.Workspace_Tokens.Work_Result;
    arguments : Sonbal.Process_Arguments.Arguments;
    work_accepted : Boolean := False;
    admission_acquired : Boolean := False;
    status : Clair.Status.Code;
    cleanup_status : Clair.Status.Code;
  begin
    state := Workspace_Start_Failed;
    if not self.initialized or else self.active or else
       has_runtime_resources (self)
    then
      return Clair.Status.INVALID_STATE;
    elsif handler = null or else
          executable_descriptor = Clair.IO.INVALID_DESCRIPTOR
    then
      return Clair.Status.INVALID_ARGUMENT;
    end if;

    status := Sonbal.Workspace_Tokens.begin_current_work
      (workspace_tokens, workspace_token, work);
    if status /= Clair.Status.OK then
      return status;
    end if;

    status := adopt_workspace_work
      (self, workspace_tokens, work, state, work_accepted);
    if status /= Clair.Status.OK or else not work_accepted then
      return status;
    end if;

    status := Sonbal.File_Read.build_helper_arguments
      (argument_zero      => argument_zero,
       workspace_root     => Sonbal.Workspace_Tokens.image(work.workspace_root),
       root_filesystem_id => work.workspace_identity.filesystem_id,
       root_object_id     => work.workspace_identity.object_id,
       path               => path,
       offset             => offset,
       maximum_bytes      => maximum_bytes,
       expected_revision  => expected_revision,
       arguments          => arguments);
    if status /= Clair.Status.OK then
      cleanup_status := release_runtime_resources (self);
      return
        (if cleanup_status = Clair.Status.OK then status else cleanup_status);
    end if;

    status := acquire_admission
      (self, admission, state, admission_acquired);
    if status /= Clair.Status.OK or else not admission_acquired then
      return status;
    end if;

    status := start_descriptor_core
      (self,
       arguments,
       executable_descriptor,
       "/",
       Sonbal.File_Read.HELPER_TIMEOUT_MS,
       handler);
    if status = Clair.Status.OK and then self.active then
      state := Workspace_Start_Running;
      return Clair.Status.OK;
    elsif self.active then
      return status;
    end if;

    cleanup_status := release_runtime_resources (self);
    return
      (if cleanup_status = Clair.Status.OK then status else cleanup_status);
  exception
    when others =>
      if self.initialized and then
         not self.active and then
         has_runtime_resources (self)
      then
        cleanup_status := release_runtime_resources (self);
        if cleanup_status /= Clair.Status.OK then
          state := Workspace_Start_Failed;
          return cleanup_status;
        end if;
      end if;
      state := Workspace_Start_Failed;
      return Clair.Status.INTERNAL_ERROR;
  end start_workspace_read;

  function retry
    (self : aliased in out Operation)
  return Clair.Status.Code
  is
  begin
    if not self.initialized or else not self.active then
      return Clair.Status.INVALID_STATE;
    end if;

    return Clair.Process.Execution.Event_Loop.retry (self.binding);
  end retry;

  function cancel
    (self : aliased in out Operation)
  return Clair.Status.Code
  is
    status : Clair.Status.Code;
  begin
    if not self.initialized or else not self.active then
      return Clair.Status.INVALID_STATE;
    elsif self.cancelling then
      status := Clair.Process.Execution.Event_Loop.retry(self.binding);
      if status in Clair.Status.OK | Clair.Status.INVALID_STATE then
        return Clair.Status.OK;
      end if;
      return status;
    end if;

    status := Clair.Process.Execution.Event_Loop.cancel
      (self            => self.binding,
       graceful_period => GRACEFUL_PERIOD,
       scope           => Clair.Process.Execution.Process_Tree);
    if status = Clair.Status.OK then
      self.cancelling := True;
    end if;
    return status;
  end cancel;

  function completion_callback
    (process_binding : not null
       Clair.Process.Execution.Event_Loop.Binding_Access;
     cause           : Clair.Process.Execution.Event_Loop.Operation_Cause;
     status          : Clair.Status.Code;
     outcome         : Clair.Process.Execution.Result;
     context         : System.Address)
  return Clair.Status.Code
  is
    handler : constant Completion_Bridge_Conversions.Object_Pointer :=
      Completion_Bridge_Conversions.To_Pointer (context);
    callback         : Completion_Handler_Access;
    resource_status  : Clair.Status.Code;
    effective_status : Clair.Status.Code := status;
    retval           : Clair.Status.Code;
  begin
    if handler = null or else handler.owner = null then
      return Clair.Status.INTERNAL_ERROR;
    elsif process_binding /= handler.owner.binding'unchecked_access or else
          not handler.owner.initialized or else
          not handler.owner.active or else
          handler.owner.client = null
    then
      handler.owner.active := False;
      handler.owner.cancelling := False;
      handler.owner.client := null;
      return Clair.Status.INTERNAL_ERROR;
    end if;

    callback := handler.owner.client;
    resource_status := release_runtime_resources (handler.owner.all);
    if resource_status /= Clair.Status.OK then
      effective_status := resource_status;
    end if;

    begin
      retval := on_complete
        (handler   => callback.all,
         operation => handler.owner,
         cause     => cause,
         status    => effective_status,
         outcome   => outcome);
    exception
      when others =>
        handler.owner.active := False;
        handler.owner.cancelling := False;
        handler.owner.client := null;
        raise;
    end;

    handler.owner.active := False;
    handler.owner.cancelling := False;
    handler.owner.client := null;
    return retval;
  end completion_callback;

end Sonbal.Process_Execution;
