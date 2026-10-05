-- ============================================================================
-- sonbal_connector_server_fixture.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Ada.Command_Line;
with Ada.Real_Time;
with Ada.Text_IO;
with Clair.Event_Loop;
with Clair.IO;
with Clair.Status;
with Interfaces.C;
with Sonbal.Configuration;
with Sonbal.Connector_Server;

procedure Sonbal_Connector_Server_Fixture is

  use type Ada.Real_Time.Time;
  use type Clair.IO.Descriptor;
  use type Clair.Status.Code;
  use type Interfaces.C.int;

  O_RDONLY : constant Interfaces.C.int := 0;
  REQUEST_FLOW_TIMEOUT : constant Ada.Real_Time.Time_Span :=
    Ada.Real_Time.Seconds (10);
  SHUTDOWN_TIMEOUT : constant Ada.Real_Time.Time_Span :=
    Ada.Real_Time.Seconds (10);

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
      fail ("cannot open connector-server fixture input: " & path);
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
  server : aliased Sonbal.Connector_Server.Context;
  configuration_fd : Clair.IO.Descriptor := Clair.IO.INVALID_DESCRIPTOR;
  credential_fd : Clair.IO.Descriptor := Clair.IO.INVALID_DESCRIPTOR;
  status : Clair.Status.Code;
  dispatched : Boolean := False;
  observed_progress : Boolean := False;
  request_deadline : Ada.Real_Time.Time;
  shutdown_deadline : Ada.Real_Time.Time;

begin
  if Ada.Command_Line.Argument_Count /= 3 then
    fail ("usage: fixture SCENARIO PLUGIN CONFIGURATION");
  end if;

  if scenario not in
    "request" | "backpressure" | "backpressure-abandonment" |
    "abandonment" | "shutdown-active" | "finalize-retry" |
    "notification" | "server-owned-job"
  then
    fail ("unknown connector-server fixture scenario: " & scenario);
  end if;

  status := Clair.Event_Loop.initialize (event_loop);
  if status /= Clair.Status.OK then
    fail ("event loop initialization failed");
  end if;

  configuration_fd := open_read_only (configuration_path);
  credential_fd := open_read_only ("/dev/null");

  status := Sonbal.Connector_Server.initialize
    (self             => server,
     event_loop       => event_loop,
     plugin_path      => plugin_path,
     configuration_fd => configuration_fd,
     credential_fd    => credential_fd,
     max_work_slots   => Sonbal.Configuration.DEFAULT_MAX_WORK_SLOTS);
  if status /= Clair.Status.OK then
    fail
      ("connector server initialization failed: " &
       Clair.Status.Code'Image (status));
  end if;

  if configuration_fd /= Clair.IO.INVALID_DESCRIPTOR or else
     credential_fd /= Clair.IO.INVALID_DESCRIPTOR
  then
    fail ("connector server did not consume startup descriptors");
  end if;

  status := Sonbal.Connector_Server.start (server);
  if status /= Clair.Status.OK then
    fail ("connector server start failed");
  end if;

  if scenario /= "finalize-retry" then
    request_deadline := Ada.Real_Time.clock + REQUEST_FLOW_TIMEOUT;
    while Ada.Real_Time.clock < request_deadline loop
      status := Clair.Event_Loop.iterate
        (self       => event_loop,
         timeout    => 100,
         dispatched => dispatched);
      if status /= Clair.Status.OK then
        fail ("request-flow event loop iteration failed");
      end if;

      observed_progress := observed_progress or dispatched;

      if Sonbal.Connector_Server.has_failed (server) then
        fail ("connector server reported request-flow failure");
      end if;

      if scenario = "shutdown-active" then
        exit when observed_progress and then
          Sonbal.Connector_Server.active_request_count (server) > 0;
      else
        exit when observed_progress and then
          Sonbal.Connector_Server.active_request_count (server) = 0;
      end if;
    end loop;

    if not observed_progress then
      fail ("connector request flow did not make progress");
    elsif scenario = "server-owned-job" then
      if Sonbal.Connector_Server.active_request_count (server) /= 0 or else
         Sonbal.Connector_Server.active_execution_count (server) = 0
      then
        fail ("server-owned job did not outlive its connector request");
      end if;
    elsif scenario = "shutdown-active" then
      if Sonbal.Connector_Server.active_request_count (server) = 0 then
        fail ("shutdown-active request did not remain live");
      end if;
    elsif Sonbal.Connector_Server.active_request_count (server) /= 0 then
      fail ("connector request flow did not settle");
    end if;
  end if;

  status := Sonbal.Connector_Server.begin_shutdown (server);
  if status /= Clair.Status.OK then
    fail ("connector server shutdown transition failed");
  end if;

  shutdown_deadline := Ada.Real_Time.clock + SHUTDOWN_TIMEOUT;
  while not Sonbal.Connector_Server.is_settled (server) and then
        Ada.Real_Time.clock < shutdown_deadline
  loop
    status := Clair.Event_Loop.iterate
      (self       => event_loop,
       timeout    => 100,
       dispatched => dispatched);
    if status /= Clair.Status.OK then
      fail ("shutdown event loop iteration failed");
    end if;
  end loop;

  if not Sonbal.Connector_Server.is_settled (server) or else
     Sonbal.Connector_Server.has_failed (server)
  then
    fail
      ("connector server did not reach clean settlement: settled=" &
       Boolean'Image (Sonbal.Connector_Server.is_settled (server)) &
       " failed=" &
       Boolean'Image (Sonbal.Connector_Server.has_failed (server)) &
       " active=" &
       Natural'Image (Sonbal.Connector_Server.active_request_count (server)));
  end if;

  if scenario = "finalize-retry" then
    status := Sonbal.Connector_Server.finalize (server);
    if status /= Clair.Status.CALLBACK_FAILED or else
       not Sonbal.Connector_Server.is_initialized (server)
    then
      fail ("connector server did not retain failed finalization ownership");
    end if;

    status := Sonbal.Connector_Server.finalize (server);
    if status /= Clair.Status.OK then
      fail ("connector server finalization retry failed");
    end if;
  else
    status := Sonbal.Connector_Server.finalize (server);
    if status /= Clair.Status.OK then
      fail ("connector server finalization failed");
    end if;
  end if;

  status := Clair.Event_Loop.finalize (event_loop);
  if status /= Clair.Status.OK then
    fail ("event loop finalization failed");
  end if;

  Ada.Text_IO.Put_Line ("[PASS] connector server " & scenario);
  Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);

exception
  when Program_Error =>
    close_if_needed (configuration_fd);
    close_if_needed (credential_fd);
end Sonbal_Connector_Server_Fixture;
