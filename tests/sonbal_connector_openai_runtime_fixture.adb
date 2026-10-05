-- ============================================================================
-- sonbal_connector_openai_runtime_fixture.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Ada.Command_Line;
with Ada.Text_IO;
with Clair.Event_Loop;
with Clair.IO;
with Clair.Status;
with Interfaces.C;
with Sonbal.Configuration;
with Sonbal.Connector_Server;

procedure Sonbal_Connector_OpenAI_Runtime_Fixture is

  use type Clair.IO.Descriptor;
  use type Clair.Status.Code;
  use type Interfaces.C.int;

  O_RDONLY : constant Interfaces.C.int := 0;
  RUNTIME_WORK_SLOTS : constant Sonbal.Configuration.Work_Slot_Count := 16;

  function c_open
    (path  : Interfaces.C.char_array;
     flags : Interfaces.C.int)
  return Interfaces.C.int
  with Import, Convention => C, External_Name => "open";

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
      fail ("cannot open OpenAI runtime fixture input: " & path);
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
      fail ("OpenAI runtime fixture descriptor cleanup failed");
    end if;
    fd := Clair.IO.INVALID_DESCRIPTOR;
  end close_if_needed;

  plugin_path : constant String := Ada.Command_Line.Argument (1);
  configuration_path : constant String := Ada.Command_Line.Argument (2);
  credential_path : constant String := Ada.Command_Line.Argument (3);

  event_loop : aliased Clair.Event_Loop.Context;
  server : aliased Sonbal.Connector_Server.Context;
  configuration_fd : Clair.IO.Descriptor := Clair.IO.INVALID_DESCRIPTOR;
  credential_fd : Clair.IO.Descriptor := Clair.IO.INVALID_DESCRIPTOR;
  status : Clair.Status.Code;
  dispatched : Boolean := False;
  observed_progress : Boolean := False;
  settled_request : Boolean := False;

begin
  if Ada.Command_Line.Argument_Count /= 3 then
    fail ("usage: fixture PLUGIN CONFIGURATION CREDENTIAL");
  end if;

  status := Clair.Event_Loop.initialize (event_loop);
  if status /= Clair.Status.OK then
    fail ("event loop initialization failed");
  end if;

  configuration_fd := open_read_only (configuration_path);
  credential_fd := open_read_only (credential_path);

  status := Sonbal.Connector_Server.initialize
    (self             => server,
     event_loop       => event_loop,
     plugin_path      => plugin_path,
     configuration_fd => configuration_fd,
     credential_fd    => credential_fd,
     max_work_slots   => RUNTIME_WORK_SLOTS);
  if status /= Clair.Status.OK then
    fail ("OpenAI runtime server initialization failed: " & Clair.Status.Code'Image (status));
  end if;

  if configuration_fd /= Clair.IO.INVALID_DESCRIPTOR or else
     credential_fd /= Clair.IO.INVALID_DESCRIPTOR
  then
    fail ("OpenAI runtime server did not consume startup descriptors");
  end if;

  status := Sonbal.Connector_Server.start (server);
  if status /= Clair.Status.OK then
    fail ("OpenAI runtime server start failed");
  end if;

  for attempt in 1 .. 120 loop
    status := Clair.Event_Loop.iterate
      (self       => event_loop,
       timeout    => 50,
       dispatched => dispatched);
    if status /= Clair.Status.OK then
      fail ("OpenAI runtime event loop iteration failed");
    end if;

    observed_progress := observed_progress or dispatched;

    if Sonbal.Connector_Server.has_failed (server) then
      fail ("OpenAI runtime server reported request-flow failure");
    end if;

    if observed_progress and then
       Sonbal.Connector_Server.active_request_count (server) = 0
    then
      settled_request := True;
      exit;
    end if;
  end loop;

  if not settled_request then
    fail ("OpenAI runtime JSON-RPC request did not settle");
  end if;

  --  Let the provider-local session-termination acknowledgement and response
  --  POST complete before asking the worker to stop its next long poll.
  for attempt in 1 .. 20 loop
    status := Clair.Event_Loop.iterate
      (self       => event_loop,
       timeout    => 50,
       dispatched => dispatched);
    if status /= Clair.Status.OK then
      fail ("OpenAI runtime post-settlement iteration failed");
    end if;

    if Sonbal.Connector_Server.has_failed (server) then
      fail ("OpenAI runtime server failed after request settlement");
    end if;
  end loop;

  status := Sonbal.Connector_Server.begin_shutdown (server);
  if status /= Clair.Status.OK then
    fail ("OpenAI runtime shutdown transition failed");
  end if;

  for attempt in 1 .. 80 loop
    exit when Sonbal.Connector_Server.is_settled (server);

    status := Clair.Event_Loop.iterate
      (self       => event_loop,
       timeout    => 50,
       dispatched => dispatched);
    if status /= Clair.Status.OK then
      fail ("OpenAI runtime shutdown iteration failed");
    end if;
  end loop;

  if not Sonbal.Connector_Server.is_settled (server) or else
     Sonbal.Connector_Server.has_failed (server)
  then
    fail ("OpenAI runtime server did not settle cleanly");
  end if;

  status := Sonbal.Connector_Server.finalize (server);
  if status /= Clair.Status.OK then
    fail ("OpenAI runtime server finalization failed");
  end if;

  status := Clair.Event_Loop.finalize (event_loop);
  if status /= Clair.Status.OK then
    fail ("OpenAI runtime event loop finalization failed");
  end if;

  Ada.Text_IO.Put_Line ("[PASS] OpenAI connector runtime lifecycle");
  Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);

exception
  when Program_Error =>
    close_if_needed (configuration_fd);
    close_if_needed (credential_fd);
end Sonbal_Connector_OpenAI_Runtime_Fixture;
