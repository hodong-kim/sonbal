-- ============================================================================
-- sonbal_connector_host_fixture.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Ada.Command_Line;
with Ada.Text_IO;
with Clair.Errno;
with Clair.Event_Loop;
with Clair.IO;
with Clair.Status;
with Interfaces.C;
with System;
with Sonbal.Configuration;
with Sonbal.Connector_Host;
with Sonbal_Connector_Host_Test_Callbacks;

procedure Sonbal_Connector_Host_Fixture is

  use type Clair.Event_Loop.Source_Handle;
  use type Clair.IO.Descriptor;
  use type Clair.Status.Code;
  use type Interfaces.C.int;

  O_RDONLY : constant Interfaces.C.int := 0;

  function c_open
    (path  : Interfaces.C.char_array;
     flags : Interfaces.C.int)
  return Interfaces.C.int
  with Import, Convention => C, External_Name => "open";

  function watch_fault_begin_c
    (read_fd  : access Interfaces.C.int;
     write_fd : access Interfaces.C.int)
  return Interfaces.C.int
  with Import, Convention => C,
       External_Name => "sonbal_connector_host_test_watch_begin";

  function watch_fault_end_c return Interfaces.C.int
  with Import, Convention => C,
       External_Name => "sonbal_connector_host_test_watch_end";

  procedure fail (message : String) is
  begin
    Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, message);
    Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
    raise Program_Error with message;
  end fail;

  function open_read_only (path : String) return Clair.IO.Descriptor is
    native : constant Interfaces.C.int :=
      c_open (Interfaces.C.To_C (path), O_RDONLY);
  begin
    if native < 0 then
      fail ("cannot open startup fixture input: " & path);
    end if;
    return Clair.IO.Descriptor(native);
  end open_read_only;

  procedure close_if_needed (fd : in out Clair.IO.Descriptor) is
    status : Clair.Status.Code;
  begin
    if fd = Clair.IO.INVALID_DESCRIPTOR then
      return;
    end if;

    status := Clair.IO.close (fd);
    if status /= Clair.Status.OK then
      fail ("fixture descriptor cleanup failed");
    end if;
    fd := Clair.IO.INVALID_DESCRIPTOR;
  end close_if_needed;

  scenario : constant String := Ada.Command_Line.Argument (1);
  plugin_path : constant String := Ada.Command_Line.Argument (2);
  configuration_path : constant String := Ada.Command_Line.Argument (3);

  event_loop : aliased Clair.Event_Loop.Context;
  host : aliased Sonbal.Connector_Host.Context;
  configuration_fd : Clair.IO.Descriptor := Clair.IO.INVALID_DESCRIPTOR;
  credential_fd : Clair.IO.Descriptor := Clair.IO.INVALID_DESCRIPTOR;
  status : Clair.Status.Code;
  dispatched : Boolean := False;

  watch_read_raw : aliased Interfaces.C.int := -1;
  watch_write_raw : aliased Interfaces.C.int := -1;
  watch_read_fd : Clair.IO.Descriptor := Clair.IO.INVALID_DESCRIPTOR;
  watch_write_fd : Clair.IO.Descriptor := Clair.IO.INVALID_DESCRIPTOR;
  watch_source : Clair.Event_Loop.Source_Handle := Clair.Event_Loop.NULL_SOURCE;
  watch_environment_active : Boolean := False;

  function cleanup_watch_fault return Clair.Status.Code is
    result : Clair.Status.Code := Clair.Status.OK;
    next   : Clair.Status.Code;
  begin
    if watch_source /= Clair.Event_Loop.NULL_SOURCE then
      result := Clair.Event_Loop.remove (event_loop, watch_source);
    end if;

    if watch_environment_active then
      if watch_fault_end_c /= 0 and then result = Clair.Status.OK then
        result := Clair.Status.INTERNAL_ERROR;
      end if;
      watch_environment_active := False;
    end if;

    if watch_source /= Clair.Event_Loop.NULL_SOURCE then
      return result;
    end if;

    if watch_read_fd /= Clair.IO.INVALID_DESCRIPTOR then
      next := Clair.IO.close (watch_read_fd);
      if next = Clair.Status.OK then
        watch_read_fd := Clair.IO.INVALID_DESCRIPTOR;
      elsif result = Clair.Status.OK then
        result := next;
      end if;
    end if;

    if watch_write_fd /= Clair.IO.INVALID_DESCRIPTOR then
      next := Clair.IO.close (watch_write_fd);
      if next = Clair.Status.OK then
        watch_write_fd := Clair.IO.INVALID_DESCRIPTOR;
      elsif result = Clair.Status.OK then
        result := next;
      end if;
    end if;

    return result;
  end cleanup_watch_fault;

