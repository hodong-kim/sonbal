-- ============================================================================
-- sonbal-connector_server.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Ada.Unchecked_Deallocation;
with Interfaces;
with System;

package body Sonbal.Connector_Server is

  use type Clair.Process.Execution.Event_Loop.Operation_Cause;
  use type Clair.Status.Code;
  use type Interfaces.Unsigned_32;
  use type Sonbal.Connector_ABI.Event_Kind;
  use type Sonbal.Connector_ABI.Request_Token;
  use type Sonbal.Connector_Host.Completion_State;
  use type Sonbal.Connector_Host.Event_Poll_State;
  use type Sonbal.MCP.Dispatcher.Action_Kind;
  use type Sonbal.Process_Execution.Operation_Access;

  MAXIMUM_PROGRESS_EVENTS : constant Positive := 16;
  MAXIMUM_CLEANUP_RETRIES : constant Positive := 8;

  procedure free_request_slots is new Ada.Unchecked_Deallocation
    (Request_Slot_Array, Request_Slot_Array_Access);

  procedure mark_failure
    (self  : in out Context;
     value : Server_Failure)
  is
  begin
    if self.failure = No_Failure then
      self.failure := value;
    end if;
  end mark_failure;

  procedure clear_slot (slot : in out Request_Slot) is
  begin
    slot.state := Slot_Free;
    slot.token := Sonbal.Connector_ABI.NO_REQUEST_TOKEN;
  end clear_slot;

  function first_free_slot (self : Context) return Natural is
  begin
    if self.slots = null then
      return 0;
    end if;

    for index in 1 .. self.request_slot_count loop
      if self.slots(index).state = Slot_Free then
        return index;
      end if;
    end loop;
    return 0;
  end first_free_slot;

  function find_token
    (self  : Context;
     token : Sonbal.Connector_ABI.Request_Token)
  return Natural
  is
  begin
    if self.slots = null or else
       token = Sonbal.Connector_ABI.NO_REQUEST_TOKEN
    then
      return 0;
    end if;

    for index in 1 .. self.request_slot_count loop
      if self.slots(index).state /= Slot_Free and then
         self.slots(index).token = token
      then
        return index;
      end if;
    end loop;
    return 0;
  end find_token;

  function find_process_slot
    (self      : Context;
     operation : not null Sonbal.Process_Execution.Operation_Access)
  return Natural
  is
  begin
    if self.slots = null then
      return 0;
    end if;

    for index in 1 .. self.request_slot_count loop
      if operation = self.slots(index).process'unchecked_access then
        return index;
      end if;
    end loop;
    return 0;
  end find_process_slot;

  function all_slots_free (self : Context) return Boolean is
  begin
    if self.slots = null then
      return True;
    end if;

    for index in 1 .. self.request_slot_count loop
      if self.slots(index).state /= Slot_Free then
        return False;
      end if;
    end loop;
    return True;
  end all_slots_free;

  function request_cancellation
    (slot : in out Request_Slot)
  return Clair.Status.Code
  is
    status : Clair.Status.Code;
  begin
    if not Sonbal.Process_Execution.is_active (slot.process) then
      return Clair.Status.OK;
    end if;

    for attempt in 1 .. MAXIMUM_CLEANUP_RETRIES loop
      status := Sonbal.Process_Execution.cancel (slot.process);
      if status = Clair.Status.OK then
        return Clair.Status.OK;
      elsif status = Clair.Status.INVALID_STATE then
        status := Sonbal.Process_Execution.retry (slot.process);
        if status in Clair.Status.OK | Clair.Status.INVALID_STATE then
          return Clair.Status.OK;
        end if;
      else
        status := Sonbal.Process_Execution.retry (slot.process);
        if status = Clair.Status.OK then
          return Clair.Status.OK;
        elsif status = Clair.Status.INVALID_STATE and then
              not Sonbal.Process_Execution.is_active (slot.process)
        then
          return Clair.Status.OK;
        end if;
      end if;
    end loop;

    return Clair.Status.CALLBACK_FAILED;
  exception
    when others =>
      return Clair.Status.INTERNAL_ERROR;
  end request_cancellation;

  function finalize_process_slots
    (self : in out Context)
  return Clair.Status.Code
  is
    status : Clair.Status.Code;
  begin
    if self.slots = null then
      return Clair.Status.OK;
    end if;

    for index in 1 .. self.request_slot_count loop
      if Sonbal.Process_Execution.is_active (self.slots(index).process) then
        return Clair.Status.INVALID_STATE;
      end if;

      if Sonbal.Process_Execution.is_initialized (self.slots(index).process)
      then
        status := Clair.Status.INVALID_STATE;
        for attempt in 1 .. MAXIMUM_CLEANUP_RETRIES loop
          status := Sonbal.Process_Execution.finalize
            (self.slots(index).process);
          exit when status = Clair.Status.OK;
        end loop;
        if status /= Clair.Status.OK then
          return status;
        end if;
      end if;
    end loop;

    return Clair.Status.OK;
  end finalize_process_slots;

  function rollback_local_initialization
    (self : in out Context)
  return Clair.Status.Code
  is
    status : Clair.Status.Code := Clair.Status.OK;
    item_status : Clair.Status.Code;
  begin
    item_status := finalize_process_slots (self);
    if item_status /= Clair.Status.OK then
      status := item_status;
    end if;

    if Sonbal.MCP.Request_Core.is_initialized (self.core) then
      item_status := Sonbal.MCP.Request_Core.finalize (self.core);
      if item_status /= Clair.Status.OK and then status = Clair.Status.OK then
        status := item_status;
      end if;
    end if;

    if status = Clair.Status.OK and then self.slots /= null then
      free_request_slots (self.slots);
    end if;

    if status = Clair.Status.OK then
      self.event_loop := null;
      self.progress_handler.owner := null;
      self.process_handler.owner := null;
    end if;

    return status;
  exception
    when others =>
      return Clair.Status.INTERNAL_ERROR;
  end rollback_local_initialization;

  function prepare_response
    (self  : in out Context;
     slot  : in out Request_Slot;
     count : out Natural)
  return Clair.Status.Code
  is
    copied : Natural := 0;
  begin
    count := 0;

    if slot.result.action = Sonbal.MCP.Dispatcher.No_Action then
      return Clair.Status.OK;
    elsif slot.result.action /= Sonbal.MCP.Dispatcher.Write_Response then
      return Clair.Status.INVALID_STATE;
    end if;

    count := Sonbal.MCP.Dispatcher.Length (slot.result.response);
    if count = 0 or else count > self.response_buffer'length then
      count := 0;
      return Clair.Status.CONTRACT_VIOLATION;
    end if;

    Sonbal.MCP.Dispatcher.Copy_Response
      (Value  => slot.result.response,
       Offset => 0,
       Target => self.response_buffer(1 .. count),
       Copied => copied);

    if copied /= count then
      self.response_buffer(1 .. count) := [others => Character'Val (0)];
      count := 0;
      return Clair.Status.CONTRACT_VIOLATION;
    end if;

    return Clair.Status.OK;
  exception
    when others =>
      if count > 0 then
        self.response_buffer(1 .. count) := [others => Character'Val (0)];
      end if;
      count := 0;
      return Clair.Status.INTERNAL_ERROR;
  end prepare_response;

  function flush_slot
    (self  : in out Context;
     index : Positive)
  return Clair.Status.Code
  is
    slot : Request_Slot renames self.slots(index);
    response_length : Natural := 0;
    status : Clair.Status.Code;
    completion : Sonbal.Connector_Host.Completion_State;
    response_address : System.Address := System.NULL_ADDRESS;
  begin
    if slot.state /= Slot_Ready then
      return Clair.Status.OK;
    end if;

    status := prepare_response (self, slot, response_length);
    if status /= Clair.Status.OK then
      mark_failure (self, Dispatcher_Failure);
      return status;
    end if;

    if response_length > 0 then
      response_address := self.response_buffer(1)'address;
    end if;

    status := Sonbal.Connector_Host.complete_request
      (self            => self.host,
       token           => slot.token,
       response        => response_address,
       response_length => response_length,
       state           => completion);

    if response_length > 0 then
      self.response_buffer(1 .. response_length) :=
        [others => Character'Val (0)];
    end if;

    if status /= Clair.Status.OK then
      mark_failure (self, Connector_Failure);
      return status;
    elsif completion = Sonbal.Connector_Host.Completion_Would_Block then
      return Clair.Status.OK;
    elsif completion /= Sonbal.Connector_Host.Completion_Accepted then
      mark_failure (self, Connector_Contract_Failure);
      return Clair.Status.CONTRACT_VIOLATION;
    end if;

    if slot.result.action = Sonbal.MCP.Dispatcher.Write_Response then
      Sonbal.MCP.Request_Core.mark_transport_response_handoff
        (self.core, slot.result);
    end if;

    clear_slot (slot);
    return Clair.Status.OK;
  exception
    when others =>
      if response_length > 0 then
        self.response_buffer(1 .. response_length) :=
          [others => Character'Val (0)];
      end if;
      mark_failure (self, Internal_Failure);
      return Clair.Status.INTERNAL_ERROR;
  end flush_slot;

  function flush_ready_slots
    (self : in out Context)
  return Clair.Status.Code
  is
    status : Clair.Status.Code;
  begin
    if self.slots = null then
      return Clair.Status.INVALID_STATE;
    end if;

    for index in 1 .. self.request_slot_count loop
      if self.slots(index).state = Slot_Ready then
        status := flush_slot (self, index);
        if status /= Clair.Status.OK then
          return status;
        end if;
      end if;
    end loop;

    return Clair.Status.OK;
  end flush_ready_slots;

  function handle_request_event
    (self : in out Context;
     item : Sonbal.Connector_ABI.Event)
  return Clair.Status.Code
  is
    index : Natural;
    processed : Boolean;
    request_length : constant Natural := Natural(item.request_length);
  begin
    if self.stopping or else
       find_token (self, item.token) /= 0
    then
      mark_failure (self, Connector_Contract_Failure);
      return Clair.Status.CONTRACT_VIOLATION;
    end if;

    index := first_free_slot (self);
    if index = 0 then
      mark_failure (self, Connector_Contract_Failure);
      return Clair.Status.CONTRACT_VIOLATION;
    end if;

    declare
      slot : Request_Slot renames self.slots(index);
    begin
      slot.token := item.token;

      if request_length = 0 then
        Sonbal.MCP.Request_Core.handle (self.core, "", slot.result);
      else
        Sonbal.MCP.Request_Core.handle
          (self.core,
           self.request_buffer(1 .. request_length),
           slot.result);
      end if;

      if slot.result.action in
        Sonbal.MCP.Dispatcher.Invoke_Run_Process |
        Sonbal.MCP.Dispatcher.Invoke_Read_File
      then
        slot.state := Slot_Unresolved;
      end if;

      processed := Sonbal.MCP.Request_Core.process_result
        (self            => self.core,
         result          => slot.result,
         process         => slot.process,
         process_handler => self.process_handler'unchecked_access);

      if not processed then
        if Sonbal.Process_Execution.is_active (slot.process) then
          slot.state := Slot_Unresolved;
        else
          clear_slot (slot);
        end if;
        mark_failure (self, Runtime_Failure);
        return Clair.Status.INTERNAL_ERROR;
      elsif Sonbal.Process_Execution.is_active (slot.process) then
        slot.state := Slot_Unresolved;
        return Clair.Status.OK;
      elsif slot.result.action in
        Sonbal.MCP.Dispatcher.No_Action |
        Sonbal.MCP.Dispatcher.Write_Response
      then
        slot.state := Slot_Ready;
        return flush_slot (self, Positive(index));
      end if;

      mark_failure (self, Dispatcher_Failure);
      return Clair.Status.CONTRACT_VIOLATION;
    end;
  exception
    when others =>
      mark_failure (self, Internal_Failure);
      return Clair.Status.INTERNAL_ERROR;
  end handle_request_event;

  function handle_abandoned_event
    (self : in out Context;
     item : Sonbal.Connector_ABI.Event)
  return Clair.Status.Code
  is
    index : constant Natural := find_token (self, item.token);
    status : Clair.Status.Code;
  begin
    if index = 0 then
      mark_failure (self, Connector_Contract_Failure);
      return Clair.Status.CONTRACT_VIOLATION;
    end if;

    declare
      slot : Request_Slot renames self.slots(index);
    begin
      case slot.state is
        when Slot_Ready =>
          if slot.result.action = Sonbal.MCP.Dispatcher.Write_Response then
            Sonbal.MCP.Request_Core.mark_transport_response_abandoned
              (self.core, slot.result);
          end if;
          clear_slot (slot);
          return Clair.Status.OK;

        when Slot_Unresolved =>
          if not Sonbal.Process_Execution.is_active (slot.process) then
            mark_failure (self, Process_Binding_Failure);
            return Clair.Status.CONTRACT_VIOLATION;
          end if;

          status := request_cancellation (slot);
          if status /= Clair.Status.OK then
            mark_failure (self, Process_Cancellation_Failure);
            return status;
          end if;

          slot.state := Slot_Abandoned_Unresolved;
          return Clair.Status.OK;

        when Slot_Abandoned_Unresolved | Slot_Free =>
          mark_failure (self, Connector_Contract_Failure);
          return Clair.Status.CONTRACT_VIOLATION;
      end case;
    end;
  exception
    when others =>
      mark_failure (self, Internal_Failure);
      return Clair.Status.INTERNAL_ERROR;
  end handle_abandoned_event;

  function process_connector_event
    (self : in out Context;
     item : Sonbal.Connector_ABI.Event)
  return Clair.Status.Code
  is
  begin
    case item.kind is
      when Sonbal.Connector_ABI.EVENT_REQUEST =>
        return handle_request_event (self, item);

      when Sonbal.Connector_ABI.EVENT_REQUEST_ABANDONED =>
        return handle_abandoned_event (self, item);

      when Sonbal.Connector_ABI.EVENT_FATAL =>
        mark_failure (self, Connector_Failure);
        return Clair.Status.OK;

      when Sonbal.Connector_ABI.EVENT_SHUTDOWN_COMPLETE =>
        if not self.stopping or else
           not all_slots_free (self)
        then
          mark_failure (self, Connector_Contract_Failure);
          return Clair.Status.CONTRACT_VIOLATION;
        end if;
        return Clair.Status.OK;

      when Sonbal.Connector_ABI.EVENT_NONE =>
        mark_failure (self, Connector_Contract_Failure);
        return Clair.Status.CONTRACT_VIOLATION;

      when others =>
        mark_failure (self, Connector_Contract_Failure);
        return Clair.Status.CONTRACT_VIOLATION;
    end case;
  end process_connector_event;

  function advance_shutdown
    (self : in out Context)
  return Clair.Status.Code
  is
    status : Clair.Status.Code := Clair.Status.OK;
    item_status : Clair.Status.Code;
  begin
    if not self.stopping then
      return Clair.Status.INVALID_STATE;
    end if;

    for index in 1 .. self.request_slot_count loop
      if self.slots(index).state in
        Slot_Unresolved | Slot_Abandoned_Unresolved
      then
        if not Sonbal.Process_Execution.is_active (self.slots(index).process)
        then
          mark_failure (self, Process_Binding_Failure);
          return Clair.Status.CONTRACT_VIOLATION;
        end if;

        item_status := request_cancellation (self.slots(index));
        if item_status /= Clair.Status.OK then
          mark_failure (self, Process_Cancellation_Failure);
          if status = Clair.Status.OK then
            status := item_status;
          end if;
        end if;

      end if;
    end loop;

    if all_slots_free (self) and then not self.core_stopping then
      if Sonbal.MCP.Request_Core.stop (self.core) then
        self.core_stopping := True;
      else
        mark_failure (self, Runtime_Failure);
        if status = Clair.Status.OK then
          status := Clair.Status.INTERNAL_ERROR;
        end if;
      end if;
    end if;

    return status;
  exception
    when others =>
      mark_failure (self, Internal_Failure);
      return Clair.Status.INTERNAL_ERROR;
  end advance_shutdown;


  overriding function on_connector_progress
    (handler : in out Progress_Bridge)
  return Clair.Status.Code
  is
    item : aliased Sonbal.Connector_ABI.Event;
    poll_state : Sonbal.Connector_Host.Event_Poll_State;
    status : Clair.Status.Code;
  begin
    if handler.owner = null then
      return Clair.Status.INTERNAL_ERROR;
    end if;

    declare
      self : Context renames handler.owner.all;
    begin
      if self.stopping then
        status := advance_shutdown (self);
        if status /= Clair.Status.OK then
          return status;
        end if;
      end if;

      for ignored in 1 .. MAXIMUM_PROGRESS_EVENTS loop
        item :=
          (token                 => Sonbal.Connector_ABI.NO_REQUEST_TOKEN,
           kind                  => Sonbal.Connector_ABI.EVENT_NONE,
           request_length        => 0,
           correlation_length    => 0,
           correlation_truncated => 0);

        status := Sonbal.Connector_Host.next_event
          (self                 => self.host,
           request_buffer       => self.request_buffer(1)'address,
           request_capacity     => self.request_buffer'length,
           correlation_buffer   => self.correlation_buffer(1)'address,
           correlation_capacity => self.correlation_buffer'length,
           item                 => item,
           state                => poll_state);

        if status /= Clair.Status.OK then
          mark_failure (self, Connector_Failure);
          return status;
        elsif poll_state = Sonbal.Connector_Host.Event_Would_Block then
          status := flush_ready_slots (self);
          if status /= Clair.Status.OK then
            return status;
          elsif self.stopping then
            return advance_shutdown (self);
          end if;
          return Clair.Status.OK;
        elsif poll_state /= Sonbal.Connector_Host.Event_Ready then
          mark_failure (self, Connector_Contract_Failure);
          return Clair.Status.CONTRACT_VIOLATION;
        end if;

        status := process_connector_event (self, item);

        if item.request_length > 0 and then
           Natural(item.request_length) <= self.request_buffer'length
        then
          self.request_buffer(1 .. Natural(item.request_length)) :=
            [others => Character'Val (0)];
        end if;
        if item.correlation_length > 0 and then
           Natural(item.correlation_length) <= self.correlation_buffer'length
        then
          self.correlation_buffer(1 .. Natural(item.correlation_length)) :=
            [others => Character'Val (0)];
        end if;

        if status /= Clair.Status.OK then
          return status;
        elsif item.kind = Sonbal.Connector_ABI.EVENT_SHUTDOWN_COMPLETE then
          return Clair.Status.OK;
        elsif self.stopping then
          status := advance_shutdown (self);
          if status /= Clair.Status.OK then
            return status;
          end if;
        end if;
      end loop;

      return Clair.Status.OK;
    end;
  exception
    when others =>
      if handler.owner /= null then
        mark_failure (handler.owner.all, Internal_Failure);
      end if;
      return Clair.Status.INTERNAL_ERROR;
  end on_connector_progress;

  overriding function on_complete
    (handler   : in out Process_Completion_Bridge;
     operation : not null Sonbal.Process_Execution.Operation_Access;
     cause     : Clair.Process.Execution.Event_Loop.Operation_Cause;
     status    : Clair.Status.Code;
     outcome   : Clair.Process.Execution.Result)
  return Clair.Status.Code
  is
    index : Natural;
    flush_status : Clair.Status.Code;
  begin
    if handler.owner = null then
      return Clair.Status.INTERNAL_ERROR;
    end if;

    declare
      self : Context renames handler.owner.all;
    begin
      index := find_process_slot (self, operation);
      if index = 0 then
        mark_failure (self, Process_Binding_Failure);
        return Clair.Status.OK;
      end if;

      declare
        slot : Request_Slot renames self.slots(index);
        abandoned : constant Boolean :=
          slot.state = Slot_Abandoned_Unresolved;
      begin
        if slot.state not in Slot_Unresolved | Slot_Abandoned_Unresolved then
          mark_failure (self, Process_Binding_Failure);
          return Clair.Status.OK;
        elsif cause =
          Clair.Process.Execution.Event_Loop.Caller_Cancellation and then
          not abandoned and then
          not self.stopping
        then
          mark_failure (self, Process_Binding_Failure);
          return Clair.Status.OK;
        end if;

        Sonbal.MCP.Request_Core.complete_request_execution
          (self.core, slot.result, status, outcome);

        if abandoned then
          Sonbal.MCP.Request_Core.mark_transport_response_abandoned
            (self.core, slot.result);
          clear_slot (slot);
          return Clair.Status.OK;
        end if;

        if slot.result.action /= Sonbal.MCP.Dispatcher.Write_Response then
          clear_slot (slot);
          mark_failure (self, Dispatcher_Failure);
          return Clair.Status.OK;
        end if;

        slot.state := Slot_Ready;
        flush_status := flush_slot (self, Positive(index));
        if flush_status /= Clair.Status.OK then
          mark_failure (self, Connector_Failure);
        end if;
      end;
    end;

    return Clair.Status.OK;
  exception
    when others =>
      if handler.owner /= null then
        mark_failure (handler.owner.all, Internal_Failure);
      end if;
      return Clair.Status.OK;
  end on_complete;

  function initialize
    (self             : aliased in out Context;
     event_loop       : aliased in out Clair.Event_Loop.Context;
     plugin_path      : String;
     configuration_fd : in out Clair.IO.Descriptor;
     credential_fd    : in out Clair.IO.Descriptor;
     max_work_slots   : Sonbal.Configuration.Work_Slot_Count)
  return Clair.Status.Code
  is
    status : Clair.Status.Code;
    initialized_slots : Natural := 0;
  begin
    if self.initialized or else self.slots /= null then
      return Clair.Status.INVALID_STATE;
    end if;

    self.event_loop := event_loop'unchecked_access;
    self.request_slot_count := Positive(max_work_slots) + 1;

    begin
      self.slots := new Request_Slot_Array (1 .. self.request_slot_count);
    exception
      when Storage_Error =>
        self.event_loop := null;
        return Clair.Status.OUT_OF_MEMORY;
    end;

    self.progress_handler.owner := self'unchecked_access;
    self.process_handler.owner := self'unchecked_access;

    status := Sonbal.MCP.Request_Core.initialize
      (self           => self.core,
       event_loop     => event_loop,
       max_work_slots => max_work_slots);
    if status /= Clair.Status.OK then
      declare
        cleanup_status : constant Clair.Status.Code :=
          rollback_local_initialization (self);
      begin
        return
          (if cleanup_status = Clair.Status.OK then status else cleanup_status);
      end;
    end if;

    for index in 1 .. self.request_slot_count loop
      status := Sonbal.Process_Execution.initialize
        (self.slots(index).process, event_loop);
      exit when status /= Clair.Status.OK;
      initialized_slots := index;
    end loop;

    if initialized_slots /= self.request_slot_count then
      declare
        cleanup_status : constant Clair.Status.Code :=
          rollback_local_initialization (self);
      begin
        return
          (if cleanup_status = Clair.Status.OK then status else cleanup_status);
      end;
    end if;

    status := Sonbal.Connector_Host.initialize
      (self             => self.host,
       event_loop       => event_loop,
       plugin_path      => plugin_path,
       configuration_fd => configuration_fd,
       credential_fd    => credential_fd,
       max_work_slots   => max_work_slots,
       progress_handler => self.progress_handler'unchecked_access);
    if status /= Clair.Status.OK then
      declare
        cleanup_status : constant Clair.Status.Code :=
          rollback_local_initialization (self);
      begin
        return
          (if cleanup_status = Clair.Status.OK then status else cleanup_status);
      end;
    end if;

    self.initialized := True;
    self.started := False;
    self.stopping := False;
    self.core_stopping := False;
    self.host_finalized := False;
    self.failure := No_Failure;
    return Clair.Status.OK;
  exception
    when others =>
      mark_failure (self, Internal_Failure);
      return Clair.Status.INTERNAL_ERROR;
  end initialize;

  function start (self : in out Context) return Clair.Status.Code is
    status : Clair.Status.Code;
  begin
    if not self.initialized or else self.started or else self.stopping then
      return Clair.Status.INVALID_STATE;
    end if;

    status := Sonbal.Connector_Host.start (self.host);
    if status /= Clair.Status.OK then
      mark_failure (self, Connector_Failure);
      return status;
    end if;

    self.started := True;
    return Clair.Status.OK;
  exception
    when others =>
      mark_failure (self, Internal_Failure);
      return Clair.Status.INTERNAL_ERROR;
  end start;

  function begin_shutdown (self : in out Context) return Clair.Status.Code is
    status : Clair.Status.Code;
  begin
    if not self.initialized or else not self.started then
      return Clair.Status.INVALID_STATE;
    end if;

    if not self.stopping then
      status := Sonbal.Connector_Host.begin_shutdown (self.host);
      if status /= Clair.Status.OK then
        mark_failure (self, Connector_Failure);
        return status;
      end if;

      self.stopping := True;
    end if;

    return advance_shutdown (self);
  exception
    when others =>
      mark_failure (self, Internal_Failure);
      return Clair.Status.INTERNAL_ERROR;
  end begin_shutdown;

  function is_initialized (self : Context) return Boolean is
    (self.initialized);

  function active_request_count (self : Context) return Natural is
    result : Natural := 0;
  begin
    if self.slots = null then
      return 0;
    end if;

    for index in 1 .. self.request_slot_count loop
      if self.slots(index).state /= Slot_Free then
        result := result + 1;
      end if;
    end loop;
    return result;
  end active_request_count;

  function active_execution_count (self : Context) return Natural is
  begin
    if not self.initialized then
      return 0;
    end if;

    return Sonbal.MCP.Request_Core.active_execution_count (self.core);
  end active_execution_count;


  function is_settled (self : Context) return Boolean is
  begin
    return
      self.initialized and then
      self.started and then
      self.stopping and then
      self.core_stopping and then
      Sonbal.Connector_Host.shutdown_complete (self.host) and then
      all_slots_free (self) and then
      Sonbal.MCP.Request_Core.is_idle (self.core);
  end is_settled;

  function has_failed (self : Context) return Boolean is
    (self.failure /= No_Failure or else
     Sonbal.Connector_Host.has_failed (self.host));

  function finalize (self : in out Context) return Clair.Status.Code is
    status : Clair.Status.Code;
  begin
    if not self.initialized then
      return Clair.Status.INVALID_STATE;
    elsif not all_slots_free (self) then
      return Clair.Status.INVALID_STATE;
    elsif Sonbal.MCP.Request_Core.is_initialized (self.core) and then
          not Sonbal.MCP.Request_Core.is_idle (self.core)
    then
      return Clair.Status.INVALID_STATE;
    elsif self.started and then
          not self.host_finalized and then
          not Sonbal.Connector_Host.shutdown_complete (self.host)
    then
      return Clair.Status.INVALID_STATE;
    end if;

    if not self.host_finalized then
      status := Sonbal.Connector_Host.finalize (self.host);
      if status /= Clair.Status.OK then
        return status;
      end if;
      self.host_finalized := True;
    end if;

    status := finalize_process_slots (self);
    if status /= Clair.Status.OK then
      return status;
    end if;

    if Sonbal.MCP.Request_Core.is_initialized (self.core) then
      status := Sonbal.MCP.Request_Core.finalize (self.core);
      if status /= Clair.Status.OK then
        return status;
      end if;
    end if;

    free_request_slots (self.slots);
    self.event_loop := null;
    self.progress_handler.owner := null;
    self.process_handler.owner := null;
    self.initialized := False;
    self.started := False;
    self.stopping := False;
    self.core_stopping := False;
    return Clair.Status.OK;
  exception
    when others =>
      mark_failure (self, Internal_Failure);
      return Clair.Status.INTERNAL_ERROR;
  end finalize;

end Sonbal.Connector_Server;
