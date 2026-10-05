-- ============================================================================
-- sonbal-mcp-json.ads
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Interfaces;
with Sonbal.Process_Arguments;

package Sonbal.MCP.JSON is
   Max_Input_Bytes           : constant Positive := 1_048_576;
   Max_Depth                 : constant Positive := 16;
   Max_Tokens                : constant Positive := 512;
   Max_Members_Per_Object   : constant Positive := 32;
   Max_Member_Name_Bytes    : constant Positive := 128;
   Max_Decoded_String_Bytes : constant Positive := 1_024;
   Max_Number_Bytes         : constant Positive := 64;
   Max_Request_Id_Bytes     : constant Positive := 256;

  MAX_RUN_PROCESS_ARGUMENT_COUNT : constant Positive :=
    Sonbal.Process_Arguments.MAXIMUM_ARGUMENT_COUNT;
  MAX_RUN_PROCESS_ARGV_BYTES : constant Positive :=
    Sonbal.Process_Arguments.MAXIMUM_ARGV_BYTES;
  MAX_RUN_PROCESS_ARGUMENT_BYTES : constant Positive :=
    Sonbal.Process_Arguments.MAXIMUM_ARGUMENT_BYTES;
  MAX_RUN_PROCESS_CWD_BYTES : constant Positive :=
    Sonbal.Process_Arguments.MAXIMUM_WORKING_DIRECTORY_BYTES;

   type Parse_Status is
     (Parse_OK,
      Input_Too_Long,
      Invalid_UTF8,
      Invalid_Syntax,
      Too_Deep,
      Too_Many_Tokens,
      Too_Many_Members,
      String_Too_Long,
      Number_Too_Long,
      Duplicate_Member);

   type Value_Kind is
     (Absent,
      Null_Value,
      Boolean_Value,
      Number_Value,
      String_Value,
      Object_Value,
      Array_Value);

   type Id_Kind is (No_Id, String_Id, Number_Id, Invalid_Id);

   type Text is record
      Data   : String (1 .. Max_Decoded_String_Bytes) :=
        [others => Character'val (0)];
      Length : Natural range 0 .. Max_Decoded_String_Bytes := 0;
   end record;

   function Image (Value : Text) return String;

   function Is_Empty (Value : Text) return Boolean;

   function Equals
     (Left  : Text;
      Right : String) return Boolean;

  --! notes:
  --!   The extra byte retains the exact one-byte cwd overflow so the dispatcher
  --!   can reject it as tool parameters without enlarging the ordinary JSON
  --!   text projection.
  type Run_Process_Text is record
    data : String (1 .. MAX_RUN_PROCESS_CWD_BYTES + 1) :=
      [others => Character'val (0)];
    length : Natural range 0 .. MAX_RUN_PROCESS_CWD_BYTES + 1 := 0;
  end record;

  function image (value : Run_Process_Text) return String;

  --! notes:
  --!   One argv element may consume the complete aggregate argv budget. The
  --!   parser reuses one value of this type as scratch storage before copying
  --!   accepted bytes into `Run_Process_Arguments.data`.
  type Run_Process_Argument_Text is record
    data : String (1 .. MAX_RUN_PROCESS_ARGUMENT_BYTES + 1) :=
      [others => Character'val (0)];
    length : Natural range 0 .. MAX_RUN_PROCESS_ARGUMENT_BYTES + 1 := 0;
  end record;

  type Run_Process_Argument_Slice is record
    first  : Natural range 0 .. MAX_RUN_PROCESS_ARGV_BYTES + 1 := 0;
    length : Natural range 0 .. MAX_RUN_PROCESS_ARGUMENT_BYTES + 1 := 0;
  end record;

  type Run_Process_Argument_Slices is array
    (Positive range 1 .. MAX_RUN_PROCESS_ARGUMENT_COUNT + 1)
    of Run_Process_Argument_Slice;

  --! notes:
  --!   Argument bytes share one bounded contiguous store. The extra slice and
  --!   data byte retain one-unit count and aggregate-size overflows for exact
  --!   boundary validation without allocating one 4 KiB buffer per element.
  type Run_Process_Arguments is record
    data : String (1 .. MAX_RUN_PROCESS_ARGV_BYTES + 1) :=
      [others => Character'val (0)];
    stored_bytes : Natural range 0 .. MAX_RUN_PROCESS_ARGV_BYTES + 1 := 0;
    count        : Natural := 0;
    total_bytes  : Natural := 0;
    all_strings  : Boolean := True;
    slices       : Run_Process_Argument_Slices;
  end record;

  function run_process_argument_at
    (value : Run_Process_Arguments;
     index : Positive)
  return String
    with Pre => index <= value.count and then
                index <= value.slices'last and then
                (value.slices(index).length = 0 or else
                   (value.slices(index).first >= value.data'first and then
                    value.slices(index).first +
                      value.slices(index).length - 1 <= value.stored_bytes));

  --! summary Project one parser-owned raw argv into the common validated form.
  --! notes:
  --!   Parser overflow/all-string observations remain JSON-owned. Only an exact
  --!   valid projection can enter the process/runtime capability boundary.
  function project_run_process_arguments
    (value  : Run_Process_Arguments;
     result : out Sonbal.Process_Arguments.Arguments)
  return Boolean;

  --! summary:
  --!   Convert one JSON number spelling to an exact bounded natural number.
  --!
  --! contract:
  --!   Input longer than `Max_Number_Bytes` is rejected without conversion.
  --!
  --! outputs:
  --!   On success, `value` is the exact mathematical integer represented by
  --!   `input`. On failure, `value` is zero.
  --!
  --! returns:
  --!   True only when `input` is a valid JSON number whose mathematical value
  --!   is an integer in `minimum .. maximum`.
  function parse_bounded_unsigned_64
    (input   : String;
     minimum : Interfaces.Unsigned_64;
     maximum : Interfaces.Unsigned_64;
     value   : out Interfaces.Unsigned_64)
  return Boolean;

  function parse_bounded_natural
    (input   : String;
     minimum : Natural;
     maximum : Natural;
     value   : out Natural)
  return Boolean;

   type Message is record
      Root_Kind : Value_Kind := Absent;

      JSONRPC_Kind : Value_Kind := Absent;
      JSONRPC      : Text;

      Method_Kind : Value_Kind := Absent;
      Method      : Text;

      Request_Id_Kind : Id_Kind := No_Id;
      Request_Id_Raw  : Text;

      Params_Kind         : Value_Kind := Absent;
      Params_Member_Count : Natural := 0;
      Params_Has_Unknown  : Boolean := False;

      Meta_Kind : Value_Kind := Absent;

      Meta_Protocol_Version_Kind : Value_Kind := Absent;
      Meta_Protocol_Version      : Text;
      Meta_Protocol_Version_Raw  : Text;

      Meta_Client_Capabilities_Kind : Value_Kind := Absent;

      Meta_Client_Info_Kind    : Value_Kind := Absent;
      Meta_Client_Name_Kind    : Value_Kind := Absent;
      Meta_Client_Name         : Text;
      Meta_Client_Version_Kind : Value_Kind := Absent;
      Meta_Client_Version      : Text;

      Cursor_Kind : Value_Kind := Absent;
      Cursor      : Text;

      Tool_Name_Kind : Value_Kind := Absent;
      Tool_Name      : Text;

      Arguments_Kind         : Value_Kind := Absent;
      Arguments_Member_Count : Natural := 0;
      arguments_has_unknown  : Boolean := False;

      argument_argv_kind : Value_Kind := Absent;
      argument_argv      : Run_Process_Arguments;

      argument_resolution_kind : Value_Kind := Absent;
      argument_resolution      : Text;

      argument_cwd_kind : Value_Kind := Absent;
      argument_cwd      : Run_Process_Text;

      argument_timeout_ms_kind : Value_Kind := Absent;
      argument_timeout_ms_raw  : Text;

      argument_workspace_root_kind : Value_Kind := Absent;
      argument_workspace_root      : Run_Process_Text;

      argument_workspace_token_kind : Value_Kind := Absent;
      argument_workspace_token      : Text;

      argument_path_kind : Value_Kind := Absent;
      argument_path      : Run_Process_Text;

      argument_offset_kind : Value_Kind := Absent;
      argument_offset_raw  : Text;

      argument_maximum_bytes_kind : Value_Kind := Absent;
      argument_maximum_bytes_raw  : Text;

      argument_expected_revision_kind : Value_Kind := Absent;
      argument_expected_revision      : Text;

      argument_operation_id_kind : Value_Kind := Absent;
      argument_operation_id      : Text;

      argument_job_id_kind : Value_Kind := Absent;
      argument_job_id      : Text;

      argument_poll_cursor_kind : Value_Kind := Absent;
      argument_poll_cursor      : Text;

      Input_Responses_Kind : Value_Kind := Absent;
      Request_State_Kind   : Value_Kind := Absent;
   end record;

   --  Result is inspected only when Status is Parse_OK. A failed parse may
   --  leave a bounded partial projection for diagnostics, but callers must not
   --  dispatch from it.
   procedure Parse
     (Input  : String;
      Result : out Message;
      Status : out Parse_Status);
end Sonbal.MCP.JSON;