begin
  if Ada.Command_Line.Argument_Count /= 3 then
    fail ("usage: fixture SCENARIO PLUGIN CONFIGURATION");
  end if;

  status := Clair.Event_Loop.initialize (event_loop);
  if status /= Clair.Status.OK then
    fail ("event loop initialization failed");
  end if;

  configuration_fd := open_read_only (configuration_path);
  credential_fd := open_read_only ("/dev/null");

  if scenario = "watch-fail" then
    if watch_fault_begin_c
      (watch_read_raw'access, watch_write_raw'access) /= 0
    then
      fail ("cannot prepare duplicate wakeup watch");
    end if;

    watch_environment_active := True;
    if watch_read_raw < 0 or else watch_write_raw < 0 then
      fail ("duplicate wakeup helper returned an invalid descriptor");
    end if;

    watch_read_fd := Clair.IO.Descriptor(watch_read_raw);
    watch_write_fd := Clair.IO.Descriptor(watch_write_raw);

    status := Clair.Event_Loop.add_watch
      (self             => event_loop,
       fd               => watch_read_fd,
       events           => Clair.Event_Loop.EVENT_INPUT,
       callback         =>
         Sonbal_Connector_Host_Test_Callbacks.watch_fault'access,
       callback_context => System.NULL_ADDRESS,
       source           => watch_source);
    if status /= Clair.Status.OK then
      fail ("cannot register duplicate wakeup control watch");
    end if;
  end if;

  status := Sonbal.Connector_Host.initialize
    (self             => host,
     event_loop       => event_loop,
     plugin_path      => plugin_path,
     configuration_fd => configuration_fd,
     credential_fd    => credential_fd,
     max_work_slots   => Sonbal.Configuration.DEFAULT_MAX_WORK_SLOTS);

  if scenario = "watch-fail" then
    declare
      cleanup_status : constant Clair.Status.Code := cleanup_watch_fault;
    begin
      if cleanup_status /= Clair.Status.OK then
        fail ("duplicate wakeup watch cleanup failed");
      end if;
    end;
  end if;

  if configuration_fd /= Clair.IO.INVALID_DESCRIPTOR or else
     credential_fd /= Clair.IO.INVALID_DESCRIPTOR
  then
    fail ("host did not consume startup descriptors");
  end if;

  if scenario = "missing-symbol" then
    if status /= Clair.Status.SYMBOL_LOOKUP_ERROR or else
       Sonbal.Connector_Host.is_initialized (host)
    then
      fail ("missing-symbol rejection contract failed");
    end if;

  elsif scenario = "bad-abi" then
    if status /= Clair.Status.CONTRACT_VIOLATION or else
       Sonbal.Connector_Host.is_initialized (host)
    then
      fail ("bad-ABI rejection contract failed");
    end if;

  elsif scenario = "init-fail" then
    if status /= Clair.Status.CALLBACK_FAILED or else
       Sonbal.Connector_Host.is_initialized (host)
    then
      fail ("initialize failure rollback contract failed");
    end if;

  elsif scenario = "invalid-wakeup" then
    if status /= Clair.Status.CONTRACT_VIOLATION or else
       Sonbal.Connector_Host.is_initialized (host)
    then
      fail ("invalid wakeup rollback contract failed");
    end if;

  elsif scenario = "watch-fail" then
    if status /= Clair.Status.from_errno (Clair.Errno.EEXIST) or else
       Sonbal.Connector_Host.is_initialized (host)
    then
      fail ("wakeup registration failure rollback contract failed");
    end if;

  elsif scenario = "finalize-fail" then
    if status /= Clair.Status.OK or else
       not Sonbal.Connector_Host.is_initialized (host)
    then
      fail ("finalize-fail fixture initialization failed");
    end if;

    status := Sonbal.Connector_Host.finalize (host);
    if status /= Clair.Status.CALLBACK_FAILED or else
       not Sonbal.Connector_Host.has_failed (host)
    then
      fail ("finalize failure was not retained fail-closed");
    end if;

  elsif scenario = "start-fail" then
    if status /= Clair.Status.OK or else
       not Sonbal.Connector_Host.is_initialized (host)
    then
      fail ("start-fail fixture initialization failed");
    end if;

    status := Sonbal.Connector_Host.start (host);
    if status /= Clair.Status.CALLBACK_FAILED or else
       Sonbal.Connector_Host.is_started (host)
    then
      fail ("start failure rollback contract failed");
    end if;

    status := Sonbal.Connector_Host.finalize (host);
    if status /= Clair.Status.OK then
      fail ("start-failure finalization failed");
    end if;

  elsif scenario = "good" then
    if status /= Clair.Status.OK or else
       not Sonbal.Connector_Host.is_initialized (host)
    then
      fail ("good fixture initialization failed");
    end if;

    status := Sonbal.Connector_Host.start (host);
    if status /= Clair.Status.OK or else
       not Sonbal.Connector_Host.is_started (host)
    then
      fail ("connector start failed");
    end if;

    status := Sonbal.Connector_Host.begin_shutdown (host);
    if status /= Clair.Status.OK then
      fail ("connector shutdown transition failed");
    end if;

    for attempt in 1 .. 8 loop
      exit when Sonbal.Connector_Host.shutdown_complete (host);

      status := Clair.Event_Loop.iterate
        (self       => event_loop,
         timeout    => 250,
         dispatched => dispatched);
      if status /= Clair.Status.OK then
        fail ("event loop iteration failed");
      end if;
    end loop;

    if not Sonbal.Connector_Host.shutdown_complete (host) or else
       Sonbal.Connector_Host.has_failed (host)
    then
      fail ("connector did not reach clean shutdown completion");
    end if;

    status := Sonbal.Connector_Host.finalize (host);
    if status /= Clair.Status.OK then
      fail ("connector finalization failed");
    end if;

  else
    fail ("unknown fixture scenario: " & scenario);
  end if;

  status := Clair.Event_Loop.finalize (event_loop);
  if status /= Clair.Status.OK then
    fail ("event loop finalization failed");
  end if;

  Ada.Text_IO.Put_Line ("[PASS] connector host " & scenario);
  Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);

exception
  when Program_Error =>
    declare
      ignored_status : constant Clair.Status.Code := cleanup_watch_fault;
      pragma Unreferenced (ignored_status);
    begin
      null;
    end;
    close_if_needed (configuration_fd);
    close_if_needed (credential_fd);
end Sonbal_Connector_Host_Fixture;
