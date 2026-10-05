-- ============================================================================
-- sonbal-mcp-stdio_server.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Ada.Characters.Latin_1;
with Ada.Interrupts.Names;
with Ada.Real_Time;
with Ada.Unchecked_Conversion;
with Ada.Unchecked_Deallocation;
with Clair.Event_Loop;
with Clair.IO;
with Clair.IO.Posix;
with Clair.Log;
with Clair.Process.Execution;
with Clair.Process.Execution.Event_Loop;
with Clair.Status;
with Clair.Unix.Signal;
with Sonbal.MCP.Dispatcher;
with Sonbal.MCP.Request_Core;
with Sonbal.MCP.Stdio_Framing;
with Sonbal.Process_Execution;
with System;

package body Sonbal.MCP.Stdio_Server is
  use type Ada.Real_Time.Time;
  use type Clair.Event_Loop.Context_Access;
  use type Clair.Event_Loop.Event_Mask;
  use type Clair.Event_Loop.Source_Handle;
  use type Clair.IO.Byte_Count;
  use type Clair.IO.Descriptor;
  use type Clair.Process.Execution.Event_Loop.Operation_Cause;
  use type Clair.Status.Code;
  use type Sonbal.MCP.Dispatcher.Action_Kind;
  use type Sonbal.Process_Execution.Operation_Access;

   Input_Chunk_Bytes : constant Positive := 16_384;
  MAXIMUM_CLEANUP_RETRIES : constant Positive := 3;

   Standard_Input : constant Clair.IO.Descriptor := Clair.IO.STANDARD_INPUT;
   Standard_Output : constant Clair.IO.Descriptor := Clair.IO.STANDARD_OUTPUT;
   Broken_Pipe_Signal : constant Clair.Unix.Signal.Number :=
     Clair.Unix.Signal.Number (Ada.Interrupts.Names.SIGPIPE);

  SHUTDOWN_POLL_INTERVAL : constant Clair.Event_Loop.Milliseconds := 250;

  shutdown_requested : Boolean := False
    with Atomic;

  procedure shutdown_signal_handler (signo : Clair.Unix.Signal.Number);
  pragma Convention (C, shutdown_signal_handler);

  procedure shutdown_signal_handler
    (signo : Clair.Unix.Signal.Number)
  is
    pragma Unreferenced (signo);
  begin
    shutdown_requested := True;
  end shutdown_signal_handler;

   Line_Feed : constant String :=
     String'(1 => Ada.Characters.Latin_1.LF);

   type Signal_Guard is record
      Previous  : Clair.Unix.Signal.Action;
      Installed : Boolean := False;
   end record;

   procedure write_diagnostic (Message : String) is
   begin
      Clair.Log.write
        (severity     => Clair.Log.Error,
         message      => Message,
         destinations => Clair.Log.Native_Diagnostic);
   exception
      when others =>
         null;
   end write_diagnostic;

   function install_broken_pipe_guard
     (Guard : in out Signal_Guard) return Boolean
   is
      Mask    : Clair.Unix.Signal.Set;
      Ignored : Clair.Unix.Signal.Action;
      Status  : Clair.Status.Code;
   begin
      Status := Clair.Unix.Signal.set_empty (Mask);
      if Status /= Clair.Status.OK then
         return False;
      end if;

      Status :=
        Clair.Unix.Signal.make_ignored_action
          (mask   => Mask,
           signal_action => Ignored);
      if Status /= Clair.Status.OK then
         return False;
      end if;

      Status :=
        Clair.Unix.Signal.replace_process_action
          (signal_number => Broken_Pipe_Signal,
           signal_action          => Ignored,
           previous_signal_action => Guard.Previous);
      if Status /= Clair.Status.OK then
         return False;
      end if;

      Guard.Installed := True;
      return True;
   end install_broken_pipe_guard;

   function restore_broken_pipe_guard
     (Guard : in out Signal_Guard) return Boolean
   is
      Status : Clair.Status.Code;
   begin
      if not Guard.Installed then
         return True;
      end if;

      declare
         Previous : constant Clair.Unix.Signal.Action := Guard.Previous;
      begin
         Status :=
           Clair.Unix.Signal.replace_process_action
             (signal_number => Broken_Pipe_Signal,
              signal_action          => Previous,
              previous_signal_action => Guard.Previous);
      end;

      Guard.Installed := False;
      return Status = Clair.Status.OK;
   end restore_broken_pipe_guard;

  function install_shutdown_guard
    (guard : in out Signal_Guard;
     signo : Clair.Unix.Signal.Number) return Boolean
  is
    mask   : Clair.Unix.Signal.Set;
    action : Clair.Unix.Signal.Action;
    status : Clair.Status.Code;
  begin
    status := Clair.Unix.Signal.set_empty (mask);
    if status /= Clair.Status.OK then
      return False;
    end if;

    status := Clair.Unix.Signal.make_handler_action
      (handler => shutdown_signal_handler'Access,
       mask    => mask,
       signal_action => action);
    if status /= Clair.Status.OK then
      return False;
    end if;

    status := Clair.Unix.Signal.replace_process_action
      (signal_number => signo,
       signal_action          => action,
       previous_signal_action => guard.Previous);
    if status /= Clair.Status.OK then
      return False;
    end if;

    guard.Installed := True;
    return True;
  end install_shutdown_guard;

  function restore_shutdown_guard
    (guard : in out Signal_Guard;
     signo : Clair.Unix.Signal.Number) return Boolean
  is
    status : Clair.Status.Code := Clair.Status.INTERNAL_ERROR;
  begin
    if not guard.Installed then
      return True;
    end if;

    for attempt in 1 .. MAXIMUM_CLEANUP_RETRIES loop
      declare
        previous : constant Clair.Unix.Signal.Action := guard.Previous;
      begin
        status := Clair.Unix.Signal.replace_process_action
          (signal_number => signo,
           signal_action          => previous,
           previous_signal_action => guard.Previous);
      end;
      exit when status = Clair.Status.OK;
    end loop;

    if status = Clair.Status.OK then
      guard.Installed := False;
      return True;
    end if;
    return False;
  end restore_shutdown_guard;

  type Slot_State is
    (Slot_Free,
     Slot_Ready,
     Slot_Unresolved);

  PROCESS_SETTLE_TIMEOUT : constant Ada.Real_Time.Time_Span :=
    Ada.Real_Time.Seconds (5);
  PROCESS_SETTLE_WAIT_MS : constant Clair.Event_Loop.Milliseconds := 100;
  MAXIMUM_REQUEST_SLOT_COUNT : constant Positive :=
    Sonbal.Configuration.ABSOLUTE_MAX_WORK_SLOTS + 1;
  OUTPUT_BUFFER_BYTES     : constant Positive :=
    Sonbal.MCP.Dispatcher.MAXIMUM_MCP_RESPONSE_BYTES + 1;

  type Server_Context;
  type Server_Context_Access is access all Server_Context;

  type Process_Completion_Bridge is limited new
    Sonbal.Process_Execution.Completion_Handler with record
      owner : Server_Context_Access := null;
    end record;

  overriding function on_complete
    (handler   : in out Process_Completion_Bridge;
     operation : not null Sonbal.Process_Execution.Operation_Access;
     cause     : Clair.Process.Execution.Event_Loop.Operation_Cause;
     status    : Clair.Status.Code;
     outcome   : Clair.Process.Execution.Result)
  return Clair.Status.Code;

  type Request_Slot is limited record
    state         : Slot_State := Slot_Free;
    result        : Sonbal.MCP.Dispatcher.Dispatch_Result;
    process : aliased Sonbal.Process_Execution.Operation;
  end record;

  type Request_Slot_Array is array (Positive range <>) of Request_Slot;
  type Request_Slot_Array_Access is access Request_Slot_Array;

  procedure free_request_slots is new Ada.Unchecked_Deallocation
    (Request_Slot_Array, Request_Slot_Array_Access);

  type Run_Failure is
    (No_Failure,
     Reported_Failure,
     Stdin_Read_Failure,
     Invalid_Read_Count,
     Framing_Failure,
     Oversized_Input,
     Truncated_Input,
     Stdout_Write_Failure,
     Dispatcher_Failure,
     Event_Loop_Failure,
     Process_Binding_Failure,
     Internal_Failure);

  type Input_Handler_Bridge is limited record
    owner : Server_Context_Access := null;
  end record;
  type Input_Handler_Bridge_Access is access all Input_Handler_Bridge;

  type Output_Handler_Bridge is limited record
    owner : Server_Context_Access := null;
  end record;
  type Output_Handler_Bridge_Access is access all Output_Handler_Bridge;

  function input_io_callback
    (source           : access constant Clair.Event_Loop.Source_Handle;
     fd               : Clair.IO.Descriptor;
     events           : Clair.Event_Loop.Event_Mask;
     callback_context : System.Address)
  return Clair.Status.Code
  with Convention => C;

  function output_io_callback
    (source           : access constant Clair.Event_Loop.Source_Handle;
     fd               : Clair.IO.Descriptor;
     events           : Clair.Event_Loop.Event_Mask;
     callback_context : System.Address)
  return Clair.Status.Code
  with Convention => C;

  function address_to_input_bridge is new Ada.Unchecked_Conversion
    (System.Address, Input_Handler_Bridge_Access);
  function address_to_output_bridge is new Ada.Unchecked_Conversion
    (System.Address, Output_Handler_Bridge_Access);

  type Server_Context is limited record
    loop_context     : Clair.Event_Loop.Context_Access := null;
    decoder          : Sonbal.MCP.Stdio_Framing.Decoder
      (Sonbal.MCP.Stdio_Framing.Default_Max_Message_Bytes);
    core             : Sonbal.MCP.Request_Core.Context;
    slots            : Request_Slot_Array_Access := null;
    request_slot_count : Positive range 2 .. MAXIMUM_REQUEST_SLOT_COUNT :=
      Sonbal.Configuration.DEFAULT_MAX_WORK_SLOTS + 1;
    max_work_slot_count : Sonbal.Configuration.Work_Slot_Count :=
      Sonbal.Configuration.DEFAULT_MAX_WORK_SLOTS;
    process_handler  : aliased Process_Completion_Bridge;
    input_handler    : aliased Input_Handler_Bridge;
    input_source : Clair.Event_Loop.Source_Handle
                 := Clair.Event_Loop.NULL_SOURCE;
    input_buffer     : aliased String (1 .. Input_Chunk_Bytes);
    input_length     : Natural range 0 .. Input_Chunk_Bytes := 0;
    input_offset     : Natural range 0 .. Input_Chunk_Bytes := 0;
    input_eof        : Boolean := False;
    accepting_input  : Boolean := True;
    finish_checked   : Boolean := False;
    output_handler   : aliased Output_Handler_Bridge;
    output_source : Clair.Event_Loop.Source_Handle
                  := Clair.Event_Loop.NULL_SOURCE;
    output_buffer    : aliased String (1 .. OUTPUT_BUFFER_BYTES);
    output_length    : Natural range 0 .. OUTPUT_BUFFER_BYTES := 0;
    output_offset    : Natural range 0 .. OUTPUT_BUFFER_BYTES := 0;
    output_slot      : Natural range 0 .. MAXIMUM_REQUEST_SLOT_COUNT := 0;
    output_next_slot : Positive range 1 .. MAXIMUM_REQUEST_SLOT_COUNT := 1;
    shutting_down    : Boolean := False;
    failure          : Run_Failure := No_Failure;
  end record;

  procedure mark_failure
    (server : in out Server_Context;
     value  : Run_Failure)
  is
  begin
    if server.failure = No_Failure then
      server.failure := value;
    end if;

    server.accepting_input := False;
  end mark_failure;

  function find_process_slot
    (server    : in out Server_Context;
     operation : not null Sonbal.Process_Execution.Operation_Access)
  return Natural
  is
  begin
    for index in 1 .. server.request_slot_count loop
      if operation = server.slots(index).process'unchecked_access then
        return index;
      end if;
    end loop;

    return 0;
  end find_process_slot;

  overriding function on_complete
    (handler   : in out Process_Completion_Bridge;
     operation : not null Sonbal.Process_Execution.Operation_Access;
     cause     : Clair.Process.Execution.Event_Loop.Operation_Cause;
     status    : Clair.Status.Code;
     outcome   : Clair.Process.Execution.Result)
  return Clair.Status.Code
  is
    index : Natural;
  begin
    if handler.owner = null then
      return Clair.Status.INTERNAL_ERROR;
    end if;

    declare
      server : Server_Context renames handler.owner.all;
    begin
      index := find_process_slot (server, operation);
      if index = 0 then
        mark_failure (server, Process_Binding_Failure);
        return Clair.Status.OK;
      end if;

      declare
        slot : Request_Slot renames server.slots(index);
      begin
        if slot.state /= Slot_Unresolved then
          mark_failure (server, Process_Binding_Failure);
          return Clair.Status.OK;
        end if;

        if server.shutting_down or else server.failure /= No_Failure then
          slot.state := Slot_Free;
          return Clair.Status.OK;
        end if;

        if cause /= Clair.Process.Execution.Event_Loop.Ordinary_Execution then
          slot.state := Slot_Free;
          mark_failure (server, Process_Binding_Failure);
          return Clair.Status.OK;
        end if;

        Sonbal.MCP.Request_Core.complete_request_execution
          (server.core, slot.result, status, outcome);
        if slot.result.action = Sonbal.MCP.Dispatcher.Write_Response then
          slot.state := Slot_Ready;
        else
          slot.state := Slot_Free;
          mark_failure (server, Dispatcher_Failure);
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

  function initialize_process_slots
    (server : in out Server_Context)
  return Boolean
  is
    status : Clair.Status.Code;
  begin
    if server.loop_context = null then
      return False;
    end if;

    for slot of server.slots(1 .. server.request_slot_count) loop
      status := Sonbal.Process_Execution.initialize
        (slot.process, server.loop_context.all);
      if status /= Clair.Status.OK then
        return False;
      end if;
    end loop;

    return True;
  exception
    when others =>
      return False;
  end initialize_process_slots;

  function cleanup_process_slots
    (server : in out Server_Context)
  return Boolean
  is
    cleanup_ok : Boolean := True;
    dispatched : Boolean := False;
    status     : Clair.Status.Code;

    function has_active_process return Boolean is
    begin
      for slot of server.slots(1 .. server.request_slot_count) loop
        if Sonbal.Process_Execution.is_active(slot.process) then
          return True;
        end if;
      end loop;

      return Sonbal.MCP.Request_Core.is_initialized(server.core) and then
        not Sonbal.MCP.Request_Core.is_idle(server.core);
    end has_active_process;

    function retry_pending_cleanup
      (slot : in out Request_Slot)
    return Boolean
    is
      retry_status : Clair.Status.Code;
    begin
      if not Sonbal.Process_Execution.is_active (slot.process) then
        return True;
      end if;

      for attempt in 1 .. MAXIMUM_CLEANUP_RETRIES loop
        retry_status := Sonbal.Process_Execution.retry (slot.process);
        if retry_status = Clair.Status.OK or else
           retry_status = Clair.Status.INVALID_STATE
        then
          return True;
        end if;
      end loop;

      return False;
    end retry_pending_cleanup;

    function request_cancellation
      (slot : in out Request_Slot)
    return Boolean
    is
      cancel_status : Clair.Status.Code;
    begin
      if not Sonbal.Process_Execution.is_active (slot.process) then
        return True;
      end if;

      for attempt in 1 .. MAXIMUM_CLEANUP_RETRIES loop
        cancel_status := Sonbal.Process_Execution.cancel (slot.process);

        if cancel_status = Clair.Status.OK then
          return True;
        elsif cancel_status = Clair.Status.INVALID_STATE then
          return retry_pending_cleanup (slot);
        elsif not retry_pending_cleanup (slot) then
          return False;
        elsif not Sonbal.Process_Execution.is_active (slot.process) then
          return True;
        end if;
      end loop;

      return not Sonbal.Process_Execution.is_active (slot.process);
    end request_cancellation;

    function finalize_slot
      (slot : in out Request_Slot)
    return Boolean
    is
      finalize_status : Clair.Status.Code;
    begin
      if not Sonbal.Process_Execution.is_initialized (slot.process) then
        return True;
      elsif Sonbal.Process_Execution.is_active (slot.process) then
        return False;
      end if;

      for attempt in 1 .. MAXIMUM_CLEANUP_RETRIES loop
        finalize_status := Sonbal.Process_Execution.finalize (slot.process);
        exit when finalize_status = Clair.Status.OK;
      end loop;

      return not Sonbal.Process_Execution.is_initialized (slot.process);
    end finalize_slot;
  begin
    server.shutting_down := True;
    if Sonbal.MCP.Request_Core.is_initialized(server.core) and then
       not Sonbal.MCP.Request_Core.stop(server.core)
    then
      cleanup_ok := False;
    end if;

    declare
      -- Ready process I/O sources may make Event_Loop.iterate return
      -- immediately, so shutdown progress is bounded by wall-clock time rather
      -- than by an iteration count.
      settle_deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + PROCESS_SETTLE_TIMEOUT;
    begin
      loop
        exit when not has_active_process;

        for slot of server.slots(1 .. server.request_slot_count) loop
          if Sonbal.Process_Execution.is_active (slot.process) then
            if not request_cancellation (slot) or else
               not retry_pending_cleanup (slot)
            then
              cleanup_ok := False;
            end if;
          end if;
        end loop;

        exit when not has_active_process;

        if Ada.Real_Time.Clock >= settle_deadline then
          cleanup_ok := False;
          exit;
        elsif server.loop_context = null then
          cleanup_ok := False;
          exit;
        end if;

        status := Clair.Event_Loop.iterate
          (self       => server.loop_context.all,
           timeout    => PROCESS_SETTLE_WAIT_MS,
           dispatched => dispatched);
        if status /= Clair.Status.OK then
          cleanup_ok := False;
          exit;
        end if;
      end loop;
    end;

    if has_active_process then
      cleanup_ok := False;
    end if;

    for slot of server.slots(1 .. server.request_slot_count) loop
      if not finalize_slot (slot) then
        cleanup_ok := False;
      end if;
    end loop;

    for slot of server.slots(1 .. server.request_slot_count) loop
      if Sonbal.Process_Execution.is_initialized (slot.process) or else
         Sonbal.Process_Execution.is_active (slot.process)
      then
        cleanup_ok := False;
      end if;
    end loop;

    if Sonbal.MCP.Request_Core.is_initialized(server.core) then
      if not Sonbal.MCP.Request_Core.is_idle(server.core) then
        cleanup_ok := False;
      else
        for attempt in 1 .. MAXIMUM_CLEANUP_RETRIES loop
          status := Sonbal.MCP.Request_Core.finalize(server.core);
          exit when status = Clair.Status.OK;
        end loop;
        if Sonbal.MCP.Request_Core.is_initialized(server.core) then
          cleanup_ok := False;
        end if;
      end if;
    end if;

    if cleanup_ok then
      server.process_handler.owner := null;
    end if;

    return cleanup_ok;
  exception
    when others =>
      return False;
  end cleanup_process_slots;

  function first_free_slot (server : Server_Context) return Natural is
  begin
    for index in 1 .. server.request_slot_count loop
      if server.slots(index).state = Slot_Free then
        return index;
      end if;
    end loop;

    return 0;
  end first_free_slot;

  function has_free_slot (server : Server_Context) return Boolean is
    (first_free_slot (server) /= 0);

  function first_ready_slot (server : Server_Context) return Natural is
    index : Positive;
  begin
    for offset in 0 .. server.request_slot_count - 1 loop
      index :=
        ((server.output_next_slot - 1 + offset) mod
           server.request_slot_count) + 1;
      if server.slots(index).state = Slot_Ready then
        return index;
      end if;
    end loop;

    return 0;
  end first_ready_slot;

  procedure clear_output_frame (server : in out Server_Context) is
  begin
    if server.output_length /= 0 then
      server.output_buffer(1 .. server.output_length) :=
        [others => Character'val (0)];
    end if;

    server.output_length := 0;
    server.output_offset := 0;
    server.output_slot := 0;
  end clear_output_frame;

  procedure prepare_output (server : in out Server_Context) is
    index : Natural;
  begin
    if server.failure /= No_Failure or else server.output_slot /= 0 then
      return;
    end if;

    if server.output_length /= 0 or else server.output_offset /= 0 then
      mark_failure (server, Internal_Failure);
      return;
    end if;

    index := first_ready_slot (server);
    if index = 0 then
      return;
    end if;

    declare
      payload : constant String :=
        Sonbal.MCP.Dispatcher.Image (server.slots(index).result.response);
    begin
      if payload'length = 0 or else
         payload'length > Sonbal.MCP.Dispatcher.MAXIMUM_MCP_RESPONSE_BYTES
      then
        mark_failure (server, Dispatcher_Failure);
        return;
      end if;

      server.output_buffer(1 .. payload'length) := payload;
      server.output_buffer(payload'length + 1) :=
        Line_Feed(Line_Feed'first);
      server.output_length := payload'length + 1;
      server.output_offset := 0;
      server.output_slot := index;
      server.output_next_slot :=
        (if index = server.request_slot_count then 1 else index + 1);
    end;
  end prepare_output;

  function has_pending_output (server : Server_Context) return Boolean is
    (server.output_slot /= 0 or else first_ready_slot (server) /= 0);

  procedure discard_ready_slots (server : in out Server_Context) is
  begin
    for slot of server.slots(1 .. server.request_slot_count) loop
      if slot.state = Slot_Ready then
        Sonbal.MCP.Request_Core.mark_transport_response_abandoned
          (server.core, slot.result);
        slot.state := Slot_Free;
      end if;
    end loop;
  end discard_ready_slots;

  procedure attempt_input_read (server : in out Server_Context) is
    read_count : Clair.IO.Byte_Count := 0;
    io_status  : Clair.Status.Code;
  begin
    if server.input_length /= 0 or else
       not server.accepting_input or else
       server.input_eof
    then
      return;
    end if;

    io_status := Clair.IO.read
      (fd     => Standard_Input,
       buffer => server.input_buffer'address,
       count  => Clair.IO.Byte_Count (server.input_buffer'length),
       bytes_read => read_count);

    if Clair.IO.Posix.is_would_block (io_status) then
      return;
    elsif io_status /= Clair.Status.OK then
      mark_failure (server, Stdin_Read_Failure);
    elsif read_count > Clair.IO.Byte_Count(server.input_buffer'length)
    then
      mark_failure (server, Invalid_Read_Count);
    elsif read_count = 0 then
      server.input_eof := True;
      server.accepting_input := False;
    else
      server.input_length := Natural(read_count);
      server.input_offset := 0;
    end if;
  exception
    when others =>
      mark_failure (server, Internal_Failure);
  end attempt_input_read;

  function input_io_callback
    (source           : access constant Clair.Event_Loop.Source_Handle;
     fd               : Clair.IO.Descriptor;
     events           : Clair.Event_Loop.Event_Mask;
     callback_context : System.Address)
  return Clair.Status.Code
  is
    handler : constant Input_Handler_Bridge_Access :=
      address_to_input_bridge (callback_context);
  begin
    if source = null or else handler = null or else handler.owner = null then
      return Clair.Status.INTERNAL_ERROR;
    end if;

    declare
      server : Server_Context renames handler.owner.all;
      io     : constant Clair.Event_Loop.Source_Handle := source.all;
      relevant_events : constant Clair.Event_Loop.Event_Mask :=
        Clair.Event_Loop.EVENT_INPUT or
        Clair.Event_Loop.EVENT_ERROR or
        Clair.Event_Loop.EVENT_HANG_UP;
    begin
      if server.input_source /= io or else fd /= Standard_Input then
        return Clair.Status.INTERNAL_ERROR;
      end if;

      if (events and relevant_events) = 0 or else
         server.input_length /= 0 or else
         not server.accepting_input
      then
        return Clair.Status.OK;
      end if;

      attempt_input_read (server);
      return Clair.Status.OK;
    end;
  exception
    when others =>
      if handler.owner /= null then
        mark_failure (handler.owner.all, Internal_Failure);
      end if;
      return Clair.Status.OK;
  end input_io_callback;

  function output_io_callback
    (source           : access constant Clair.Event_Loop.Source_Handle;
     fd               : Clair.IO.Descriptor;
     events           : Clair.Event_Loop.Event_Mask;
     callback_context : System.Address)
  return Clair.Status.Code
  is
    handler : constant Output_Handler_Bridge_Access :=
      address_to_output_bridge (callback_context);
    write_count : Clair.IO.Byte_Count := 0;
    io_status   : Clair.Status.Code;
  begin
    if source = null or else handler = null or else handler.owner = null then
      return Clair.Status.INTERNAL_ERROR;
    end if;

    declare
      server : Server_Context renames handler.owner.all;
      io     : constant Clair.Event_Loop.Source_Handle := source.all;
      relevant_events : constant Clair.Event_Loop.Event_Mask :=
        Clair.Event_Loop.EVENT_OUTPUT or
        Clair.Event_Loop.EVENT_ERROR or
        Clair.Event_Loop.EVENT_HANG_UP;
    begin
      if server.output_source /= io or else fd /= Standard_Output then
        return Clair.Status.INTERNAL_ERROR;
      end if;

      if (events and relevant_events) = 0 or else server.output_slot = 0 then
        return Clair.Status.OK;
      end if;

      if server.output_length = 0 or else
         server.output_offset >= server.output_length or else
         server.slots(server.output_slot).state /= Slot_Ready
      then
        mark_failure (server, Internal_Failure);
        return Clair.Status.OK;
      end if;

      declare
        remaining : constant Natural :=
          server.output_length - server.output_offset;
      begin
        io_status := Clair.IO.write
          (fd     => fd,
           buffer => server.output_buffer
             (server.output_buffer'first + server.output_offset)'address,
           count  => Clair.IO.Byte_Count (remaining),
           bytes_written => write_count);

        if Clair.IO.Posix.is_would_block (io_status) then
          return Clair.Status.OK;
        elsif io_status /= Clair.Status.OK or else
              write_count = 0 or else
              write_count > Clair.IO.Byte_Count(remaining)
        then
          Sonbal.MCP.Request_Core.mark_transport_response_abandoned
            (server.core, server.slots(server.output_slot).result);
          mark_failure (server, Stdout_Write_Failure);
          return Clair.Status.OK;
        end if;

        server.output_offset :=
          server.output_offset + Natural(write_count);
      end;

      if server.output_offset = server.output_length then
        Sonbal.MCP.Request_Core.mark_transport_response_handoff
          (server.core, server.slots(server.output_slot).result);
        server.slots(server.output_slot).state := Slot_Free;
        clear_output_frame (server);
      end if;

      return Clair.Status.OK;
    end;
  exception
    when others =>
      if handler.owner /= null then
        mark_failure (handler.owner.all, Internal_Failure);
      end if;
      return Clair.Status.OK;
  end output_io_callback;

  function add_input_watch
    (server : in out Server_Context) return Clair.Status.Code
  is
  begin
    if server.input_source /= Clair.Event_Loop.NULL_SOURCE then
      return Clair.Status.OK;
    end if;

    if server.loop_context = null or else
       not server.accepting_input or else
       server.input_eof or else
       server.input_length /= 0 or else
       not has_free_slot (server)
    then
      return Clair.Status.OK;
    end if;

    return Clair.Event_Loop.add_watch
      (self    => server.loop_context.all,
       fd      => Standard_Input,
       events           => Clair.Event_Loop.EVENT_INPUT,
       callback         => input_io_callback'access,
       callback_context => server.input_handler'address,
       source           => server.input_source);
  end add_input_watch;

  function remove_input_watch
    (server : in out Server_Context) return Clair.Status.Code
  is
  begin
    if server.input_source = Clair.Event_Loop.NULL_SOURCE then
      return Clair.Status.OK;
    elsif server.loop_context = null then
      return Clair.Status.INVALID_STATE;
    end if;

    return Clair.Event_Loop.remove
      (server.loop_context.all, server.input_source);
  end remove_input_watch;

  function add_output_watch
    (server : in out Server_Context) return Clair.Status.Code
  is
  begin
    if server.output_source /= Clair.Event_Loop.NULL_SOURCE then
      return Clair.Status.OK;
    end if;

    if server.loop_context = null or else
       server.output_slot = 0 or else
       server.output_length = 0
    then
      return Clair.Status.OK;
    end if;

    return Clair.Event_Loop.add_watch
      (self    => server.loop_context.all,
       fd      => Standard_Output,
       events           => Clair.Event_Loop.EVENT_OUTPUT,
       callback         => output_io_callback'access,
       callback_context => server.output_handler'address,
       source           => server.output_source);
  end add_output_watch;

  function remove_output_watch
    (server : in out Server_Context) return Clair.Status.Code
  is
  begin
    if server.output_source = Clair.Event_Loop.NULL_SOURCE then
      return Clair.Status.OK;
    elsif server.loop_context = null then
      return Clair.Status.INVALID_STATE;
    end if;

    return Clair.Event_Loop.remove
      (server.loop_context.all, server.output_source);
  end remove_output_watch;

  function update_output_watch
    (server : in out Server_Context) return Clair.Status.Code
  is
  begin
    if server.output_slot = 0 then
      return remove_output_watch (server);
    end if;

    return add_output_watch (server);
  end update_output_watch;

  procedure process_input_buffer (server : in out Server_Context) is
    consumed : Natural;
    status   : Sonbal.MCP.Stdio_Framing.Feed_Status;
    index    : Natural;
    processed : Boolean;
  begin
    while server.input_offset < server.input_length and then
          server.failure = No_Failure
    loop
      index := first_free_slot (server);
      exit when index = 0;

      Sonbal.MCP.Stdio_Framing.feed
        (state    => server.decoder,
         data     => server.input_buffer
           (server.input_buffer'first + server.input_offset ..
            server.input_buffer'first + server.input_length - 1),
         consumed => consumed,
         status   => status);

      if consumed = 0 or else
         consumed > server.input_length - server.input_offset
      then
        mark_failure (server, Framing_Failure);
        exit;
      end if;

      server.input_offset := server.input_offset + consumed;

      case status is
        when Sonbal.MCP.Stdio_Framing.Need_More |
             Sonbal.MCP.Stdio_Framing.Discarding_Too_Large =>
          null;

        when Sonbal.MCP.Stdio_Framing.Frame_Ready =>
          Sonbal.MCP.Request_Core.handle
            (server.core,
             Sonbal.MCP.Stdio_Framing.frame (server.decoder),
             server.slots(index).result);

          if server.slots(index).result.action in
            Sonbal.MCP.Dispatcher.Invoke_Run_Process |
            Sonbal.MCP.Dispatcher.Invoke_Read_File
          then
            server.slots(index).state := Slot_Unresolved;
          end if;

          processed := Sonbal.MCP.Request_Core.process_result
            (server.core,
             server.slots(index).result,
             server.slots(index).process,
             server.process_handler'unchecked_access);

          if not processed then
            server.slots(index).state := Slot_Unresolved;
            mark_failure(server, Reported_Failure);
          elsif Sonbal.Process_Execution.is_active
            (server.slots(index).process)
          then
            server.slots(index).state := Slot_Unresolved;
          elsif server.slots(index).result.action =
            Sonbal.MCP.Dispatcher.No_Action
          then
            server.slots(index).state := Slot_Free;
          elsif server.slots(index).result.action =
            Sonbal.MCP.Dispatcher.Write_Response
          then
            server.slots(index).state := Slot_Ready;
          else
            server.slots(index).state := Slot_Unresolved;
            mark_failure(server, Dispatcher_Failure);
          end if;

          Sonbal.MCP.Stdio_Framing.reset (server.decoder);

        when Sonbal.MCP.Stdio_Framing.Frame_Rejected_Too_Large =>
          write_diagnostic ("sonbal: oversized input discarded");
          Sonbal.MCP.Stdio_Framing.reset (server.decoder);
      end case;
    end loop;

    if server.input_offset = server.input_length then
      server.input_offset := 0;
      server.input_length := 0;
    end if;
  end process_input_buffer;

  procedure classify_input_end (server : in out Server_Context) is
    status : Sonbal.MCP.Stdio_Framing.Finish_Status;
  begin
    if server.finish_checked then
      return;
    end if;

    server.finish_checked := True;
    Sonbal.MCP.Stdio_Framing.finish (server.decoder, status);

    case status is
      when Sonbal.MCP.Stdio_Framing.Clean_End =>
        null;
      when Sonbal.MCP.Stdio_Framing.Truncated_Frame =>
        mark_failure (server, Truncated_Input);
      when Sonbal.MCP.Stdio_Framing.Oversize_Frame_At_End =>
        mark_failure (server, Oversized_Input);
    end case;
  end classify_input_end;

  procedure report_failure (failure : Run_Failure) is
  begin
    case failure is
      when No_Failure | Reported_Failure =>
        null;
      when Stdin_Read_Failure =>
        write_diagnostic ("sonbal: stdin read failed");
      when Invalid_Read_Count =>
        write_diagnostic ("sonbal: invalid read count");
      when Framing_Failure =>
        write_diagnostic ("sonbal: framing failure");
      when Oversized_Input =>
        write_diagnostic ("sonbal: oversized input");
      when Truncated_Input =>
        write_diagnostic ("sonbal: truncated input");
      when Stdout_Write_Failure =>
        write_diagnostic ("sonbal: stdout write failed");
      when Dispatcher_Failure =>
        write_diagnostic ("sonbal: dispatcher failure");
      when Event_Loop_Failure =>
        write_diagnostic ("sonbal: event loop failure");
      when Process_Binding_Failure =>
        write_diagnostic ("sonbal: process binding failure");
      when Internal_Failure =>
        write_diagnostic ("sonbal: internal failure");
    end case;
  end report_failure;

  function run_loop
    (loop_context           : aliased in out Clair.Event_Loop.Context;
     max_work_slots         : Sonbal.Configuration.Work_Slot_Count;
     input_source_released  : out Boolean;
     output_source_released : out Boolean)
  return Run_Status
  is
    server           : aliased Server_Context;
    retval           : Clair.Status.Code;
    dispatched       : Boolean;
    result           : Run_Status := Run_Completed;
    slots_releasable : Boolean := False;
  begin
    input_source_released := False;
    output_source_released := False;
    server.request_slot_count := Positive(max_work_slots) + 1;
    begin
      server.slots := new Request_Slot_Array (1 .. server.request_slot_count);
    exception
      when Storage_Error =>
        write_diagnostic ("sonbal: request slot allocation failed");
        return Run_Failed;
    end;
    server.loop_context := loop_context'unchecked_access;
    server.max_work_slot_count := max_work_slots;
    server.process_handler.owner := server'unchecked_access;
    server.input_handler.owner := server'unchecked_access;
    server.output_handler.owner := server'unchecked_access;

    retval := Sonbal.MCP.Request_Core.initialize
      (server.core, loop_context, max_work_slots);
    if retval /= Clair.Status.OK then
      mark_failure(server, Process_Binding_Failure);
    elsif not initialize_process_slots(server) then
      mark_failure(server, Process_Binding_Failure);
    else
      attempt_input_read (server);
      if server.failure = No_Failure then
        retval := add_input_watch (server);
        if retval /= Clair.Status.OK then
          mark_failure (server, Event_Loop_Failure);
        end if;
      end if;
    end if;

    loop
      if shutdown_requested then
        server.shutting_down := True;
        server.input_length := 0;
        server.input_offset := 0;

        retval := remove_input_watch (server);
        if retval /= Clair.Status.OK and then
           server.input_source /= Clair.Event_Loop.NULL_SOURCE
        then
          mark_failure (server, Event_Loop_Failure);
        end if;

        retval := remove_output_watch (server);
        if retval /= Clair.Status.OK and then
           server.output_source /= Clair.Event_Loop.NULL_SOURCE
        then
          mark_failure (server, Event_Loop_Failure);
        end if;

        discard_ready_slots (server);
        clear_output_frame (server);
        exit;
      end if;

      if server.failure = No_Failure and then server.input_length /= 0 then
        retval := remove_input_watch (server);
        if retval /= Clair.Status.OK then
          mark_failure (server, Event_Loop_Failure);
        else
          process_input_buffer (server);
        end if;
      end if;

      if server.failure = No_Failure then
        prepare_output (server);
        if server.failure = No_Failure then
          retval := update_output_watch (server);
          if retval /= Clair.Status.OK then
            if server.output_slot = 0 then
              mark_failure (server, Event_Loop_Failure);
            else
              mark_failure (server, Stdout_Write_Failure);
            end if;
          end if;
        end if;
      end if;

      if server.input_eof and then not server.finish_checked then
        retval := remove_input_watch (server);
        if retval /= Clair.Status.OK then
          mark_failure (server, Event_Loop_Failure);
        end if;
        classify_input_end (server);
        if server.failure = No_Failure then
          server.shutting_down := True;
        end if;
      end if;

      if server.failure /= No_Failure then
        server.shutting_down := True;
        server.input_length := 0;
        server.input_offset := 0;

        retval := remove_input_watch (server);
        if retval /= Clair.Status.OK and then
           server.input_source /= Clair.Event_Loop.NULL_SOURCE
        then
          mark_failure (server, Event_Loop_Failure);
        end if;

        retval := remove_output_watch (server);
        if retval /= Clair.Status.OK and then
           server.output_source /= Clair.Event_Loop.NULL_SOURCE
        then
          mark_failure (server, Event_Loop_Failure);
        end if;

        discard_ready_slots (server);
        clear_output_frame (server);
        exit;
      elsif server.finish_checked and then
            not has_pending_output (server) then
        exit;
      end if;

      if server.failure = No_Failure then
        if server.input_length = 0 and then has_free_slot (server) then
          retval := add_input_watch (server);
          if retval /= Clair.Status.OK then
            mark_failure (server, Event_Loop_Failure);
          end if;
        else
          retval := remove_input_watch (server);
          if retval /= Clair.Status.OK then
            mark_failure (server, Event_Loop_Failure);
          end if;
        end if;
      end if;

      if server.failure = No_Failure and then
         server.input_length /= 0 and then
         has_free_slot (server)
      then
        null;
      else
        retval := Clair.Event_Loop.iterate
          (self       => loop_context,
           timeout    => SHUTDOWN_POLL_INTERVAL,
           dispatched => dispatched);
        if retval /= Clair.Status.OK then
          mark_failure (server, Event_Loop_Failure);
        end if;
      end if;
    end loop;

    for attempt in 1 .. MAXIMUM_CLEANUP_RETRIES loop
      retval := remove_input_watch (server);
      exit when retval = Clair.Status.OK;
    end loop;
    input_source_released :=
      server.input_source = Clair.Event_Loop.NULL_SOURCE;
    if not input_source_released then
      mark_failure (server, Event_Loop_Failure);
    end if;

    for attempt in 1 .. MAXIMUM_CLEANUP_RETRIES loop
      retval := remove_output_watch (server);
      exit when retval = Clair.Status.OK;
    end loop;
    output_source_released :=
      server.output_source = Clair.Event_Loop.NULL_SOURCE;
    if not output_source_released then
      mark_failure (server, Event_Loop_Failure);
    end if;

    clear_output_frame (server);

    if cleanup_process_slots (server) then
      slots_releasable := True;
    else
      write_diagnostic ("sonbal: process cleanup failed");
      result := Run_Failed;
    end if;

    if server.failure /= No_Failure then
      report_failure (server.failure);
      result := Run_Failed;
    end if;

    if slots_releasable then
      free_request_slots (server.slots);
    end if;
    return result;
  exception
    when others =>
      write_diagnostic ("sonbal: internal failure");

      for attempt in 1 .. MAXIMUM_CLEANUP_RETRIES loop
        retval := remove_input_watch (server);
        exit when retval = Clair.Status.OK;
      end loop;
      input_source_released :=
        server.input_source = Clair.Event_Loop.NULL_SOURCE;

      for attempt in 1 .. MAXIMUM_CLEANUP_RETRIES loop
        retval := remove_output_watch (server);
        exit when retval = Clair.Status.OK;
      end loop;
      output_source_released :=
        server.output_source = Clair.Event_Loop.NULL_SOURCE;

      if not input_source_released or else not output_source_released then
        write_diagnostic ("sonbal: event loop failure");
      end if;

      if cleanup_process_slots (server) then
        free_request_slots (server.slots);
      else
        write_diagnostic ("sonbal: process cleanup failed");
      end if;

      return Run_Failed;
  end run_loop;

  function run
    (max_work_slots : Sonbal.Configuration.Work_Slot_Count)
  return Run_Status
  is
    guard                  : Signal_Guard;
    termination_guard      : Signal_Guard;
    interrupt_guard        : Signal_Guard;
    loop_context           : aliased Clair.Event_Loop.Context;
    input_mode             : Clair.IO.Posix.Nonblocking_Mode_State;
    output_mode            : Clair.IO.Posix.Nonblocking_Mode_State;
    loop_initialized       : Boolean := False;
    input_nonblocking      : Boolean := False;
    output_nonblocking     : Boolean := False;
    input_source_released  : Boolean := True;
    output_source_released : Boolean := True;
    result                 : Run_Status := Run_Failed;
    retval                 : Clair.Status.Code;

    function restore_input_mode return Boolean is
    begin
      if not input_nonblocking then
        return True;
      end if;

      for attempt in 1 .. MAXIMUM_CLEANUP_RETRIES loop
        retval := Clair.IO.Posix.restore_nonblocking (input_mode);
        if retval = Clair.Status.OK then
          input_nonblocking := False;
          return True;
        end if;
      end loop;

      return False;
    end restore_input_mode;

    function restore_output_mode return Boolean is
    begin
      if not output_nonblocking then
        return True;
      end if;

      for attempt in 1 .. MAXIMUM_CLEANUP_RETRIES loop
        retval := Clair.IO.Posix.restore_nonblocking (output_mode);
        if retval = Clair.Status.OK then
          output_nonblocking := False;
          return True;
        end if;
      end loop;

      return False;
    end restore_output_mode;

    function restore_stdio_modes return Boolean is
    begin
      if output_nonblocking and then not restore_output_mode then
        return False;
      end if;
      if input_nonblocking and then not restore_input_mode then
        return False;
      end if;

      return True;
    end restore_stdio_modes;

    function finalize_loop return Boolean is
    begin
      if not loop_initialized then
        return True;
      end if;

      for attempt in 1 .. MAXIMUM_CLEANUP_RETRIES loop
        retval := Clair.Event_Loop.finalize (loop_context);
        if retval = Clair.Status.OK then
          loop_initialized := False;
          return True;
        end if;
      end loop;

      return False;
    end finalize_loop;

    function restore_shutdown_guards return Boolean is
      ok : Boolean := True;
    begin
      if interrupt_guard.Installed and then
         not restore_shutdown_guard
           (interrupt_guard, Clair.Unix.Signal.INTERRUPT)
      then
        ok := False;
      end if;
      if termination_guard.Installed and then
         not restore_shutdown_guard
           (termination_guard, Clair.Unix.Signal.TERMINATION)
      then
        ok := False;
      end if;
      return ok;
    end restore_shutdown_guards;
  begin
    shutdown_requested := False;

    if not install_broken_pipe_guard (guard) then
      write_diagnostic ("sonbal: SIGPIPE setup failed");
      return Run_Failed;
    end if;

    retval := Clair.Event_Loop.initialize (loop_context);
    if retval /= Clair.Status.OK then
      write_diagnostic ("sonbal: event loop initialization failed");
      if not restore_broken_pipe_guard (guard) then
        write_diagnostic ("sonbal: SIGPIPE restore failed");
      end if;
      return Run_Failed;
    end if;
    loop_initialized := True;

    if not install_shutdown_guard
      (termination_guard, Clair.Unix.Signal.TERMINATION)
    then
      write_diagnostic ("sonbal: SIGTERM setup failed");
      if not finalize_loop then
        write_diagnostic ("sonbal: event loop finalization failed");
      end if;
      if not restore_broken_pipe_guard (guard) then
        write_diagnostic ("sonbal: SIGPIPE restore failed");
      end if;
      return Run_Failed;
    end if;

    if not install_shutdown_guard
      (interrupt_guard, Clair.Unix.Signal.INTERRUPT)
    then
      write_diagnostic ("sonbal: SIGINT setup failed");
      if not finalize_loop then
        write_diagnostic ("sonbal: event loop finalization failed");
      end if;
      if not restore_shutdown_guards then
        write_diagnostic ("sonbal: shutdown signal restore failed");
      end if;
      if not restore_broken_pipe_guard (guard) then
        write_diagnostic ("sonbal: SIGPIPE restore failed");
      end if;
      return Run_Failed;
    end if;

    retval := Clair.IO.Posix.enter_nonblocking (Standard_Input, input_mode);
    if retval /= Clair.Status.OK then
      write_diagnostic ("sonbal: stdin nonblocking setup failed");
      if not finalize_loop then
        write_diagnostic ("sonbal: event loop finalization failed");
      end if;
      if not restore_shutdown_guards then
        write_diagnostic ("sonbal: shutdown signal restore failed");
      end if;
      if not restore_broken_pipe_guard (guard) then
        write_diagnostic ("sonbal: SIGPIPE restore failed");
      end if;
      return Run_Failed;
    end if;
    input_nonblocking := True;

    retval := Clair.IO.Posix.enter_nonblocking (Standard_Output, output_mode);
    if retval /= Clair.Status.OK then
      write_diagnostic ("sonbal: stdout nonblocking setup failed");
      if not restore_input_mode then
        write_diagnostic ("sonbal: stdin nonblocking restore failed");
      end if;
      if not finalize_loop then
        write_diagnostic ("sonbal: event loop finalization failed");
      end if;
      if not restore_shutdown_guards then
        write_diagnostic ("sonbal: shutdown signal restore failed");
      end if;
      if not restore_broken_pipe_guard (guard) then
        write_diagnostic ("sonbal: SIGPIPE restore failed");
      end if;
      return Run_Failed;
    end if;
    output_nonblocking := True;

    result := run_loop
      (loop_context,
       max_work_slots,
       input_source_released,
       output_source_released);

    if input_source_released and then output_source_released and then
       not restore_stdio_modes
    then
      write_diagnostic ("sonbal: stdio nonblocking restore failed");
      result := Run_Failed;
    end if;

    if not finalize_loop then
      write_diagnostic ("sonbal: event loop finalization failed");
      if not restore_shutdown_guards then
        write_diagnostic ("sonbal: shutdown signal restore failed");
      end if;
      if not restore_broken_pipe_guard (guard) then
        write_diagnostic ("sonbal: SIGPIPE restore failed");
      end if;
      return Run_Failed;
    end if;

    if not restore_shutdown_guards then
      write_diagnostic ("sonbal: shutdown signal restore failed");
      result := Run_Failed;
    end if;

    if (input_nonblocking or else output_nonblocking) and then
       not restore_stdio_modes
    then
      write_diagnostic ("sonbal: stdio nonblocking restore failed");
      result := Run_Failed;
    end if;

    if not restore_broken_pipe_guard (guard) then
      write_diagnostic ("sonbal: SIGPIPE restore failed");
      return Run_Failed;
    end if;

    return result;
  exception
    when others =>
      write_diagnostic ("sonbal: startup failure");
      if loop_initialized and then not finalize_loop then
        write_diagnostic ("sonbal: event loop finalization failed");
      end if;
      if not loop_initialized and then
         (input_nonblocking or else output_nonblocking) and then
         not restore_stdio_modes
      then
        write_diagnostic ("sonbal: stdio nonblocking restore failed");
      end if;
      if not restore_shutdown_guards then
        write_diagnostic ("sonbal: shutdown signal restore failed");
      end if;
      if not restore_broken_pipe_guard (guard) then
        write_diagnostic ("sonbal: SIGPIPE restore failed");
      end if;
      return Run_Failed;
  end run;
end Sonbal.MCP.Stdio_Server;
