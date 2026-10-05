-- ============================================================================
-- sonbal-security_diagnostics.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Ada.Environment_Variables;
with Ada.Text_IO;
with Clair.Errno;
with Clair.Unix.File;
with Clair.IO;
with Clair.Status;

package body Sonbal.Security_Diagnostics is

  use type Clair.Status.Code;

  function present (name : String) return Boolean is
  begin
    return Ada.Environment_Variables.Exists (name);
  end present;

  function observe return Observation is
    result       : Observation;
    descriptor   : Clair.Unix.File.Descriptor;
    open_status  : Clair.Status.Code;
    close_status : Clair.Status.Code;
    options      : constant Clair.Unix.File.Open_Options :=
      [Clair.Unix.File.Close_On_Exec => True, others => False];
  begin
    result.control_plane_api_key_present := present ("CONTROL_PLANE_API_KEY");
    result.openai_api_key_present        := present ("OPENAI_API_KEY");
    result.openai_admin_key_present      := present ("OPENAI_ADMIN_KEY");
    result.ssh_auth_sock_present         := present ("SSH_AUTH_SOCK");

    open_status := Clair.Unix.File.open
      ("/dev/tty", Clair.Unix.File.Read_Only, options, descriptor);
    if open_status = Clair.Status.OK then
      close_status := Clair.IO.close (descriptor);
      if close_status = Clair.Status.OK then
        result.terminal := Controlling_Terminal_Accessible;
      else
        result.terminal := Terminal_Probe_Failed;
      end if;
    elsif open_status = Clair.Status.from_errno (Clair.Errno.ENXIO) then
      result.terminal := No_Controlling_Terminal;
    else
      result.terminal := Terminal_Probe_Failed;
    end if;

    return result;
  end observe;

  function is_hardened (item : Observation) return Boolean is
  begin
    return not item.control_plane_api_key_present and then
      not item.openai_api_key_present and then
      not item.openai_admin_key_present and then
      not item.ssh_auth_sock_present and then
      item.terminal = No_Controlling_Terminal;
  end is_hardened;

  function presence_image (value : Boolean) return String is
  begin
    if value then
      return "present";
    end if;

    return "absent";
  end presence_image;

  function terminal_image (value : Terminal_State) return String is
  begin
    case value is
      when No_Controlling_Terminal =>
        return "absent";
      when Controlling_Terminal_Accessible =>
        return "accessible";
      when Terminal_Probe_Failed =>
        return "probe_failed";
    end case;
  end terminal_image;

  procedure print_report (item : Observation) is
  begin
    Ada.Text_IO.Put_Line
      ("CONTROL_PLANE_API_KEY=" &
       presence_image (item.control_plane_api_key_present));
    Ada.Text_IO.Put_Line
      ("OPENAI_API_KEY=" & presence_image (item.openai_api_key_present));
    Ada.Text_IO.Put_Line
      ("OPENAI_ADMIN_KEY=" & presence_image (item.openai_admin_key_present));
    Ada.Text_IO.Put_Line
      ("SSH_AUTH_SOCK=" & presence_image (item.ssh_auth_sock_present));
    Ada.Text_IO.Put_Line
      ("controlling_terminal=" & terminal_image (item.terminal));

    if is_hardened (item) then
      Ada.Text_IO.Put_Line ("result=hardened");
    else
      Ada.Text_IO.Put_Line ("result=unsafe");
    end if;
  end print_report;

end Sonbal.Security_Diagnostics;
