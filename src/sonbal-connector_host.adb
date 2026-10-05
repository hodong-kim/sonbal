-- ============================================================================
-- sonbal-connector_host.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Ada.Unchecked_Conversion;
with Clair.Process;
with Interfaces;
with Interfaces.C;
with Sonbal.MCP.Dispatcher;
with Sonbal.MCP.JSON;
with System.Address_To_Access_Conversions;

package body Sonbal.Connector_Host is

  use type Clair.Dynamic_Library.Handle;
  use type Clair.Event_Loop.Context_Access;
  use type Clair.Event_Loop.Event_Mask;
  use type Clair.Event_Loop.Source_Handle;
  use type Clair.IO.Descriptor;
  use type Clair.Status.Code;
  use type Interfaces.C.int;
  use type Interfaces.Unsigned_32;
  use type Interfaces.Unsigned_64;
  use type Sonbal.Connector_ABI.Begin_Shutdown_Access;
  use type Sonbal.Connector_ABI.Complete_Request_Access;
  use type Sonbal.Connector_ABI.Connector_Kind;
  use type Sonbal.Connector_ABI.Finalize_Access;
  use type Sonbal.Connector_ABI.Initialize_Access;
  use type Sonbal.Connector_ABI.Next_Event_Access;
  use type Sonbal.Connector_ABI.Request_Token;
  use type Sonbal.Connector_ABI.Start_Access;
  use type Sonbal.Connector_ABI.Status_Code;
  use type System.Address;

  MAXIMUM_LIFECYCLE_EVENTS_PER_WAKEUP : constant Positive := 16;

  package Descriptor_Conversions is new System.Address_To_Access_Conversions
    (Sonbal.Connector_ABI.Descriptor);

  use type Descriptor_Conversions.Object_Pointer;

  type Callback_Bridge_Access is access all Callback_Bridge;

  function address_to_bridge is new Ada.Unchecked_Conversion
    (System.Address, Callback_Bridge_Access);

  function wakeup_callback
    (source           : access constant Clair.Event_Loop.Source_Handle;
     fd               : Clair.IO.Descriptor;
     events           : Clair.Event_Loop.Event_Mask;
     callback_context : System.Address)
  return Clair.Status.Code
  with Convention => C;

  procedure clear_descriptor (self : in out Context) is
  begin
    self.descriptor :=
      (magic            => 0,
       abi_version      => 0,
       descriptor_size  => 0,
       kind             => Sonbal.Connector_ABI.CONNECTOR_UNKNOWN,
       initialize       => null,
       start            => null,
       next_event       => null,
       complete_request => null,
       begin_shutdown   => null,
       finalize         => null);
  end clear_descriptor;

  function close_startup_descriptor
    (fd : in out Clair.IO.Descriptor)
  return Clair.Status.Code
  is
    status : Clair.Status.Code;
  begin
    if fd = Clair.IO.INVALID_DESCRIPTOR then
      return Clair.Status.OK;
    end if;

    status := Clair.IO.close (fd);
    if status = Clair.Status.OK then
      fd := Clair.IO.INVALID_DESCRIPTOR;
    end if;
    return status;
  end close_startup_descriptor;

  function close_startup_descriptors
    (configuration_fd : in out Clair.IO.Descriptor;
     credential_fd    : in out Clair.IO.Descriptor)
  return Clair.Status.Code
  is
    first_status : Clair.Status.Code;
    second_status : Clair.Status.Code;
  begin
    if configuration_fd /= Clair.IO.INVALID_DESCRIPTOR and then
       configuration_fd = credential_fd
    then
      first_status := close_startup_descriptor (configuration_fd);
      if first_status = Clair.Status.OK then
        credential_fd := Clair.IO.INVALID_DESCRIPTOR;
      end if;
      return first_status;
    end if;

    first_status := close_startup_descriptor (configuration_fd);
    second_status := close_startup_descriptor (credential_fd);

    if first_status /= Clair.Status.OK then
      return first_status;
    end if;
    return second_status;
  end close_startup_descriptors;

  function close_library (self : in out Context) return Clair.Status.Code is
    status : Clair.Status.Code;
  begin
    if self.library = Clair.Dynamic_Library.NULL_HANDLE then
      clear_descriptor (self);
      return Clair.Status.OK;
    end if;

    status := Clair.Dynamic_Library.close (self.library);
    if status /= Clair.Status.OK then
      self.failed := True;
      self.state := Host_Library_Close_Failed;
      return status;
    end if;

    clear_descriptor (self);
    return Clair.Status.OK;
  end close_library;

  function plugin_status
    (status : Sonbal.Connector_ABI.Status_Code)
  return Clair.Status.Code
  is
  begin
    if status = Sonbal.Connector_ABI.STATUS_OK then
      return Clair.Status.OK;
    elsif status = Sonbal.Connector_ABI.STATUS_INVALID_ARGUMENT then
      return Clair.Status.INVALID_ARGUMENT;
    elsif status = Sonbal.Connector_ABI.STATUS_INVALID_STATE then
      return Clair.Status.INVALID_STATE;
    elsif status = Sonbal.Connector_ABI.STATUS_RESOURCE_EXHAUSTED then
      return Clair.Status.OUT_OF_MEMORY;
    end if;

    return Clair.Status.CALLBACK_FAILED;
  end plugin_status;

  function descriptor_is_valid
    (item : Sonbal.Connector_ABI.Descriptor)
  return Boolean
  is
  begin
    return
      item.magic = Sonbal.Connector_ABI.ABI_MAGIC and then
      item.abi_version = Sonbal.Connector_ABI.ABI_VERSION and then
      item.descriptor_size = Sonbal.Connector_ABI.DESCRIPTOR_BYTES and then
      item.kind = Sonbal.Connector_ABI.CONNECTOR_OPENAI and then
      item.initialize /= null and then
      item.start /= null and then
      item.next_event /= null and then
      item.complete_request /= null and then
      item.begin_shutdown /= null and then
      item.finalize /= null;
  end descriptor_is_valid;

  function plugin_finalize (self : in out Context) return Clair.Status.Code is
    instance : aliased System.Address := self.instance;
    status   : Sonbal.Connector_ABI.Status_Code;
  begin
    if self.instance = System.NULL_ADDRESS then
      return Clair.Status.OK;
    elsif self.descriptor.finalize = null then
      self.failed := True;
      return Clair.Status.INTERNAL_ERROR;
    end if;

    status := self.descriptor.finalize (instance'access);
    self.instance := instance;

    if status /= Sonbal.Connector_ABI.STATUS_OK then
      self.failed := True;
      return plugin_status (status);
    elsif instance /= System.NULL_ADDRESS then
      self.failed := True;
      return Clair.Status.CONTRACT_VIOLATION;
    end if;

    return Clair.Status.OK;
  exception
    when others =>
      self.failed := True;
      return Clair.Status.INTERNAL_ERROR;
  end plugin_finalize;

  function remove_wakeup_source
    (self : in out Context)
  return Clair.Status.Code
  is
  begin
    if self.wakeup_source = Clair.Event_Loop.NULL_SOURCE then
      return Clair.Status.OK;
    elsif self.event_loop = null then
      self.failed := True;
      return Clair.Status.INTERNAL_ERROR;
    end if;

    return Clair.Event_Loop.remove (self.event_loop.all, self.wakeup_source);
  exception
    when others =>
      self.failed := True;
      return Clair.Status.INTERNAL_ERROR;
  end remove_wakeup_source;

  function rollback_initialized
    (self : in out Context)
  return Clair.Status.Code
  is
    status : Clair.Status.Code;
  begin
    status := remove_wakeup_source (self);
    if status /= Clair.Status.OK then
      self.failed := True;
      return status;
    end if;

    status := plugin_finalize (self);
    if status /= Clair.Status.OK then
      return status;
    end if;

    self.wakeup_fd := Clair.IO.INVALID_DESCRIPTOR;
    self.event_loop := null;
    self.bridge.owner := null;
    self.progress_handler := null;

    status := close_library (self);
    if status /= Clair.Status.OK then
      return status;
    end if;

    self.state := Host_Empty;
    return Clair.Status.OK;
  end rollback_initialized;

  function quarantine
    (self : in out Context;
     status : Clair.Status.Code)
  return Clair.Status.Code
  is
  begin
    self.failed := True;
    self.state := Host_Quarantined;
    return status;
  end quarantine;

  function fail_before_plugin
    (self             : in out Context;
     primary          : Clair.Status.Code;
     configuration_fd : in out Clair.IO.Descriptor;
     credential_fd    : in out Clair.IO.Descriptor)
  return Clair.Status.Code
  is
    fd_status      : Clair.Status.Code;
    library_status : Clair.Status.Code;
  begin
    fd_status := close_startup_descriptors (configuration_fd, credential_fd);
    library_status := close_library (self);
    self.event_loop := null;
    self.bridge.owner := null;
    self.progress_handler := null;

    if library_status /= Clair.Status.OK then
      return library_status;
    elsif fd_status /= Clair.Status.OK then
      return fd_status;
    end if;

    self.state := Host_Empty;
    return primary;
  end fail_before_plugin;

  function initialize
    (self             : aliased in out Context;
     event_loop       : aliased in out Clair.Event_Loop.Context;
     plugin_path      : String;
     configuration_fd : in out Clair.IO.Descriptor;
     credential_fd    : in out Clair.IO.Descriptor;
     max_work_slots   : Sonbal.Configuration.Work_Slot_Count;
     progress_handler : Progress_Handler_Access := null)
  return Clair.Status.Code
  is
    symbol_address : System.Address := System.NULL_ADDRESS;
    pointer : Descriptor_Conversions.Object_Pointer;
    parameters : aliased Sonbal.Connector_ABI.Initialize_Parameters;
    instance : aliased System.Address := System.NULL_ADDRESS;
    wakeup : aliased Interfaces.C.int :=
      Sonbal.Connector_ABI.INVALID_STARTUP_FD;
    status : Clair.Status.Code;
    fd_status : Clair.Status.Code;
    plugin_result : Sonbal.Connector_ABI.Status_Code;
  begin
    if self.state /= Host_Empty then
      return Clair.Status.INVALID_STATE;
    end if;

    self.failed := False;
    self.event_loop := event_loop'unchecked_access;
    self.bridge.owner := self'unchecked_access;
    self.progress_handler := progress_handler;

    if plugin_path'length = 0 or else
       plugin_path(plugin_path'first) /= '/' or else
       (configuration_fd /= Clair.IO.INVALID_DESCRIPTOR and then
        configuration_fd = credential_fd)
    then
      return fail_before_plugin
        (self,
         Clair.Status.INVALID_ARGUMENT,
         configuration_fd,
         credential_fd);
    end if;

    status := Clair.Dynamic_Library.open (plugin_path, self.library);
    if status /= Clair.Status.OK then
      return fail_before_plugin
        (self, status, configuration_fd, credential_fd);
    end if;

    status := Clair.Dynamic_Library.lookup_symbol
      (self.library,
       Sonbal.Connector_ABI.DESCRIPTOR_SYMBOL,
       symbol_address);
    if status /= Clair.Status.OK or else
       symbol_address = System.NULL_ADDRESS
    then
      if status = Clair.Status.OK then
        status := Clair.Status.SYMBOL_LOOKUP_ERROR;
      end if;
      return fail_before_plugin
        (self, status, configuration_fd, credential_fd);
    end if;

    pointer := Descriptor_Conversions.to_pointer (symbol_address);
    if pointer = null then
      return fail_before_plugin
        (self,
         Clair.Status.CONTRACT_VIOLATION,
         configuration_fd,
         credential_fd);
    end if;

    self.descriptor := pointer.all;
    if not descriptor_is_valid (self.descriptor) then
      return fail_before_plugin
        (self,
         Clair.Status.CONTRACT_VIOLATION,
         configuration_fd,
         credential_fd);
    end if;

    status := Clair.Process.disable_current_process_inspection;
    if status /= Clair.Status.OK then
      return fail_before_plugin
        (self, status, configuration_fd, credential_fd);
    end if;

    parameters :=
      (abi_version             => Sonbal.Connector_ABI.ABI_VERSION,
       struct_size             =>
         Sonbal.Connector_ABI.INITIALIZE_PARAMETERS_BYTES,
       maximum_active_requests =>
         Interfaces.Unsigned_32(max_work_slots) + 1,
       maximum_request_bytes   =>
         Interfaces.Unsigned_32(Sonbal.MCP.JSON.Max_Input_Bytes),
       maximum_response_bytes  =>
         Interfaces.Unsigned_32
           (Sonbal.MCP.Dispatcher.MAXIMUM_MCP_RESPONSE_BYTES),
       configuration_fd        => Interfaces.C.int(configuration_fd),
       credential_fd           => Interfaces.C.int(credential_fd));

    plugin_result := self.descriptor.initialize
      (parameters'access, instance'access, wakeup'access);

    fd_status := close_startup_descriptors (configuration_fd, credential_fd);

    if plugin_result /= Sonbal.Connector_ABI.STATUS_OK then
      declare
        contract_violation : constant Boolean :=
          instance /= System.NULL_ADDRESS or else
          wakeup /= Sonbal.Connector_ABI.INVALID_STARTUP_FD;
      begin
        if contract_violation then
          self.instance := instance;
          if instance = System.NULL_ADDRESS then
            return quarantine (self, Clair.Status.CONTRACT_VIOLATION);
          end if;

          status := plugin_finalize (self);
          if status /= Clair.Status.OK then
            return quarantine (self, status);
          end if;
        end if;

        status := close_library (self);
        self.event_loop := null;
        self.bridge.owner := null;
        self.progress_handler := null;
        if status /= Clair.Status.OK then
          return status;
        elsif fd_status /= Clair.Status.OK then
          return fd_status;
        elsif contract_violation then
          self.state := Host_Empty;
          return Clair.Status.CONTRACT_VIOLATION;
        end if;
      end;

      self.state := Host_Empty;
      return plugin_status (plugin_result);
    end if;

    self.instance := instance;

    if instance = System.NULL_ADDRESS or else
       wakeup < 0
    then
      if instance /= System.NULL_ADDRESS then
        status := plugin_finalize (self);
        if status /= Clair.Status.OK then
          return quarantine (self, status);
        end if;
      else
        return quarantine (self, Clair.Status.CONTRACT_VIOLATION);
      end if;

      status := close_library (self);
      self.event_loop := null;
      self.bridge.owner := null;
      self.progress_handler := null;
      if status /= Clair.Status.OK then
        return status;
      elsif fd_status /= Clair.Status.OK then
        return fd_status;
      end if;

      self.state := Host_Empty;
      return Clair.Status.CONTRACT_VIOLATION;
    end if;

    self.wakeup_fd := Clair.IO.Descriptor(wakeup);
    self.state := Host_Initialized;

    if fd_status /= Clair.Status.OK then
      status := rollback_initialized (self);
      if status /= Clair.Status.OK then
        return status;
      end if;
      return fd_status;
    end if;

    status := Clair.Event_Loop.add_watch
      (self             => event_loop,
       fd               => self.wakeup_fd,
       events           => Clair.Event_Loop.EVENT_INPUT,
       callback         => wakeup_callback'access,
       callback_context => self.bridge'address,
       source           => self.wakeup_source);
    if status /= Clair.Status.OK then
      declare
        cleanup_status : constant Clair.Status.Code :=
          rollback_initialized (self);
      begin
        if cleanup_status /= Clair.Status.OK then
          return cleanup_status;
        end if;
      end;
      return status;
    end if;

    return Clair.Status.OK;
  exception
    when others =>
      self.failed := True;
      return Clair.Status.INTERNAL_ERROR;
  end initialize;

  function start (self : in out Context) return Clair.Status.Code is
    status : Sonbal.Connector_ABI.Status_Code;
  begin
    if self.state /= Host_Initialized or else
       self.instance = System.NULL_ADDRESS
    then
      return Clair.Status.INVALID_STATE;
    end if;

    status := self.descriptor.start (self.instance);
    if status /= Sonbal.Connector_ABI.STATUS_OK then
      return plugin_status (status);
    end if;

    self.state := Host_Started;
    return Clair.Status.OK;
  exception
    when others =>
      self.failed := True;
      return Clair.Status.INTERNAL_ERROR;
  end start;

  function event_shape_is_valid
    (item                 : Sonbal.Connector_ABI.Event;
     request_capacity     : Interfaces.Unsigned_32;
     correlation_capacity : Interfaces.Unsigned_32)
  return Boolean
  is
  begin
    if item.correlation_truncated > 1 then
      return False;
    end if;

    case item.kind is
      when Sonbal.Connector_ABI.EVENT_REQUEST =>
        return
          item.token /= Sonbal.Connector_ABI.NO_REQUEST_TOKEN and then
          item.request_length <= request_capacity and then
          item.correlation_length <= correlation_capacity;

      when Sonbal.Connector_ABI.EVENT_REQUEST_ABANDONED =>
        return
          item.token /= Sonbal.Connector_ABI.NO_REQUEST_TOKEN and then
          item.request_length = 0 and then
          item.correlation_length = 0 and then
          item.correlation_truncated = 0;

      when Sonbal.Connector_ABI.EVENT_FATAL |
           Sonbal.Connector_ABI.EVENT_SHUTDOWN_COMPLETE =>
        return
          item.token = Sonbal.Connector_ABI.NO_REQUEST_TOKEN and then
          item.request_length = 0 and then
          item.correlation_length = 0 and then
          item.correlation_truncated = 0;

      when Sonbal.Connector_ABI.EVENT_NONE =>
        return False;

      when others =>
        return False;
    end case;
  end event_shape_is_valid;

  function next_event
    (self                 : in out Context;
     request_buffer       : System.Address;
     request_capacity     : Natural;
     correlation_buffer   : System.Address;
     correlation_capacity : Natural;
     item                 : aliased out Sonbal.Connector_ABI.Event;
     state                : out Event_Poll_State)
  return Clair.Status.Code
  is
    request_limit : Interfaces.Unsigned_32;
    correlation_limit : Interfaces.Unsigned_32;
    plugin_result : Sonbal.Connector_ABI.Status_Code;
  begin
    state := Event_Poll_Failed;
    item :=
      (token                 => Sonbal.Connector_ABI.NO_REQUEST_TOKEN,
       kind                  => Sonbal.Connector_ABI.EVENT_NONE,
       request_length        => 0,
       correlation_length    => 0,
       correlation_truncated => 0);

    if self.state not in Host_Started | Host_Stopping then
      return Clair.Status.INVALID_STATE;
    elsif request_capacity > 0 and then
          request_buffer = System.NULL_ADDRESS
    then
      return Clair.Status.INVALID_ARGUMENT;
    elsif correlation_capacity > 0 and then
          correlation_buffer = System.NULL_ADDRESS
    then
      return Clair.Status.INVALID_ARGUMENT;
    end if;

    request_limit := Interfaces.Unsigned_32(request_capacity);
    correlation_limit := Interfaces.Unsigned_32(correlation_capacity);

    plugin_result := self.descriptor.next_event
      (instance             => self.instance,
       request_buffer       => request_buffer,
       request_capacity     => request_limit,
       correlation_buffer   => correlation_buffer,
       correlation_capacity => correlation_limit,
       result_event         => item'access);

    if plugin_result = Sonbal.Connector_ABI.STATUS_WOULD_BLOCK then
      state := Event_Would_Block;
      return Clair.Status.OK;
    elsif plugin_result /= Sonbal.Connector_ABI.STATUS_OK then
      self.failed := True;
      return plugin_status (plugin_result);
    elsif not event_shape_is_valid
      (item, request_limit, correlation_limit)
    then
      self.failed := True;
      return Clair.Status.CONTRACT_VIOLATION;
    end if;

    case item.kind is
      when Sonbal.Connector_ABI.EVENT_FATAL =>
        self.failed := True;

      when Sonbal.Connector_ABI.EVENT_SHUTDOWN_COMPLETE =>
        if self.state /= Host_Stopping then
          self.failed := True;
          return Clair.Status.CONTRACT_VIOLATION;
        end if;
        self.state := Host_Stopped;

      when others =>
        null;
    end case;

    state := Event_Ready;
    return Clair.Status.OK;
  exception
    when others =>
      self.failed := True;
      state := Event_Poll_Failed;
      return Clair.Status.INTERNAL_ERROR;
  end next_event;

  function complete_request
    (self            : in out Context;
     token           : Sonbal.Connector_ABI.Request_Token;
     response        : System.Address;
     response_length : Natural;
     state           : out Completion_State)
  return Clair.Status.Code
  is
    plugin_result : Sonbal.Connector_ABI.Status_Code;
  begin
    state := Completion_Failed;

    if self.state not in Host_Started | Host_Stopping then
      return Clair.Status.INVALID_STATE;
    elsif token = Sonbal.Connector_ABI.NO_REQUEST_TOKEN then
      return Clair.Status.INVALID_ARGUMENT;
    elsif response_length >
      Sonbal.MCP.Dispatcher.MAXIMUM_MCP_RESPONSE_BYTES
    then
      return Clair.Status.RANGE_ERROR;
    elsif response_length > 0 and then response = System.NULL_ADDRESS then
      return Clair.Status.INVALID_ARGUMENT;
    end if;

    plugin_result := self.descriptor.complete_request
      (instance        => self.instance,
       token           => token,
       response        => response,
       response_length => Interfaces.Unsigned_32(response_length));

    if plugin_result = Sonbal.Connector_ABI.STATUS_WOULD_BLOCK then
      state := Completion_Would_Block;
      return Clair.Status.OK;
    elsif plugin_result /= Sonbal.Connector_ABI.STATUS_OK then
      self.failed := True;
      return plugin_status (plugin_result);
    end if;

    state := Completion_Accepted;
    return Clair.Status.OK;
  exception
    when others =>
      self.failed := True;
      state := Completion_Failed;
      return Clair.Status.INTERNAL_ERROR;
  end complete_request;

  function begin_shutdown (self : in out Context) return Clair.Status.Code is
    status : Sonbal.Connector_ABI.Status_Code;
  begin
    if self.state = Host_Stopping then
      return Clair.Status.OK;
    elsif self.state /= Host_Started then
      return Clair.Status.INVALID_STATE;
    end if;

    status := self.descriptor.begin_shutdown (self.instance);
    if status /= Sonbal.Connector_ABI.STATUS_OK then
      return plugin_status (status);
    end if;

    self.state := Host_Stopping;
    return Clair.Status.OK;
  exception
    when others =>
      self.failed := True;
      return Clair.Status.INTERNAL_ERROR;
  end begin_shutdown;

  function drain_lifecycle_events
    (self : in out Context)
  return Clair.Status.Code
  is
    item : aliased Sonbal.Connector_ABI.Event;
  begin
    for ignored in 1 .. MAXIMUM_LIFECYCLE_EVENTS_PER_WAKEUP loop
      item :=
        (token                 => Sonbal.Connector_ABI.NO_REQUEST_TOKEN,
         kind                  => Sonbal.Connector_ABI.EVENT_NONE,
         request_length        => 0,
         correlation_length    => 0,
         correlation_truncated => 0);

      declare
        poll_state : Event_Poll_State;
        host_status : Clair.Status.Code;
      begin
        host_status := next_event
          (self                 => self,
           request_buffer       => System.NULL_ADDRESS,
           request_capacity     => 0,
           correlation_buffer   => System.NULL_ADDRESS,
           correlation_capacity => 0,
           item                 => item,
           state                => poll_state);

        if host_status /= Clair.Status.OK then
          return host_status;
        elsif poll_state = Event_Would_Block then
          return Clair.Status.OK;
        elsif poll_state /= Event_Ready then
          return Clair.Status.INTERNAL_ERROR;
        end if;
      end;

      case item.kind is
        when Sonbal.Connector_ABI.EVENT_FATAL =>
          null;

        when Sonbal.Connector_ABI.EVENT_SHUTDOWN_COMPLETE =>
          return Clair.Status.OK;

        when Sonbal.Connector_ABI.EVENT_NONE |
             Sonbal.Connector_ABI.EVENT_REQUEST |
             Sonbal.Connector_ABI.EVENT_REQUEST_ABANDONED =>
          self.failed := True;
          return Clair.Status.CONTRACT_VIOLATION;

        when others =>
          self.failed := True;
          return Clair.Status.CONTRACT_VIOLATION;
      end case;
    end loop;

    self.failed := True;
    return Clair.Status.RANGE_ERROR;
  exception
    when others =>
      self.failed := True;
      return Clair.Status.INTERNAL_ERROR;
  end drain_lifecycle_events;

  function wakeup_callback
    (source           : access constant Clair.Event_Loop.Source_Handle;
     fd               : Clair.IO.Descriptor;
     events           : Clair.Event_Loop.Event_Mask;
     callback_context : System.Address)
  return Clair.Status.Code
  is
    bridge : constant Callback_Bridge_Access :=
      address_to_bridge (callback_context);
    relevant : constant Clair.Event_Loop.Event_Mask :=
      Clair.Event_Loop.EVENT_INPUT or
      Clair.Event_Loop.EVENT_ERROR or
      Clair.Event_Loop.EVENT_HANG_UP;
  begin
    if source = null or else
       bridge = null or else
       bridge.owner = null
    then
      return Clair.Status.INTERNAL_ERROR;
    end if;

    declare
      self : Context renames bridge.owner.all;
    begin
      if source.all /= self.wakeup_source or else
         fd /= self.wakeup_fd
      then
        self.failed := True;
        return Clair.Status.OK;
      end if;

      if (events and relevant) = 0 then
        return Clair.Status.OK;
      end if;

      declare
        status : Clair.Status.Code;
        abnormal : constant Clair.Event_Loop.Event_Mask :=
          events and
          (Clair.Event_Loop.EVENT_ERROR or Clair.Event_Loop.EVENT_HANG_UP);
      begin
        if self.progress_handler = null then
          status := drain_lifecycle_events (self);
        else
          status := on_connector_progress (self.progress_handler.all);
        end if;

        if status /= Clair.Status.OK then
          self.failed := True;
        elsif abnormal /= 0 and then self.state /= Host_Stopped then
          self.failed := True;
        end if;
      end;

      return Clair.Status.OK;
    end;
  exception
    when others =>
      if bridge /= null and then bridge.owner /= null then
        bridge.owner.failed := True;
      end if;
      return Clair.Status.OK;
  end wakeup_callback;

  function is_initialized (self : Context) return Boolean is
    (self.state in
       Host_Initialized |
       Host_Started |
       Host_Stopping |
       Host_Stopped);

  function is_started (self : Context) return Boolean is
    (self.state in Host_Started | Host_Stopping | Host_Stopped);

  function shutdown_complete (self : Context) return Boolean is
    (self.state = Host_Stopped);

  function has_failed (self : Context) return Boolean is
    (self.failed or else
       self.state in Host_Quarantined | Host_Library_Close_Failed);

  function finalize (self : in out Context) return Clair.Status.Code is
    status : Clair.Status.Code;
  begin
    if self.state = Host_Finalized then
      return Clair.Status.INVALID_STATE;
    elsif self.state not in Host_Initialized | Host_Stopped then
      return Clair.Status.INVALID_STATE;
    end if;

    status := remove_wakeup_source (self);
    if status /= Clair.Status.OK then
      return status;
    end if;

    status := plugin_finalize (self);
    if status /= Clair.Status.OK then
      return status;
    end if;

    self.wakeup_fd := Clair.IO.INVALID_DESCRIPTOR;
    self.event_loop := null;
    self.bridge.owner := null;
    self.progress_handler := null;

    status := close_library (self);
    if status /= Clair.Status.OK then
      return status;
    end if;

    self.state := Host_Finalized;
    return Clair.Status.OK;
  exception
    when others =>
      self.failed := True;
      return Clair.Status.INTERNAL_ERROR;
  end finalize;

end Sonbal.Connector_Host;
