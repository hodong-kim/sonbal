-- ============================================================================
-- sonbal-configuration.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Ada.Environment_Variables;
with Ada.IO_Exceptions;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Clair.Status;
with Clair.YAML;

package body Sonbal.Configuration is

  package Stream_IO renames Ada.Streams.Stream_IO;

  use type Ada.Streams.Stream_Element_Offset;
  use type Ada.Streams.Stream_IO.Count;
  use type Clair.Status.Code;
  use type Clair.YAML.Count;
  use type Clair.YAML.Node_Kind;

  DIAGNOSTIC_TRACE_ENVIRONMENT_VARIABLE : constant String :=
    "SONBAL_DIAGNOSTIC_TRACE";

  function diagnostic_trace_enabled return Boolean is
  begin
    return
      Ada.Environment_Variables.Exists
        (DIAGNOSTIC_TRACE_ENVIRONMENT_VARIABLE) and then
      Ada.Environment_Variables.Value
        (DIAGNOSTIC_TRACE_ENVIRONMENT_VARIABLE) = "1";
  exception
    when others =>
      return False;
  end diagnostic_trace_enabled;

  function parse_max_work_slots
    (text   : String;
     result : out Work_Slot_Count)
  return Boolean
  is
    value : Natural := 0;
    digit : Natural;
  begin
    result := DEFAULT_MAX_WORK_SLOTS;

    if text'length = 0 then
      return False;
    end if;

    for item of text loop
      if item not in '0' .. '9' then
        return False;
      end if;

      digit := Character'pos (item) - Character'pos ('0');
      value := value * 10 + digit;
      if value > ABSOLUTE_MAX_WORK_SLOTS then
        return False;
      end if;
    end loop;

    if value not in 1 .. ABSOLUTE_MAX_WORK_SLOTS then
      return False;
    end if;

    result := Work_Slot_Count(value);
    return True;
  end parse_max_work_slots;

  function scalar_equals
    (document : Clair.YAML.Document;
     node     : Clair.YAML.Node_Id;
     expected : String)
  return Boolean
  is
    kind          : Clair.YAML.Node_Kind;
    length        : Clair.YAML.Count;
    bytes_written : Clair.YAML.Count;
    buffer        : String (expected'range);
    status        : Clair.Status.Code;
  begin
    status := Clair.YAML.get_kind (document, node, kind);
    if status /= Clair.Status.OK or else kind /= Clair.YAML.Scalar_Node then
      return False;
    end if;

    status := Clair.YAML.get_scalar_length (document, node, length);
    if status /= Clair.Status.OK or else length /= expected'length then
      return False;
    end if;

    status := Clair.YAML.copy_scalar
      (document, node, buffer, bytes_written);
    return status = Clair.Status.OK and then
      bytes_written = length and then buffer = expected;
  end scalar_equals;

  function parse_source
    (source : String;
     result : out Values)
  return Boolean
  is
    identity        : Clair.YAML.Identity_Context;
    document        : Clair.YAML.Document;
    root            : Clair.YAML.Node_Id;
    execution_pair  : Clair.YAML.Node_Pair;
    max_work_pair   : Clair.YAML.Node_Pair;
    kind            : Clair.YAML.Node_Kind;
    length          : Clair.YAML.Count;
    scalar_length   : Clair.YAML.Count;
    bytes_written   : Clair.YAML.Count;
    max_work_slots  : Work_Slot_Count := DEFAULT_MAX_WORK_SLOTS;
    status          : Clair.Status.Code;
    finalize_status : Clair.Status.Code;
    initialized     : Boolean := False;

    function settle (value : Boolean) return Boolean is
    begin
      finalize_status := Clair.YAML.finalize (document);
      initialized := False;
      if finalize_status /= Clair.Status.OK then
        result := (others => <>);
        return False;
      end if;
      return value;
    end settle;
  begin
    result := (others => <>);

    if source'length = 0 or else source'length > MAXIMUM_CONFIG_BYTES then
      return False;
    end if;

    status := Clair.YAML.load (source, identity, document);
    if status /= Clair.Status.OK then
      return False;
    end if;
    initialized := True;

    status := Clair.YAML.get_root (document, root);
    if status /= Clair.Status.OK then
      return settle (False);
    end if;
    status := Clair.YAML.get_kind (document, root, kind);
    if status /= Clair.Status.OK or else kind /= Clair.YAML.Mapping_Node then
      return settle (False);
    end if;
    status := Clair.YAML.get_mapping_count (document, root, length);
    if status /= Clair.Status.OK or else length > 1 then
      return settle (False);
    elsif length = 0 then
      return settle (True);
    end if;

    status := Clair.YAML.get_mapping_pair_at
      (document, root, 1, execution_pair);
    if status /= Clair.Status.OK or else
       not scalar_equals (document, execution_pair.key, "execution")
    then
      return settle (False);
    end if;

    status := Clair.YAML.get_kind (document, execution_pair.value, kind);
    if status /= Clair.Status.OK or else kind /= Clair.YAML.Mapping_Node then
      return settle (False);
    end if;
    status := Clair.YAML.get_mapping_count
      (document, execution_pair.value, length);
    if status /= Clair.Status.OK or else length > 1 then
      return settle (False);
    elsif length = 0 then
      return settle (True);
    end if;

    status := Clair.YAML.get_mapping_pair_at
      (document, execution_pair.value, 1, max_work_pair);
    if status /= Clair.Status.OK or else
       not scalar_equals (document, max_work_pair.key, "max_work_slots")
    then
      return settle (False);
    end if;

    status := Clair.YAML.get_kind (document, max_work_pair.value, kind);
    if status /= Clair.Status.OK or else kind /= Clair.YAML.Scalar_Node then
      return settle (False);
    end if;
    status := Clair.YAML.get_scalar_length
      (document, max_work_pair.value, scalar_length);
    if status /= Clair.Status.OK or else scalar_length not in 1 .. 2 then
      return settle (False);
    end if;

    declare
      buffer : String (1 .. Natural(scalar_length));
    begin
      status := Clair.YAML.copy_scalar
        (document, max_work_pair.value, buffer, bytes_written);
      if status /= Clair.Status.OK or else
         bytes_written /= scalar_length or else
         not parse_max_work_slots (buffer, max_work_slots)
      then
        return settle (False);
      end if;
    end;

    result.max_work_slots := max_work_slots;
    return settle (True);
  exception
    when others =>
      if initialized then
        begin
          finalize_status := Clair.YAML.finalize (document);
        exception
          when others =>
            null;
        end;
      end if;
      result := (others => <>);
      return False;
  end parse_source;

  function load (result : out Values) return Load_Status is
    file      : Stream_IO.File_Type;
    opened    : Boolean := False;
    file_size : Stream_IO.Count;
    last      : Ada.Streams.Stream_Element_Offset;
    buffer    : Ada.Streams.Stream_Element_Array
      (1 .. Ada.Streams.Stream_Element_Offset(MAXIMUM_CONFIG_BYTES));
  begin
    result := (others => <>);

    begin
      Stream_IO.open (file, Stream_IO.In_File, CONFIG_FILE_PATH);
      opened := True;
    exception
      when Ada.IO_Exceptions.Name_Error =>
        return Configuration_Defaulted;
      when others =>
        return Configuration_Read_Failed;
    end;

    file_size := Stream_IO.size (file);
    if file_size = 0 or else
       file_size > Stream_IO.Count(MAXIMUM_CONFIG_BYTES)
    then
      Stream_IO.close (file);
      opened := False;
      return Configuration_Invalid;
    end if;

    Stream_IO.read
      (file,
       buffer
         (buffer'first .. Ada.Streams.Stream_Element_Offset(file_size)),
       last);

    if last /= Ada.Streams.Stream_Element_Offset(file_size) or else
       not Stream_IO.end_of_file (file)
    then
      Stream_IO.close (file);
      opened := False;
      return Configuration_Read_Failed;
    end if;

    Stream_IO.close (file);
    opened := False;

    declare
      source : String (1 .. Natural(file_size));
    begin
      for index in source'range loop
        source(index) := Character'val
          (Integer(buffer(Ada.Streams.Stream_Element_Offset(index))));
      end loop;

      if parse_source (source, result) then
        return Configuration_Loaded;
      end if;
    end;

    result := (others => <>);
    return Configuration_Invalid;
  exception
    when others =>
      if opened then
        begin
          Stream_IO.close (file);
        exception
          when others =>
            null;
        end;
      end if;
      result := (others => <>);
      return Configuration_Read_Failed;
  end load;

end Sonbal.Configuration;
