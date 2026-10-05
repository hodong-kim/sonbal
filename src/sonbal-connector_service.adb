-- ============================================================================
-- sonbal-connector_service.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Ada.Interrupts.Names;
with Ada.Real_Time;
with Clair.Event_Loop;
with Clair.Log;
with Clair.Status;
with Clair.Unix.File;
with Clair.Unix.Signal;
with Sonbal.Connector_Server;

package body Sonbal.Connector_Service is

  use type Ada.Real_Time.Time;
  use type Clair.IO.Descriptor;
  use type Clair.Status.Code;

  MAXIMUM_CLEANUP_RETRIES : constant Positive := 3;
  IDLE_POLL_INTERVAL : constant Clair.Event_Loop.Milliseconds := 250;
  SHUTDOWN_POLL_INTERVAL : constant Clair.Event_Loop.Milliseconds := 50;
  SHUTDOWN_TIMEOUT : constant Ada.Real_Time.Time_Span :=
    Ada.Real_Time.Seconds (10);

  shutdown_requested : Boolean := False
    with Atomic;

  type Signal_Guard is record
    previous  : Clair.Unix.Signal.Action;
    installed : Boolean := False;
  end record;

  procedure shutdown_signal_handler (signo : Clair.Unix.Signal.Number);
  pragma Convention (C, shutdown_signal_handler);

  procedure shutdown_signal_handler
    (signo : Clair.Unix.Signal.Number)
  is
    pragma Unreferenced (signo);
  begin
    shutdown_requested := True;
  end shutdown_signal_handler;

  procedure write_diagnostic (message : String) is
  begin
    Clair.Log.write
      (severity     => Clair.Log.Error,
       message      => message,
       destinations => Clair.Log.Native_Diagnostic);
  exception
    when others =>
      null;
  end write_diagnostic;

  function install_shutdown_guard
    (guard : in out Signal_Guard;
     signo : Clair.Unix.Signal.Number)
  return Boolean
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
       previous_signal_action => guard.previous);
    if status /= Clair.Status.OK then
      return False;
    end if;

    guard.installed := True;
    return True;
  end install_shutdown_guard;

  function restore_shutdown_guard
    (guard : in out Signal_Guard;
     signo : Clair.Unix.Signal.Number)
  return Boolean
  is
    status : Clair.Status.Code := Clair.Status.INTERNAL_ERROR;
  begin
    if not guard.installed then
      return True;
    end if;

    for attempt in 1 .. MAXIMUM_CLEANUP_RETRIES loop
      declare
        previous : constant Clair.Unix.Signal.Action := guard.previous;
      begin
        status := Clair.Unix.Signal.replace_process_action
          (signal_number => signo,
           signal_action          => previous,
           previous_signal_action => guard.previous);
      end;
      exit when status = Clair.Status.OK;
    end loop;

    if status = Clair.Status.OK then
      guard.installed := False;
      return True;
    end if;
    return False;
  end restore_shutdown_guard;

  function run
    (plugin_path        : String;
     configuration_path : String;
     credential_fd      : in out Clair.IO.Descriptor;
     max_work_slots     : Sonbal.Configuration.Work_Slot_Count)
  return Run_Result
  is
    loop_context : aliased Clair.Event_Loop.Context;
    server       : aliased Sonbal.Connector_Server.Context;
    configuration_fd : Clair.IO.Descriptor := Clair.IO.INVALID_DESCRIPTOR;
    termination_guard : Signal_Guard;
    interrupt_guard   : Signal_Guard;
    loop_initialized  : Boolean := False;
    server_initialized : Boolean := False;
    server_started     : Boolean := False;
    failed             : Boolean := False;
    status             : Clair.Status.Code;
    dispatched         : Boolean := False;

    procedure note_failure (message : String) is
    begin
      write_diagnostic (message);
      failed := True;
    end note_failure;

    procedure close_if_needed (fd : in out Clair.IO.Descriptor) is
      close_status : Clair.Status.Code;
    begin
      if fd = Clair.IO.INVALID_DESCRIPTOR then
        return;
      end if;

      close_status := Clair.IO.close (fd);
      if close_status /= Clair.Status.OK then
        note_failure ("sonbal: connector startup descriptor cleanup failed");
      end if;
      fd := Clair.IO.INVALID_DESCRIPTOR;
    end close_if_needed;

    procedure restore_signals is
    begin
      if interrupt_guard.installed and then
         not restore_shutdown_guard
           (interrupt_guard,
            Clair.Unix.Signal.Number (Ada.Interrupts.Names.SIGINT))
      then
        note_failure ("sonbal: connector SIGINT restore failed");
      end if;

      if termination_guard.installed and then
         not restore_shutdown_guard
           (termination_guard, Clair.Unix.Signal.TERMINATION)
      then
        note_failure ("sonbal: connector SIGTERM restore failed");
      end if;
    end restore_signals;

  begin
    shutdown_requested := False;

    if plugin_path'length = 0 or else
       configuration_path'length = 0 or else
       credential_fd = Clair.IO.INVALID_DESCRIPTOR
    then
      write_diagnostic ("sonbal: invalid connector startup contract");
      return Run_Failed;
    end if;

    status := Clair.Unix.File.open
      (path             => configuration_path,
       requested_access => Clair.Unix.File.Read_Only,
       options          =>
         [Clair.Unix.File.Close_On_Exec => True, others => False],
       opened_descriptor => configuration_fd);
    if status /= Clair.Status.OK then
      close_if_needed (credential_fd);
      write_diagnostic ("sonbal: connector configuration open failed");
      return Run_Failed;
    end if;

    status := Clair.Event_Loop.initialize (loop_context);
    if status /= Clair.Status.OK then
      close_if_needed (configuration_fd);
      close_if_needed (credential_fd);
      write_diagnostic ("sonbal: connector Event Loop initialization failed");
      return Run_Failed;
    end if;
    loop_initialized := True;

    if not install_shutdown_guard
      (termination_guard, Clair.Unix.Signal.TERMINATION)
    then
      note_failure ("sonbal: connector SIGTERM setup failed");
    elsif not install_shutdown_guard
      (interrupt_guard,
       Clair.Unix.Signal.Number (Ada.Interrupts.Names.SIGINT))
    then
      note_failure ("sonbal: connector SIGINT setup failed");
    end if;

    if not failed then
      status := Sonbal.Connector_Server.initialize
        (self             => server,
         event_loop       => loop_context,
         plugin_path      => plugin_path,
         configuration_fd => configuration_fd,
         credential_fd    => credential_fd,
         max_work_slots   => max_work_slots);
      if status /= Clair.Status.OK then
        note_failure ("sonbal: connector server initialization failed");
      else
        server_initialized := True;
      end if;
    end if;

    close_if_needed (configuration_fd);
    close_if_needed (credential_fd);

    if server_initialized and then not failed then
      status := Sonbal.Connector_Server.start (server);
      if status /= Clair.Status.OK then
        note_failure ("sonbal: connector server start failed");
      else
        server_started := True;
      end if;
    end if;

    while server_started and then
          not shutdown_requested and then
          not Sonbal.Connector_Server.has_failed (server)
    loop
      status := Clair.Event_Loop.iterate
        (self       => loop_context,
         timeout    => IDLE_POLL_INTERVAL,
         dispatched => dispatched);
      if status /= Clair.Status.OK then
        note_failure ("sonbal: connector Event Loop iteration failed");
      end if;
      exit when failed;
    end loop;

    if server_started and then
       Sonbal.Connector_Server.has_failed (server)
    then
      note_failure ("sonbal: connector runtime failed");
    end if;

    if server_started then
      status := Sonbal.Connector_Server.begin_shutdown (server);
      if status /= Clair.Status.OK then
        note_failure ("sonbal: connector shutdown request failed");
      else
        declare
          deadline : constant Ada.Real_Time.Time :=
            Ada.Real_Time.Clock + SHUTDOWN_TIMEOUT;
        begin
          while not Sonbal.Connector_Server.is_settled (server) and then
                Ada.Real_Time.Clock < deadline
          loop
            status := Clair.Event_Loop.iterate
              (self       => loop_context,
               timeout    => SHUTDOWN_POLL_INTERVAL,
               dispatched => dispatched);
            if status /= Clair.Status.OK then
              note_failure ("sonbal: connector shutdown iteration failed");
              exit;
            end if;
          end loop;

          if not Sonbal.Connector_Server.is_settled (server) then
            note_failure ("sonbal: connector shutdown did not settle");
          end if;
        end;
      end if;
    end if;

    if server_initialized and then
       (not server_started or else Sonbal.Connector_Server.is_settled (server))
    then
      status := Sonbal.Connector_Server.finalize (server);
      if status /= Clair.Status.OK then
        note_failure ("sonbal: connector server finalization failed");
      end if;
    end if;

    restore_signals;

    if loop_initialized then
      status := Clair.Event_Loop.finalize (loop_context);
      if status /= Clair.Status.OK then
        note_failure ("sonbal: connector Event Loop finalization failed");
      end if;
    end if;

    return (if failed then Run_Failed else Run_Completed);
  exception
    when others =>
      close_if_needed (configuration_fd);
      close_if_needed (credential_fd);
      restore_signals;
      if loop_initialized then
        status := Clair.Event_Loop.finalize (loop_context);
      end if;
      return Run_Failed;
  end run;

end Sonbal.Connector_Service;
