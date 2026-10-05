-- ============================================================================
-- sonbal-file_read.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Clair.Errno;
with Clair.Process;
with Clair.Unix.File;
with System;

package body Sonbal.File_Read is

  use type Clair.IO.Byte_Count;
  use type Clair.IO.Descriptor;
  use type Clair.IO.File_Offset;
  use type Clair.Process.Execution.Completion_Kind;
  use type Clair.Process.Exit_Code;
  use type Clair.Status.Code;
  use type Clair.Unix.File.Entry_Kind;
  use type Interfaces.Unsigned_64;
  use type Sonbal.Process_Arguments.Append_State;
  use type System.Storage_Elements.Storage_Element;
  use type System.Storage_Elements.Storage_Offset;

  HELPER_MODE : constant String := "--internal-read-file";
  PROTOCOL_MAGIC : constant String := "SBRF1";
  MAXIMUM_HELPER_HEADER_BYTES : constant Positive := 384;
  MAXIMUM_HELPER_OUTPUT_BYTES : constant Positive :=
    MAXIMUM_HELPER_HEADER_BYTES + MAXIMUM_CONTENT_BYTES;
  HEX_DIGITS : constant String := "0123456789abcdef";

  function compact_image (value : String) return String is
  begin
    if value'length > 0 and then value(value'first) = ' ' then
      return value(value'first + 1 .. value'last);
    end if;
    return value;
  end compact_image;

  function image (value : Revision) return String is
  begin
    if value.length = 0 then
      return "";
    end if;
    return value.data(1 .. value.length);
  end image;

  function is_empty (value : Revision) return Boolean is
    (value.length = 0);

  function is_valid_revision (value : String) return Boolean is
  begin
    if value'length /= MAXIMUM_REVISION_BYTES or else
       value(value'first .. value'first + 2) /= "r1-"
    then
      return False;
    end if;

    for index in value'first + 3 .. value'last loop
      if value(index) not in '0' .. '9' and then
         value(index) not in 'a' .. 'f'
      then
        return False;
      end if;
    end loop;
    return True;
  end is_valid_revision;

  procedure append_hex
    (target : in out Revision;
     cursor : in out Positive;
     value  : Interfaces.Unsigned_64;
     width  : Positive)
  is
    remaining : Interfaces.Unsigned_64 := value;
  begin
    for offset in reverse 0 .. width - 1 loop
      target.data(cursor + offset) :=
        HEX_DIGITS(Integer(remaining mod 16) + 1);
      remaining := remaining / 16;
    end loop;
    cursor := cursor + width;
  end append_hex;

  function revision_of
    (metadata : Clair.Unix.File.Metadata) return Revision
  is
    result : Revision;
    cursor : Positive := 1;
  begin
    result.data(1 .. 3) := "r1-";
    cursor := 4;
    append_hex
      (result,
       cursor,
       Interfaces.Unsigned_64(metadata.filesystem_id),
       16);
    append_hex
      (result,
       cursor,
       Interfaces.Unsigned_64(metadata.object_id),
       16);
    append_hex
      (result,
       cursor,
       Interfaces.Unsigned_64(metadata.size),
       16);
    append_hex
      (result,
       cursor,
       Interfaces.Unsigned_64
         (Interfaces.Integer_64(metadata.modification_time.seconds)),
       16);
    append_hex
      (result,
       cursor,
       Interfaces.Unsigned_64(metadata.modification_time.nanoseconds),
       8);
    append_hex
      (result,
       cursor,
       Interfaces.Unsigned_64
         (Interfaces.Integer_64(metadata.status_change_time.seconds)),
       16);
    append_hex
      (result,
       cursor,
       Interfaces.Unsigned_64(metadata.status_change_time.nanoseconds),
       8);

    if cursor /= MAXIMUM_REVISION_BYTES + 1 then
      return (others => <>);
    end if;

    result.length := MAXIMUM_REVISION_BYTES;
    return result;
  exception
    when others =>
      return (others => <>);
  end revision_of;

  function contains_nul (value : String) return Boolean is
  begin
    for item of value loop
      if item = Character'val (0) then
        return True;
      end if;
    end loop;
    return False;
  end contains_nul;

  function component_is_valid (value : String) return Boolean is
    (value'length > 0 and then
     value /= "." and then
     value /= "..");

  function is_valid_path (path : String) return Boolean is
    component_first : Integer;
  begin
    if path'length not in 1 .. MAXIMUM_PATH_BYTES or else
       path(path'first) = '/' or else contains_nul (path)
    then
      return False;
    end if;

    component_first := path'first;
    for index in path'range loop
      if path(index) = '/' then
        if not component_is_valid (path(component_first .. index - 1)) then
          return False;
        end if;
        component_first := index + 1;
      end if;
    end loop;

    return component_first <= path'last and then
      component_is_valid (path(component_first .. path'last));
  end is_valid_path;

  function workspace_root_is_valid (path : String) return Boolean is
    component_first : Integer;
  begin
    if path'length not in 1 .. MAXIMUM_PATH_BYTES or else
       path(path'first) /= '/' or else contains_nul (path)
    then
      return False;
    elsif path = "/" then
      return True;
    elsif path(path'last) = '/' then
      return False;
    end if;

    component_first := path'first + 1;
    for index in component_first .. path'last loop
      if path(index) = '/' then
        if not component_is_valid (path(component_first .. index - 1)) then
          return False;
        end if;
        component_first := index + 1;
      end if;
    end loop;

    return component_first <= path'last and then
      component_is_valid (path(component_first .. path'last));
  end workspace_root_is_valid;

  function parse_unsigned_64
    (text  : String;
     value : out Interfaces.Unsigned_64)
  return Boolean
  is
    parsed : Interfaces.Unsigned_64 := 0;
    digit  : Interfaces.Unsigned_64;
  begin
    value := 0;
    if text'length = 0 or else
       (text'length > 1 and then text(text'first) = '0')
    then
      return False;
    end if;

    for item of text loop
      if item not in '0' .. '9' then
        return False;
      end if;

      digit := Interfaces.Unsigned_64
        (Character'pos(item) - Character'pos('0'));
      if parsed > (Interfaces.Unsigned_64'Last - digit) / 10 then
        return False;
      end if;
      parsed := parsed * 10 + digit;
    end loop;

    value := parsed;
    return True;
  end parse_unsigned_64;

  function parse_offset
    (text    : String;
     maximum : Clair.IO.File_Offset;
     value   : out Clair.IO.File_Offset)
  return Boolean
  is
    parsed : Clair.IO.File_Offset := 0;
    digit  : Clair.IO.File_Offset;
  begin
    value := 0;
    if text'length = 0 or else
       (text'length > 1 and then text(text'first) = '0')
    then
      return False;
    end if;

    for item of text loop
      if item not in '0' .. '9' then
        return False;
      end if;

      digit :=
        Clair.IO.File_Offset(Character'pos(item) - Character'pos('0'));
      if parsed > (maximum - digit) / 10 then
        return False;
      end if;
      parsed := parsed * 10 + digit;
    end loop;

    value := parsed;
    return True;
  end parse_offset;

  function parse_maximum
    (text  : String;
     value : out Positive)
  return Boolean
  is
    parsed : Clair.IO.File_Offset := 0;
  begin
    value := 1;
    if not parse_offset
      (text, Clair.IO.File_Offset(MAXIMUM_CONTENT_BYTES), parsed)
    then
      return False;
    elsif parsed = 0 then
      return False;
    end if;

    value := Positive(parsed);
    return True;
  end parse_maximum;

  function append_argument
    (arguments : in out Sonbal.Process_Arguments.Arguments;
     value     : String)
  return Boolean
  is
    state : constant Sonbal.Process_Arguments.Append_State :=
      Sonbal.Process_Arguments.append (arguments, value);
  begin
    return state = Sonbal.Process_Arguments.Append_Accepted;
  end append_argument;

  function build_helper_arguments
    (argument_zero      : String;
     workspace_root     : String;
     root_filesystem_id : Interfaces.Unsigned_64;
     root_object_id     : Interfaces.Unsigned_64;
     path               : String;
     offset             : Clair.IO.File_Offset;
     maximum_bytes      : Positive;
     expected_revision  : String;
     arguments          : out Sonbal.Process_Arguments.Arguments)
  return Clair.Status.Code
  is
    succeeded : Boolean := True;
  begin
    Sonbal.Process_Arguments.clear (arguments);
    if argument_zero'length = 0 or else contains_nul (argument_zero) or else
       not workspace_root_is_valid (workspace_root) or else
       not is_valid_path (path) or else
       offset > MAXIMUM_PUBLIC_FILE_OFFSET or else
       maximum_bytes > MAXIMUM_CONTENT_BYTES or else
       (expected_revision'length /= 0 and then
        not is_valid_revision (expected_revision))
    then
      return Clair.Status.INVALID_ARGUMENT;
    end if;

    succeeded := append_argument (arguments, argument_zero);
    succeeded := append_argument (arguments, HELPER_MODE) and then succeeded;
    succeeded := append_argument (arguments, workspace_root) and then succeeded;
    succeeded :=
      append_argument
        (arguments,
         compact_image(Interfaces.Unsigned_64'image(root_filesystem_id))) and then
      succeeded;
    succeeded :=
      append_argument
        (arguments,
         compact_image(Interfaces.Unsigned_64'image(root_object_id))) and then
      succeeded;
    succeeded := append_argument (arguments, path) and then succeeded;
    succeeded :=
      append_argument
        (arguments, compact_image(Clair.IO.File_Offset'image(offset))) and then
      succeeded;
    succeeded :=
      append_argument
        (arguments, compact_image(Positive'image(maximum_bytes))) and then
      succeeded;
    succeeded :=
      append_argument
        (arguments,
         (if expected_revision'length = 0
          then "-"
          else expected_revision)) and then
      succeeded;

    if not succeeded or else
       not Sonbal.Process_Arguments.is_valid (arguments)
    then
      Sonbal.Process_Arguments.clear (arguments);
      return Clair.Status.RANGE_ERROR;
    end if;

    return Clair.Status.OK;
  end build_helper_arguments;

  function classify_open_failure
    (status : Clair.Status.Code) return Read_State
  is
  begin
    if status = Clair.Status.from_errno (Clair.Errno.ENOENT) then
      return Read_Not_Found;
    elsif status = Clair.Status.from_errno (Clair.Errno.EACCES) or else
          status = Clair.Status.from_errno (Clair.Errno.EPERM)
    then
      return Read_Access_Denied;
    elsif status = Clair.Status.from_errno (Clair.Errno.ELOOP) or else
          status = Clair.Status.from_errno (Clair.Errno.EMLINK) or else
          status = Clair.Status.from_errno (Clair.Errno.ENOTDIR)
    then
      return Read_Path_Refused;
    end if;
    return Read_Failed;
  end classify_open_failure;

  function close_descriptor
    (descriptor : in out Clair.IO.Descriptor) return Boolean
  is
    status : Clair.Status.Code;
  begin
    if descriptor = Clair.IO.INVALID_DESCRIPTOR then
      return True;
    end if;

    status := Clair.IO.close (descriptor);
    descriptor := Clair.IO.INVALID_DESCRIPTOR;
    return status = Clair.Status.OK;
  end close_descriptor;

  procedure discard_descriptor
    (descriptor : in out Clair.IO.Descriptor)
  is
    ignored : constant Boolean := close_descriptor (descriptor);
    pragma Unreferenced (ignored);
  begin
    null;
  end discard_descriptor;

  function advance_directory
    (directory_fd : in out Clair.IO.Descriptor;
     name         : String;
     state        : out Read_State)
  return Boolean
  is
    options  : Clair.Unix.File.Open_Options :=
      Clair.Unix.File.NO_OPEN_OPTIONS;
    child_fd : Clair.IO.Descriptor := Clair.IO.INVALID_DESCRIPTOR;
    status   : Clair.Status.Code;
  begin
    state := Read_Failed;
    options(Clair.Unix.File.Close_On_Exec) := True;
    options(Clair.Unix.File.Nonblocking) := True;
    options(Clair.Unix.File.Do_Not_Follow_Final_Symbolic_Link) := True;
    options(Clair.Unix.File.Require_Directory) := True;

    status := Clair.Unix.File.open_at
      (parent            => directory_fd,
       name              => name,
       requested_access  => Clair.Unix.File.Read_Only,
       options           => options,
       opened_descriptor => child_fd);
    if status /= Clair.Status.OK then
      state := classify_open_failure (status);
      return False;
    end if;

    if not close_descriptor (directory_fd) then
      discard_descriptor (child_fd);
      state := Read_Failed;
      return False;
    end if;

    directory_fd := child_fd;
    return True;
  end advance_directory;

  function open_workspace_root
    (workspace_root     : String;
     root_filesystem_id : Interfaces.Unsigned_64;
     root_object_id     : Interfaces.Unsigned_64;
     directory_fd       : out Clair.IO.Descriptor;
     state              : out Read_State)
  return Boolean
  is
    options  : Clair.Unix.File.Open_Options :=
      Clair.Unix.File.NO_OPEN_OPTIONS;
    metadata : Clair.Unix.File.Metadata;
    status   : Clair.Status.Code;
  begin
    directory_fd := Clair.IO.INVALID_DESCRIPTOR;
    state := Read_Path_Refused;
    if not workspace_root_is_valid (workspace_root) then
      return False;
    end if;

    options(Clair.Unix.File.Close_On_Exec) := True;
    options(Clair.Unix.File.Nonblocking) := True;
    options(Clair.Unix.File.Do_Not_Follow_Final_Symbolic_Link) := True;
    options(Clair.Unix.File.Require_Directory) := True;

    status := Clair.Unix.File.open
      (path              => workspace_root,
       requested_access  => Clair.Unix.File.Read_Only,
       options           => options,
       opened_descriptor => directory_fd);
    if status /= Clair.Status.OK then
      state := classify_open_failure (status);
      return False;
    end if;

    status := Clair.Unix.File.query_metadata (directory_fd, metadata);
    if status /= Clair.Status.OK then
      state := Read_Failed;
      discard_descriptor (directory_fd);
      return False;
    elsif metadata.kind /= Clair.Unix.File.Directory or else
          Interfaces.Unsigned_64(metadata.filesystem_id) /=
            root_filesystem_id or else
          Interfaces.Unsigned_64(metadata.object_id) /= root_object_id
    then
      state := Read_Path_Refused;
      discard_descriptor (directory_fd);
      return False;
    end if;

    return True;
  end open_workspace_root;

  function open_target_file
    (directory_fd : in out Clair.IO.Descriptor;
     path         : String;
     file_fd      : out Clair.IO.Descriptor;
     state        : out Read_State)
  return Boolean
  is
    options : Clair.Unix.File.Open_Options :=
      Clair.Unix.File.NO_OPEN_OPTIONS;
    cursor : Integer := path'first;
    finish : Integer;
    status : Clair.Status.Code;
  begin
    file_fd := Clair.IO.INVALID_DESCRIPTOR;
    state := Read_Path_Refused;
    if not is_valid_path (path) then
      return False;
    end if;

    while cursor <= path'last loop
      finish := cursor;
      while finish <= path'last and then path(finish) /= '/' loop
        finish := finish + 1;
      end loop;

      if finish <= path'last then
        if not advance_directory
          (directory_fd, path(cursor .. finish - 1), state)
        then
          return False;
        end if;
      else
        options(Clair.Unix.File.Close_On_Exec) := True;
        options(Clair.Unix.File.Nonblocking) := True;
        options(Clair.Unix.File.Do_Not_Follow_Final_Symbolic_Link) := True;
        status := Clair.Unix.File.open_at
          (parent            => directory_fd,
           name              => path(cursor .. path'last),
           requested_access  => Clair.Unix.File.Read_Only,
           options           => options,
           opened_descriptor => file_fd);
        if status /= Clair.Status.OK then
          state := classify_open_failure (status);
          return False;
        end if;

        if not close_descriptor (directory_fd) then
          discard_descriptor (file_fd);
          state := Read_Failed;
          return False;
        end if;
        return True;
      end if;

      cursor := finish + 1;
    end loop;
    return False;
  end open_target_file;

  procedure clear_content (result : in out Read_Result) is
  begin
    result.file_revision := (others => <>);
    result.file_size := 0;
    result.offset := 0;
    result.next_offset := 0;
    result.eof := False;
    result.content := [others => 0];
    result.content_length := 0;
  end clear_content;

  procedure perform_read
    (workspace_root     : String;
     root_filesystem_id : Interfaces.Unsigned_64;
     root_object_id     : Interfaces.Unsigned_64;
     path               : String;
     offset             : Clair.IO.File_Offset;
     maximum_bytes      : Positive;
     expected_revision  : String;
     result             : out Read_Result)
  is
    directory_fd : Clair.IO.Descriptor := Clair.IO.INVALID_DESCRIPTOR;
    file_fd : Clair.IO.Descriptor := Clair.IO.INVALID_DESCRIPTOR;
    before : Clair.Unix.File.Metadata;
    after : Clair.Unix.File.Metadata;
    before_revision : Revision;
    after_revision : Revision;
    state : Read_State := Read_Failed;
    status : Clair.Status.Code;
    bytes_read : Clair.IO.Byte_Count := 0;
    target_bytes : Natural := 0;
    total_read : Natural := 0;
    read_operation_failed : Boolean := False;
    unexpected_eof : Boolean := False;

    procedure cleanup is
      close_ok : Boolean := True;
    begin
      if not close_descriptor (file_fd) then
        close_ok := False;
      end if;
      if not close_descriptor (directory_fd) then
        close_ok := False;
      end if;
      if not close_ok and then result.state = Read_OK then
        result.state := Read_Failed;
        clear_content (result);
      end if;
    end cleanup;
  begin
    result := (others => <>);
    result.state := Read_Failed;

    if maximum_bytes > MAXIMUM_CONTENT_BYTES or else
       offset > MAXIMUM_PUBLIC_FILE_OFFSET or else
       not workspace_root_is_valid (workspace_root) or else
       not is_valid_path (path) or else
       (expected_revision'length /= 0 and then
        not is_valid_revision (expected_revision))
    then
      result.state := Read_Path_Refused;
      return;
    end if;

    if not open_workspace_root
      (workspace_root,
       root_filesystem_id,
       root_object_id,
       directory_fd,
       state)
    then
      result.state := state;
      cleanup;
      return;
    elsif not open_target_file (directory_fd, path, file_fd, state) then
      result.state := state;
      cleanup;
      return;
    end if;

    status := Clair.Unix.File.query_metadata (file_fd, before);
    if status /= Clair.Status.OK then
      result.state := Read_Failed;
      cleanup;
      return;
    elsif before.kind /= Clair.Unix.File.Regular_File then
      result.state := Read_Not_Regular_File;
      cleanup;
      return;
    elsif before.size > MAXIMUM_PUBLIC_FILE_OFFSET then
      result.state := Read_File_Too_Large;
      cleanup;
      return;
    elsif offset > before.size then
      result.state := Read_Offset_Out_Of_Range;
      cleanup;
      return;
    end if;

    before_revision := revision_of (before);
    if is_empty (before_revision) then
      result.state := Read_Failed;
      cleanup;
      return;
    elsif expected_revision'length /= 0 and then
          image (before_revision) /= expected_revision
    then
      result.state := Read_Revision_Mismatch;
      cleanup;
      return;
    end if;

    target_bytes := Natural
      (Clair.IO.File_Offset'Min
         (Clair.IO.File_Offset(maximum_bytes), before.size - offset));

    while total_read < target_bytes loop
      status := Clair.IO.read_at
        (fd         => file_fd,
         offset     => offset + Clair.IO.File_Offset(total_read),
         buffer     => result.content
           (result.content'first +
              System.Storage_Elements.Storage_Offset(total_read) ..
            result.content'first +
              System.Storage_Elements.Storage_Offset(target_bytes - 1)),
         bytes_read => bytes_read);
      if status /= Clair.Status.OK then
        read_operation_failed := True;
        exit;
      elsif bytes_read = 0 then
        unexpected_eof := True;
        exit;
      elsif bytes_read > Clair.IO.Byte_Count(target_bytes - total_read) then
        read_operation_failed := True;
        exit;
      end if;
      total_read := total_read + Natural(bytes_read);
    end loop;

    status := Clair.Unix.File.query_metadata (file_fd, after);
    if status /= Clair.Status.OK then
      result.state := Read_Failed;
      clear_content (result);
      cleanup;
      return;
    end if;

    after_revision := revision_of (after);
    if is_empty (after_revision) then
      result.state := Read_Failed;
      clear_content (result);
      cleanup;
      return;
    elsif image (before_revision) /= image (after_revision) then
      result.state := Read_File_Changed;
      clear_content (result);
      cleanup;
      return;
    elsif read_operation_failed or else unexpected_eof or else
          total_read /= target_bytes
    then
      result.state := Read_Failed;
      clear_content (result);
      cleanup;
      return;
    end if;

    result.state := Read_OK;
    result.file_revision := before_revision;
    result.file_size := before.size;
    result.offset := offset;
    result.content_length := total_read;
    result.next_offset := offset + Clair.IO.File_Offset(total_read);
    result.eof := result.next_offset = result.file_size;
    cleanup;
  exception
    when others =>
      result := (others => <>);
      result.state := Read_Failed;
      cleanup;
  end perform_read;

  function status_image (state : Read_State) return String is
  begin
    case state is
      when Read_OK =>
        return "ok";
      when Read_Path_Refused =>
        return "path_refused";
      when Read_Not_Found =>
        return "not_found";
      when Read_Access_Denied =>
        return "access_denied";
      when Read_Not_Regular_File =>
        return "not_regular_file";
      when Read_File_Too_Large =>
        return "file_too_large";
      when Read_Offset_Out_Of_Range =>
        return "offset_out_of_range";
      when Read_Revision_Mismatch =>
        return "revision_mismatch";
      when Read_File_Changed =>
        return "file_changed";
      when Read_Timed_Out =>
        return "timed_out";
      when Read_Failed =>
        return "read_failed";
      when Read_Execution_Failed =>
        return "execution_failed";
    end case;
  end status_image;

  function state_from_image
    (value : String;
     state : out Read_State)
  return Boolean
  is
  begin
    for candidate in Read_State loop
      if value = status_image (candidate) then
        state := candidate;
        return True;
      end if;
    end loop;

    state := Read_Execution_Failed;
    return False;
  end state_from_image;

  function write_string (value : String) return Boolean is
    bytes_written : Clair.IO.Byte_Count := 0;
    offset : Natural := 0;
    status : Clair.Status.Code;
  begin
    while offset < value'length loop
      status := Clair.IO.write
        (fd            => Clair.IO.STANDARD_OUTPUT,
         buffer        => value(value'first + offset)'address,
         count         => Clair.IO.Byte_Count(value'length - offset),
         bytes_written => bytes_written);
      if status /= Clair.Status.OK or else bytes_written = 0 or else
         bytes_written > Clair.IO.Byte_Count(value'length - offset)
      then
        return False;
      end if;
      offset := offset + Natural(bytes_written);
    end loop;

    return True;
  end write_string;

  function write_content
    (content : Content_Buffer;
     length  : Natural)
  return Boolean
  is
    bytes_written : Clair.IO.Byte_Count := 0;
    offset : Natural := 0;
    status : Clair.Status.Code;
  begin
    if length = 0 then
      return True;
    end if;

    while offset < length loop
      status := Clair.IO.write
        (fd            => Clair.IO.STANDARD_OUTPUT,
         buffer        => content
           (content'first +
            System.Storage_Elements.Storage_Offset(offset))'address,
         count         => Clair.IO.Byte_Count(length - offset),
         bytes_written => bytes_written);
      if status /= Clair.Status.OK or else bytes_written = 0 or else
         bytes_written > Clair.IO.Byte_Count(length - offset)
      then
        return False;
      end if;
      offset := offset + Natural(bytes_written);
    end loop;

    return True;
  end write_content;

  function emit_result (result : Read_Result) return Boolean is
    header : constant String :=
      PROTOCOL_MAGIC & "|" & status_image(result.state) & "|" &
      (if result.state = Read_OK then image(result.file_revision) else "-") & "|" &
      (if result.state = Read_OK
       then compact_image(Clair.IO.File_Offset'image(result.file_size))
       else "0") & "|" &
      (if result.state = Read_OK
       then compact_image(Clair.IO.File_Offset'image(result.offset))
       else "0") & "|" &
      (if result.state = Read_OK
       then compact_image(Natural'image(result.content_length))
       else "0") & "|" &
      (if result.state = Read_OK and then result.eof then "1" else "0") &
      Character'val(10);
  begin
    if header'length > MAXIMUM_HELPER_HEADER_BYTES then
      return False;
    end if;

    return write_string (header) and then
      (result.state /= Read_OK or else
       write_content (result.content, result.content_length));
  end emit_result;

  function run_helper
    (workspace_root     : String;
     root_filesystem_id : String;
     root_object_id     : String;
     path               : String;
     offset_text        : String;
     maximum_text       : String;
     expected_revision  : String)
  return Boolean
  is
    filesystem_id : Interfaces.Unsigned_64 := 0;
    object_id     : Interfaces.Unsigned_64 := 0;
    offset        : Clair.IO.File_Offset := 0;
    maximum_bytes : Positive := 1;
    result        : Read_Result;
    expected : constant String :=
      (if expected_revision = "-" then "" else expected_revision);
  begin
    if not parse_unsigned_64 (root_filesystem_id, filesystem_id) or else
       not parse_unsigned_64 (root_object_id, object_id) or else
       not parse_offset
         (offset_text, MAXIMUM_PUBLIC_FILE_OFFSET, offset) or else
       not parse_maximum (maximum_text, maximum_bytes) or else
       (expected'length /= 0 and then not is_valid_revision (expected))
    then
      return False;
    end if;

    perform_read
      (workspace_root,
       filesystem_id,
       object_id,
       path,
       offset,
       maximum_bytes,
       expected,
       result);
    return emit_result (result);
  exception
    when others =>
      return False;
  end run_helper;

  function parse_header_offset
    (text    : String;
     maximum : Clair.IO.File_Offset;
     value   : out Clair.IO.File_Offset)
  return Boolean is
    (parse_offset (text, maximum, value));

  function parse_helper_outcome
    (status             : Clair.Status.Code;
     outcome            : Clair.Process.Execution.Result;
     requested_offset   : Clair.IO.File_Offset;
     requested_maximum  : Positive;
     expected_revision  : String;
     result             : out Read_Result)
  return Clair.Status.Code
  is
    stdout_length : Natural := 0;
    stderr_length : Natural := 0;
    copied : Natural := 0;
    buffer : System.Storage_Elements.Storage_Array
      (1 .. System.Storage_Elements.Storage_Offset
        (MAXIMUM_HELPER_OUTPUT_BYTES)) := [others => 0];
  begin
    result := (others => <>);
    result.state := Read_Execution_Failed;

    if requested_offset > MAXIMUM_PUBLIC_FILE_OFFSET or else
       requested_maximum > MAXIMUM_CONTENT_BYTES or else
       (expected_revision'length /= 0 and then
        not is_valid_revision (expected_revision))
    then
      return Clair.Status.INVALID_ARGUMENT;
    elsif status /= Clair.Status.OK or else
          not Clair.Process.Execution.is_available (outcome) or else
          Clair.Process.Execution.has_infrastructure_failure (outcome) or else
          Clair.Process.Execution.cleanup_status_of (outcome) /=
            Clair.Status.OK or else
          not Clair.Process.Execution.has_completion (outcome)
    then
      return Clair.Status.OK;
    end if;

    case Clair.Process.Execution.completion_of (outcome) is
      when Clair.Process.Execution.Timed_Out =>
        result.state := Read_Timed_Out;
        return Clair.Status.OK;
      when Clair.Process.Execution.Signaled |
           Clair.Process.Execution.Launch_Failed =>
        return Clair.Status.OK;
      when Clair.Process.Execution.Exited =>
        if Clair.Process.Execution.exit_code_of (outcome) /= 0 then
          return Clair.Status.OK;
        end if;
    end case;

    stdout_length := Clair.Process.Execution.standard_output_length (outcome);
    stderr_length := Clair.Process.Execution.standard_error_length (outcome);
    if stdout_length = 0 or else
       stdout_length > MAXIMUM_HELPER_OUTPUT_BYTES or else
       stderr_length /= 0 or else
       Clair.Process.Execution.is_standard_output_truncated (outcome) or else
       Clair.Process.Execution.is_standard_error_truncated (outcome)
    then
      return Clair.Status.INTERNAL_ERROR;
    end if;

    declare
      target : System.Storage_Elements.Storage_Array
        renames buffer
          (buffer'first ..
           buffer'first +
             System.Storage_Elements.Storage_Offset(stdout_length - 1));
      copy_status : constant Clair.Status.Code :=
        Clair.Process.Execution.copy_standard_output
          (outcome => outcome,
           offset  => 0,
           buffer  => target,
           copied  => copied);
    begin
      if copy_status /= Clair.Status.OK or else copied /= stdout_length then
        return Clair.Status.INTERNAL_ERROR;
      end if;
    end;

    declare
      newline : Natural := 0;
    begin
      for index in 0 .. stdout_length - 1 loop
        if buffer
          (buffer'first +
           System.Storage_Elements.Storage_Offset(index)) = 10
        then
          newline := index + 1;
          exit;
        end if;
      end loop;

      if newline = 0 or else newline > MAXIMUM_HELPER_HEADER_BYTES then
        return Clair.Status.INTERNAL_ERROR;
      end if;

      declare
        header : String (1 .. newline - 1);
      begin
        for index in header'range loop
          header(index) := Character'val
            (Integer
               (buffer
                  (buffer'first +
                   System.Storage_Elements.Storage_Offset(index - 1))));
        end loop;

        declare
          type Field_Bounds is record
            first : Natural := 0;
            last  : Natural := 0;
          end record;

          type Field_Bounds_Array is array (Positive range 1 .. 7)
            of Field_Bounds;

          fields : Field_Bounds_Array;
          field_index : Positive := 1;
          field_first : Natural := header'first;
          parsed_state : Read_State;
          parsed_file_size : Clair.IO.File_Offset := 0;
          parsed_offset : Clair.IO.File_Offset := 0;
          parsed_length : Clair.IO.File_Offset := 0;
          parsed_eof : Boolean := False;
        begin
          for index in header'range loop
            if header(index) = '|' then
              if field_index > 6 then
                return Clair.Status.INTERNAL_ERROR;
              end if;

              fields(field_index) := (field_first, index - 1);
              field_index := field_index + 1;
              field_first := index + 1;
            end if;
          end loop;

          if field_index /= 7 or else field_first > header'last then
            return Clair.Status.INTERNAL_ERROR;
          end if;
          fields(7) := (field_first, header'last);

          declare
            magic_text : constant String :=
              header(fields(1).first .. fields(1).last);
            state_text : constant String :=
              header(fields(2).first .. fields(2).last);
            revision_text : constant String :=
              header(fields(3).first .. fields(3).last);
            size_text : constant String :=
              header(fields(4).first .. fields(4).last);
            offset_text : constant String :=
              header(fields(5).first .. fields(5).last);
            length_text : constant String :=
              header(fields(6).first .. fields(6).last);
            eof_text : constant String :=
              header(fields(7).first .. fields(7).last);
            payload_length : constant Natural := stdout_length - newline;
          begin
            if magic_text /= PROTOCOL_MAGIC or else
               not state_from_image (state_text, parsed_state)
            then
              return Clair.Status.INTERNAL_ERROR;
            end if;

            if parsed_state /= Read_OK then
              if revision_text /= "-" or else
                 size_text /= "0" or else
                 offset_text /= "0" or else
                 length_text /= "0" or else
                 eof_text /= "0" or else
                 payload_length /= 0 or else
                 parsed_state in Read_Timed_Out | Read_Execution_Failed
              then
                return Clair.Status.INTERNAL_ERROR;
              end if;

              result.state := parsed_state;
              return Clair.Status.OK;
            end if;

            if not is_valid_revision (revision_text) or else
               not parse_header_offset
                 (size_text,
                  MAXIMUM_PUBLIC_FILE_OFFSET,
                  parsed_file_size) or else
               not parse_header_offset
                 (offset_text,
                  MAXIMUM_PUBLIC_FILE_OFFSET,
                  parsed_offset) or else
               not parse_header_offset
                 (length_text,
                  Clair.IO.File_Offset(MAXIMUM_CONTENT_BYTES),
                  parsed_length) or else
               (eof_text /= "0" and then eof_text /= "1")
            then
              return Clair.Status.INTERNAL_ERROR;
            end if;

            parsed_eof := eof_text = "1";
            if parsed_offset /= requested_offset or else
               parsed_length > Clair.IO.File_Offset(requested_maximum) or else
               payload_length /= Natural(parsed_length) or else
               parsed_offset > parsed_file_size or else
               parsed_length > parsed_file_size - parsed_offset or else
               parsed_eof /=
                 (parsed_offset + parsed_length = parsed_file_size) or else
               (expected_revision'length /= 0 and then
                revision_text /= expected_revision)
            then
              return Clair.Status.INTERNAL_ERROR;
            end if;

            result.state := Read_OK;
            result.file_revision.data := [others => Character'val (0)];
            result.file_revision.data(1 .. revision_text'length) := revision_text;
            result.file_revision.length := revision_text'length;
            result.file_size := parsed_file_size;
            result.offset := parsed_offset;
            result.next_offset := parsed_offset + parsed_length;
            result.eof := parsed_eof;
            result.content_length := Natural(parsed_length);

            if result.content_length > 0 then
              for index in 0 .. result.content_length - 1 loop
                result.content
                  (result.content'first +
                   System.Storage_Elements.Storage_Offset(index)) :=
                  buffer
                    (buffer'first +
                     System.Storage_Elements.Storage_Offset(newline + index));
              end loop;
            end if;
            return Clair.Status.OK;
          end;
        end;
      end;
    end;
  exception
    when others =>
      result := (others => <>);
      result.state := Read_Execution_Failed;
      return Clair.Status.INTERNAL_ERROR;
  end parse_helper_outcome;

end Sonbal.File_Read;
