-- ============================================================================
-- sonbal_connector_openai_fixture.adb
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
with Sonbal.Connector_Host;

procedure Sonbal_Connector_OpenAI_Fixture is

  use type Clair.IO.Descriptor;
  use type Clair.Status.Code;
  use type Interfaces.C.int;

  O_RDONLY : constant Interfaces.C.int := 0;

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
      fail ("cannot open OpenAI connector fixture input: " & path);
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
      fail ("OpenAI connector fixture descriptor cleanup failed");
    end if;
    fd := Clair.IO.INVALID_DESCRIPTOR;
  end close_if_needed;

  scenario : constant String := Ada.Command_Line.Argument (1);
  plugin_path : constant String := Ada.Command_Line.Argument (2);
  configuration_path : constant String := Ada.Command_Line.Argument (3);
  credential_path : constant String := Ada.Command_Line.Argument (4);

  event_loop : aliased Clair.Event_Loop.Context;
  host : aliased Sonbal.Connector_Host.Context;
  configuration_fd : Clair.IO.Descriptor := Clair.IO.INVALID_DESCRIPTOR;
  credential_fd : Clair.IO.Descriptor := Clair.IO.INVALID_DESCRIPTOR;
  status : Clair.Status.Code;

begin
  if Ada.Command_Line.Argument_Count /= 4 then
    fail ("usage: fixture SCENARIO PLUGIN CONFIGURATION CREDENTIAL");
  end if;

  if scenario not in
    "initialize-finalize" | "invalid-config" |
    "invalid-credential" | "oversize-config" | "oversize-credential"
  then
    fail ("unknown OpenAI connector fixture scenario: " & scenario);
  end if;

  status := Clair.Event_Loop.initialize (event_loop);
  if status /= Clair.Status.OK then
    fail ("event loop initialization failed");
  end if;

  configuration_fd := open_read_only (configuration_path);
  credential_fd := open_read_only (credential_path);

  status := Sonbal.Connector_Host.initialize
    (self             => host,
     event_loop       => event_loop,
     plugin_path      => plugin_path,
     configuration_fd => configuration_fd,
     credential_fd    => credential_fd,
     max_work_slots   => Sonbal.Configuration.DEFAULT_MAX_WORK_SLOTS);

  if configuration_fd /= Clair.IO.INVALID_DESCRIPTOR or else
     credential_fd /= Clair.IO.INVALID_DESCRIPTOR
  then
    fail ("OpenAI connector host did not consume startup descriptors");
  end if;

  if scenario = "initialize-finalize" then
    if status /= Clair.Status.OK or else
       not Sonbal.Connector_Host.is_initialized (host)
    then
      fail ("OpenAI connector initialization failed");
    end if;

    status := Sonbal.Connector_Host.finalize (host);
    if status /= Clair.Status.OK then
      fail ("OpenAI connector initialization cleanup failed");
    end if;

  elsif scenario in "invalid-config" | "invalid-credential" then
    if status /= Clair.Status.INVALID_ARGUMENT or else
       Sonbal.Connector_Host.is_initialized (host)
    then
      fail ("invalid OpenAI startup input was not rejected cleanly");
    end if;

  elsif scenario in "oversize-config" | "oversize-credential" then
    if status /= Clair.Status.OUT_OF_MEMORY or else
       Sonbal.Connector_Host.is_initialized (host)
    then
      fail ("oversized OpenAI startup input was not rejected boundedly");
    end if;
  end if;

  status := Clair.Event_Loop.finalize (event_loop);
  if status /= Clair.Status.OK then
    fail ("event loop finalization failed");
  end if;

  Ada.Text_IO.Put_Line ("[PASS] OpenAI connector " & scenario);
  Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);

exception
  when Program_Error =>
    close_if_needed (configuration_fd);
    close_if_needed (credential_fd);
end Sonbal_Connector_OpenAI_Fixture;
