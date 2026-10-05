-- ============================================================================
-- sonbal-mcp-dispatcher.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Clair.Base64;
with Clair.Process;
with Clair.Unicode.UTF8;

package body Sonbal.MCP.Dispatcher is

  use type Clair.Status.Code;
  use type Sonbal.MCP.JSON.Id_Kind;
  use type Sonbal.MCP.JSON.Parse_Status;
  use type Sonbal.MCP.JSON.Value_Kind;
  use type Sonbal.File_Read.Read_State;
  use type Sonbal.Process_Jobs.Poll_State;
  use type Sonbal.Process_Jobs.Start_State;
  use type Sonbal.Process_Jobs.Terminal_State;
  use type Sonbal.Workspace_Tokens.Rotation_State;
  use type System.Storage_Elements.Storage_Offset;

   type Error_Kind is
     (Parse_Error,
      Invalid_Request,
      Method_Not_Found,
      Invalid_Params);

   Server_Info_Meta : constant String :=
     """_meta"":{""io.modelcontextprotocol/serverInfo"":{" &
     """name"":""" & Server_Name & """," &
     """version"":""" & Server_Version & """}}";

   Discover_Result_Suffix : constant String :=
     ",""result"":{""resultType"":""complete""," &
     """supportedVersions"":[""" & Protocol_Version & """]," &
     """capabilities"":{""tools"":{}}," &
     Server_Info_Meta & ",""ttlMs"":0,""cacheScope"":""private""}}";

  EMPTY_TOOL_INPUT_SCHEMA : constant String :=
    "{""type"":""object"",""properties"":{}," &
    """additionalProperties"":false}";

  PING_OUTPUT_SCHEMA : constant String :=
    "{""type"":""object"",""properties"":{""version"":{" &
    """type"":""string"",""pattern"":""^[0-9]{4}\\.[0-9]{2}\\." &
    "[0-9]{2}$""},""revision"":{""type"":""string""," &
    """pattern"":""^[0-9]{6}$""}},""required"":[""version""," &
    """revision""],""additionalProperties"":false}";

  PING_ANNOTATIONS : constant String :=
    "{""readOnlyHint"":true,""destructiveHint"":false," &
    """idempotentHint"":true,""openWorldHint"":false}";

  PING_TOOL_DESCRIPTOR : constant String :=
    "{""name"":""ping"",""description"":""" &
    "Verifies the Sonbal MCP round trip and reports release version and " &
    "revision." &
    """,""inputSchema"":" &
    EMPTY_TOOL_INPUT_SCHEMA &
    ",""outputSchema"":" & PING_OUTPUT_SCHEMA &
    ",""annotations"":" &
    PING_ANNOTATIONS &
    "}";

  TOOLS_LIST_RESULT_SUFFIX : constant String :=
    ",""result"":{""resultType"":""complete"",""tools"":[" &
    PING_TOOL_DESCRIPTOR & "," &
    ROTATE_WORKSPACE_TOKEN_TOOL_DESCRIPTOR & "," &
    RUN_PROCESS_TOOL_DESCRIPTOR & "," &
    START_PROCESS_TOOL_DESCRIPTOR & "," &
    POLL_PROCESS_TOOL_DESCRIPTOR & "," &
    CANCEL_PROCESS_TOOL_DESCRIPTOR & "," &
    READ_FILE_TOOL_DESCRIPTOR & "]," &
    SERVER_INFO_META &
    ",""ttlMs"":0,""cacheScope"":""private""}}";

   Ping_Result_Suffix : constant String :=
     ",""result"":{""resultType"":""complete""," &
     """content"":[{""type"":""text"",""text"":""" &
     Server_Name & " " & Server_Version & "-" & Server_Revision & """}]," &
     """structuredContent"":{""version"":""" & Server_Version &
     """,""revision"":""" & Server_Revision & """}," &
     """isError"":false," & Server_Info_Meta & "}}";

  function image (value : Response_Text) return String is
  begin
    if value.length = 0 then
      return "";
    end if;

    return value.data (1 .. value.length);
  end Image;

  function length (value : Response_Text) return Natural is
    (value.length);

  procedure copy_response
    (value  : in Response_Text;
     offset : in Natural;
     target : out String;
     copied : out Natural)
  is
    available : Natural;
  begin
    copied := 0;
    if target'length = 0 or else offset >= value.length then
      return;
    end if;

    available := Natural'Min (target'length, value.length - offset);
    target(target'first .. target'first + available - 1) :=
      value.data(1 + offset .. offset + available);
    copied := available;
  end copy_response;

  function is_empty (value : Response_Text) return Boolean is
    (value.length = 0);

  function current_state (self : Context) return Dispatcher_State is
    (self.State);

  procedure clear_result (result : out Dispatch_Result) is
  begin
    result.action := No_Action;
    result.response.length := 0;
    result.request_id := (others => <>);
    result.notification := False;
    result.diagnostic_action := No_Action;
    result.diagnostic_correlation := 0;
    result.rotate_workspace_token := (others => <>);
    result.read_file := (others => <>);
    result.run_process := (others => <>);
    result.start_process := (others => <>);
    result.poll_process := (others => <>);
    result.cancel_process := (others => <>);
  end clear_result;

  procedure clear_result_for_completion
    (result : in out Dispatch_Result)
  is
    diagnostic_action : constant Action_Kind := result.diagnostic_action;
    diagnostic_correlation : constant Interfaces.Unsigned_64 :=
      result.diagnostic_correlation;
  begin
    clear_result (result);
    result.diagnostic_action := diagnostic_action;
    result.diagnostic_correlation := diagnostic_correlation;
  end clear_result_for_completion;

  procedure fail_internal
    (self : in out Context;
     result  : in out Dispatch_Result)
  is
  begin
    clear_result (result);
    result.action := Fatal_Error;
    self.state := Stopping;
  end fail_internal;

  procedure append_response
    (target    : in out Response_Text;
     item      : String;
     succeeded : in out Boolean)
  is
  begin
    if not succeeded then
      return;
    end if;

    if item'length > MAXIMUM_MCP_RESPONSE_BYTES - target.length then
      succeeded := False;
      return;
    end if;

    if item'length = 0 then
      return;
    end if;

    target.data (target.length + 1 .. target.length + item'length) := item;
    target.length := target.length + item'length;
  end append_response;

  MAXIMUM_RUN_PROCESS_CAPTURE_BYTES : constant Positive := 32_768;

  function compact_image (value : String) return String is
  begin
    if value'length > 0 and then value(value'first) = ' ' then
      return value(value'first + 1 .. value'last);
    end if;

    return value;
  end compact_image;

  function json_escaped_length (value : String) return Natural is
    total : Natural := 0;
  begin
    for item of value loop
      case Character'pos (item) is
        when 8 | 9 | 10 | 12 | 13 | 34 | 92 =>
          total := total + 2;
        when 0 .. 7 | 11 | 14 .. 31 =>
          total := total + 6;
        when others =>
          total := total + 1;
      end case;
    end loop;

    return total;
  end json_escaped_length;

  procedure append_json_escaped
    (target    : in out Response_Text;
     value     : String;
     succeeded : in out Boolean)
  is
    segment_first : Integer := value'first;

    procedure append_escape (item : Character) is
      escape : String (1 .. 6) := [others => Character'val (0)];
      code   : constant Natural := Character'pos (item);
      HEX_DIGITS : constant String := "0123456789abcdef";
    begin
      escape(1) := Character'val (92);

      case code is
        when 8 =>
          escape(2) := 'b';
          append_response (target, escape(1 .. 2), succeeded);
        when 9 =>
          escape(2) := 't';
          append_response (target, escape(1 .. 2), succeeded);
        when 10 =>
          escape(2) := 'n';
          append_response (target, escape(1 .. 2), succeeded);
        when 12 =>
          escape(2) := 'f';
          append_response (target, escape(1 .. 2), succeeded);
        when 13 =>
          escape(2) := 'r';
          append_response (target, escape(1 .. 2), succeeded);
        when 34 =>
          escape(2) := Character'val (34);
          append_response (target, escape(1 .. 2), succeeded);
        when 92 =>
          escape(2) := Character'val (92);
          append_response (target, escape(1 .. 2), succeeded);
        when 0 .. 7 | 11 | 14 .. 31 =>
          escape(2) := 'u';
          escape(3) := '0';
          escape(4) := '0';
          escape(5) := HEX_DIGITS(code / 16 + 1);
          escape(6) := HEX_DIGITS(code mod 16 + 1);
          append_response (target, escape, succeeded);
        when others =>
          succeeded := False;
      end case;
    end append_escape;
  begin
    for index in value'range loop
      if Character'pos (value(index)) <= 31 or else
         Character'pos (value(index)) = 34 or else
         Character'pos (value(index)) = 92
      then
        if segment_first <= index - 1 then
          append_response
            (target, value(segment_first .. index - 1), succeeded);
        end if;

        append_escape (value(index));
        segment_first := index + 1;
      end if;
    end loop;

    if segment_first <= value'last then
      append_response (target, value(segment_first .. value'last), succeeded);
    end if;
  end append_json_escaped;

  procedure append_encoded_byte_fields
    (target    : in out Response_Text;
     data      : System.Storage_Elements.Storage_Array;
     length    : Natural;
     maximum   : Natural;
     succeeded : in out Boolean)
  is
    encoded_length : Natural;
  begin
    if not succeeded then
      return;
    elsif length > maximum or else length > data'length then
      succeeded := False;
      return;
    end if;

    encoded_length := 4 * ((length + 2) / 3);

    if length = 0 then
      append_response
        (target,
         """encoding"":""utf8"",""bytes"":0,""data"":""""",
         succeeded);
      return;
    end if;

    declare
      text : String (1 .. length);
    begin
      for index in text'range loop
        text(index) := Character'val
          (Integer
             (data
                (data'first +
                 System.Storage_Elements.Storage_Offset(index - 1))));
      end loop;

      if Clair.Unicode.UTF8.validate (text) = Clair.Status.OK and then
         json_escaped_length (text) <= encoded_length
      then
        append_response
          (target,
           """encoding"":""utf8"",""bytes"":" &
             compact_image (Natural'image (length)) &
             ",""data"":""",
           succeeded);
        append_json_escaped (target, text, succeeded);
        append_response (target, """", succeeded);
        return;
      end if;
    end;

    declare
      encoded : String (1 .. MAXIMUM_RUN_PROCESS_STREAM_DATA_BYTES) :=
        [others => Character'val (0)];
      actual_length : Natural := 0;
      status : Clair.Status.Code;
    begin
      status := Clair.Base64.encode
        (input  =>
           data
             (data'first ..
              data'first +
                System.Storage_Elements.Storage_Offset(length - 1)),
         output        => encoded,
         output_length => actual_length);
      if status /= Clair.Status.OK or else actual_length /= encoded_length then
        succeeded := False;
        return;
      end if;

      append_response
        (target,
         """encoding"":""base64"",""bytes"":" &
           compact_image (Natural'image (length)) &
           ",""data"":""",
         succeeded);
      append_response (target, encoded(1 .. actual_length), succeeded);
      append_response (target, """", succeeded);
    end;
  end append_encoded_byte_fields;

  procedure append_run_process_stream
    (target    : in out Response_Text;
     data      : System.Storage_Elements.Storage_Array;
     length    : Natural;
     truncated : Boolean;
     succeeded : in out Boolean)
  is
  begin
    append_response (target, "{", succeeded);
    append_encoded_byte_fields
      (target,
       data,
       length,
       MAXIMUM_RUN_PROCESS_CAPTURE_BYTES,
       succeeded);
    append_response
      (target,
       ",""truncated"":" &
         (if truncated then "true" else "false") & "}",
       succeeded);
  end append_run_process_stream;

  procedure append_read_file_content
    (target    : in out Response_Text;
     data      : System.Storage_Elements.Storage_Array;
     length    : Natural;
     succeeded : in out Boolean)
  is
  begin
    append_response (target, "{", succeeded);
    append_encoded_byte_fields
      (target,
       data,
       length,
       Sonbal.File_Read.MAXIMUM_CONTENT_BYTES,
       succeeded);
    append_response (target, "}", succeeded);
  end append_read_file_content;

  type Run_Process_Stream_Kind is
    (Standard_Output_Stream,
     Standard_Error_Stream);

  function launch_stage_image
    (stage : Clair.Process.Execution.Launch_Stage)
  return String
  is
  begin
    case stage is
      when Clair.Process.Execution.Executable_Resolution_Stage =>
        return "executable_resolution";
      when Clair.Process.Execution.Working_Directory_Stage =>
        return "working_directory";
      when Clair.Process.Execution.Standard_Stream_Stage =>
        return "standard_stream";
      when Clair.Process.Execution.Environment_Construction_Stage =>
        return "environment_construction";
      when Clair.Process.Execution.Program_Execution_Stage =>
        return "program_execution";
    end case;
  end launch_stage_image;

  function infrastructure_stage_image
    (stage : Clair.Process.Execution.Infrastructure_Stage)
  return String
  is
  begin
    case stage is
      when Clair.Process.Execution.Execution_Preparation_Stage =>
        return "execution_preparation";
      when Clair.Process.Execution.Process_Creation_Stage =>
        return "process_creation";
      when Clair.Process.Execution.Process_Monitoring_Stage =>
        return "process_monitoring";
      when Clair.Process.Execution.Process_Termination_Stage =>
        return "process_termination";
      when Clair.Process.Execution.Output_Drain_Stage =>
        return "output_drain";
      when Clair.Process.Execution.Process_Wait_Stage =>
        return "process_wait";
      when Clair.Process.Execution.Resource_Cleanup_Stage =>
        return "resource_cleanup";
    end case;
  end infrastructure_stage_image;

  function ownership_stage_image
    (stage : Clair.Process.Execution.Ownership_Failure_Stage)
  return String
  is
  begin
    case stage is
      when Clair.Process.Execution.Ownership_Setup_Stage =>
        return "setup";
      when Clair.Process.Execution.Ownership_Launch_Stage =>
        return "launch";
      when Clair.Process.Execution.Ownership_Settlement_Stage =>
        return "settlement";
    end case;
  end ownership_stage_image;

  function classify_run_process_failure
    (status_failed         : Boolean;
     infrastructure_failed : Boolean;
     cleanup_failed        : Boolean)
  return Run_Process_Failure_Kind
  is
  begin
    if infrastructure_failed then
      return Run_Process_Infrastructure_Failure;
    elsif cleanup_failed then
      return Run_Process_Cleanup_Failure;
    elsif status_failed then
      return Run_Process_Status_Failure;
    end if;
    return Run_Process_No_Failure;
  end classify_run_process_failure;

  procedure append_empty_run_process_stream
    (target    : in out Response_Text;
     succeeded : in out Boolean;
     truncated : Boolean := False)
  is
    empty : constant System.Storage_Elements.Storage_Array (1 .. 1)
          := [others => 0];
  begin
    append_run_process_stream
      (target,
       data      => empty,
       length    => 0,
       truncated => truncated,
       succeeded => succeeded);
  end append_empty_run_process_stream;

  procedure append_process_result_stream
    (target    : in out Response_Text;
     outcome   : Clair.Process.Execution.Result;
     kind      : Run_Process_Stream_Kind;
     succeeded : in out Boolean)
  is
    length : constant Natural :=
      (case kind is
         when Standard_Output_Stream =>
           Clair.Process.Execution.standard_output_length (outcome),
         when Standard_Error_Stream =>
           Clair.Process.Execution.standard_error_length (outcome));
    truncated : constant Boolean :=
      (case kind is
         when Standard_Output_Stream =>
           Clair.Process.Execution.is_standard_output_truncated (outcome),
         when Standard_Error_Stream =>
           Clair.Process.Execution.is_standard_error_truncated (outcome));
    copied : Natural := 0;
    status : Clair.Status.Code;
  begin
    if length > MAXIMUM_RUN_PROCESS_CAPTURE_BYTES then
      succeeded := False;
      return;
    elsif length = 0 then
      append_empty_run_process_stream
        (target, succeeded, truncated => truncated);
      return;
    end if;

    declare
      data : System.Storage_Elements.Storage_Array
        (1 .. System.Storage_Elements.Storage_Offset(length)) :=
          [others => 0];
    begin
      case kind is
        when Standard_Output_Stream =>
          status := Clair.Process.Execution.copy_standard_output
            (outcome => outcome,
             offset => 0,
             buffer => data,
             copied => copied);
        when Standard_Error_Stream =>
          status := Clair.Process.Execution.copy_standard_error
            (outcome => outcome,
             offset => 0,
             buffer => data,
             copied => copied);
      end case;

      if status /= Clair.Status.OK or else copied /= length then
        succeeded := False;
        return;
      end if;

      append_run_process_stream
        (target,
         data      => data,
         length    => length,
         truncated => truncated,
         succeeded => succeeded);
    end;
  end append_process_result_stream;

  procedure append_run_process_prefix
    (target     : in out Response_Text;
     request_id : Sonbal.MCP.JSON.Text;
     status     : String;
     succeeded  : in out Boolean)
  is
  begin
    append_response
      (target, "{""jsonrpc"":""2.0"",""id"":", succeeded);
    append_response
      (target, Sonbal.MCP.JSON.image (request_id), succeeded);
    append_response
      (target,
       ",""result"":{""resultType"":""complete""," &
         """content"":[{""type"":""text"",""text"":""" & status &
         """}],""structuredContent"":{""status"":""" & status &
         """,""stdout"":" ,
       succeeded);
  end append_run_process_prefix;

  procedure append_run_process_suffix
    (target          : in out Response_Text;
     is_error        : Boolean;
     extra_name      : String;
     extra_value     : String;
     extra_is_string : Boolean;
     succeeded       : in out Boolean;
     ownership_stage : String := "")
  is
  begin
    if extra_name'length > 0 then
      append_response
        (target, ",""" & extra_name & """:", succeeded);
      if extra_is_string then
        append_response (target, """", succeeded);
      end if;
      append_response (target, extra_value, succeeded);
      if extra_is_string then
        append_response (target, """", succeeded);
      end if;
    end if;

    if ownership_stage'length > 0 then
      append_response
        (target,
         ",""ownership_stage"":""" & ownership_stage & """",
         succeeded);
    end if;

    append_response
      (target,
       "},""isError"":" & (if is_error then "true" else "false") & "," &
         Server_Info_Meta & "}}",
       succeeded);
  end append_run_process_suffix;

   function Error_Code (Kind : Error_Kind) return String is
   begin
      case Kind is
         when Parse_Error =>
            return "-32700";
         when Invalid_Request =>
            return "-32600";
         when Method_Not_Found =>
            return "-32601";
         when Invalid_Params =>
            return "-32602";
      end case;
   end Error_Code;

   function error_message (Kind : Error_Kind) return String is
   begin
      case Kind is
         when Parse_Error =>
            return "Parse error";
         when Invalid_Request =>
            return "Invalid Request";
         when Method_Not_Found =>
            return "Method not found";
         when Invalid_Params =>
            return "Invalid params";
      end case;
   end error_message;

  procedure finish_response
    (self   : in out Context;
     result    : in out Dispatch_Result;
     succeeded : Boolean)
  is
  begin
    if succeeded then
      result.action := Write_Response;
    else
      fail_internal (self, result);
    end if;
  end finish_response;

  procedure build_error
    (self    : in out Context;
     result     : in out Dispatch_Result;
     kind       : Error_Kind;
     request_id : Sonbal.MCP.JSON.Text;
     include_id : Boolean)
  is
    succeeded : Boolean := True;
  begin
    result.response.length := 0;
    append_response (result.response, "{""jsonrpc"":""2.0""", succeeded);

    append_response (result.response, ",""id"":", succeeded);
    if include_id then
      append_response
        (result.response,
         Sonbal.MCP.JSON.Image (request_id),
         succeeded);
    else
      append_response (result.response, "null", succeeded);
    end if;

    append_response (result.response, ",""error"":{""code"":", succeeded);
    append_response (result.response, Error_Code (kind), succeeded);
    append_response (result.response, ",""message"":""", succeeded);
    append_response (result.response, error_message (kind), succeeded);
    append_response (result.response, """}}", succeeded);
    finish_response (self, result, succeeded);
  end build_error;

   procedure build_unsupported_protocol_version
     (self : in out Context;
      result  : in out Dispatch_Result;
      message : Sonbal.MCP.JSON.Message)
   is
      succeeded : Boolean := True;
   begin
      result.response.length := 0;
      append_response
        (result.response, "{""jsonrpc"":""2.0"",""id"":", succeeded);
      append_response
        (result.response,
         Sonbal.MCP.JSON.Image (message.Request_Id_Raw),
         succeeded);
      append_response
        (result.response,
         ",""error"":{""code"":-32022," &
           """message"":""Unsupported protocol version""," &
           """data"":{""supported"":[""" & Protocol_Version &
           """],""requested"":",
         succeeded);
      append_response
        (result.response,
         Sonbal.MCP.JSON.Image (message.Meta_Protocol_Version_Raw),
         succeeded);
      append_response (result.response, "}}}", succeeded);
      finish_response (self, result, succeeded);
   end build_unsupported_protocol_version;

   procedure build_result
     (self    : in out Context;
      result     : in out Dispatch_Result;
      request_id : Sonbal.MCP.JSON.Text;
      suffix     : String)
   is
      succeeded : Boolean := True;
   begin
      result.response.length := 0;
      append_response
        (result.response, "{""jsonrpc"":""2.0"",""id"":", succeeded);
      append_response
        (result.response,
         Sonbal.MCP.JSON.Image (request_id),
         succeeded);
      append_response (result.response, suffix, succeeded);
      finish_response (self, result, succeeded);
   end build_result;

   function has_response_id
     (message : Sonbal.MCP.JSON.Message) return Boolean
   is
     (message.Request_Id_Kind = Sonbal.MCP.JSON.String_Id
      or else message.Request_Id_Kind = Sonbal.MCP.JSON.Number_Id);

   function client_info_is_valid
     (message : Sonbal.MCP.JSON.Message) return Boolean
   is
   begin
      if message.Meta_Client_Info_Kind = Sonbal.MCP.JSON.Absent then
         return True;
      end if;

      return message.Meta_Client_Info_Kind = Sonbal.MCP.JSON.Object_Value
        and then message.Meta_Client_Name_Kind = Sonbal.MCP.JSON.String_Value
        and then
          message.Meta_Client_Version_Kind = Sonbal.MCP.JSON.String_Value;
   end client_info_is_valid;

   function request_meta_is_valid
     (message : Sonbal.MCP.JSON.Message) return Boolean
   is
   begin
      return message.Params_Kind = Sonbal.MCP.JSON.Object_Value
        and then message.Meta_Kind = Sonbal.MCP.JSON.Object_Value
        and then
          message.Meta_Protocol_Version_Kind = Sonbal.MCP.JSON.String_Value
        and then
          message.Meta_Client_Capabilities_Kind =
            Sonbal.MCP.JSON.Object_Value
        and then client_info_is_valid (message);
   end request_meta_is_valid;

   function protocol_is_supported
     (message : Sonbal.MCP.JSON.Message) return Boolean
   is
     (Sonbal.MCP.JSON.Equals
        (message.Meta_Protocol_Version, Protocol_Version));

   function discover_params_are_valid
     (message : Sonbal.MCP.JSON.Message) return Boolean
   is
   begin
      return not message.Params_Has_Unknown
        and then message.Cursor_Kind = Sonbal.MCP.JSON.Absent
        and then message.Tool_Name_Kind = Sonbal.MCP.JSON.Absent
        and then message.Arguments_Kind = Sonbal.MCP.JSON.Absent
        and then message.Input_Responses_Kind = Sonbal.MCP.JSON.Absent
        and then message.Request_State_Kind = Sonbal.MCP.JSON.Absent;
   end discover_params_are_valid;

   function tools_list_params_are_valid
     (message : Sonbal.MCP.JSON.Message) return Boolean
   is
   begin
      return not message.Params_Has_Unknown
        and then message.Tool_Name_Kind = Sonbal.MCP.JSON.Absent
        and then message.Arguments_Kind = Sonbal.MCP.JSON.Absent
        and then message.Input_Responses_Kind = Sonbal.MCP.JSON.Absent
        and then message.Request_State_Kind = Sonbal.MCP.JSON.Absent
        and then
          (message.Cursor_Kind = Sonbal.MCP.JSON.Absent
           or else
             (message.Cursor_Kind = Sonbal.MCP.JSON.String_Value
              and then Sonbal.MCP.JSON.Is_Empty (message.Cursor)));
   end tools_list_params_are_valid;

  function tools_call_params_are_valid
    (message : Sonbal.MCP.JSON.Message) return Boolean
  is
  begin
    return not message.Params_Has_Unknown
      and then message.Cursor_Kind = Sonbal.MCP.JSON.Absent
      and then message.Tool_Name_Kind = Sonbal.MCP.JSON.String_Value
      and then
        (message.Input_Responses_Kind = Sonbal.MCP.JSON.Absent
          or else
            message.Input_Responses_Kind = Sonbal.MCP.JSON.Object_Value)
      and then
        (message.Request_State_Kind = Sonbal.MCP.JSON.Absent
          or else
            message.Request_State_Kind = Sonbal.MCP.JSON.String_Value);
  end tools_call_params_are_valid;

  function empty_arguments_are_valid
    (message : Sonbal.MCP.JSON.Message)
  return Boolean
  is
  begin
    return message.Arguments_Kind = Sonbal.MCP.JSON.Absent
      or else
        (message.Arguments_Kind = Sonbal.MCP.JSON.Object_Value
         and then message.Arguments_Member_Count = 0
         and then not message.arguments_has_unknown);
  end empty_arguments_are_valid;

  function arguments_object_is_valid
    (message      : Sonbal.MCP.JSON.Message;
     member_count : Natural)
  return Boolean
  is
  begin
    return message.Arguments_Kind = Sonbal.MCP.JSON.Object_Value
      and then not message.arguments_has_unknown
      and then message.Arguments_Member_Count = member_count;
  end arguments_object_is_valid;

  function contains_nul (value : String) return Boolean is
  begin
    for item of value loop
      if item = Character'val (0) then
        return True;
      end if;
    end loop;

    return False;
  end contains_nul;

  function supported_absolute_cwd (value : String) return Boolean is
    (value'length > 0 and then value(value'first) = '/');

  function opaque_identifier_is_valid
    (value        : Sonbal.MCP.JSON.Text;
     prefix       : String;
     exact_length : Positive)
  return Boolean
  is
    text : constant String := Sonbal.MCP.JSON.image(value);
  begin
    if text'length /= exact_length or else
       prefix'length = 0 or else prefix'length >= exact_length or else
       text(text'first .. text'first + prefix'length - 1) /= prefix
    then
      return False;
    end if;

    for index in text'first + prefix'length .. text'last loop
      if text(index) not in '0' .. '9' | 'a' .. 'f' then
        return False;
      end if;
    end loop;
    return True;
  end opaque_identifier_is_valid;

  function workspace_root_is_valid
    (kind  : Sonbal.MCP.JSON.Value_Kind;
     value : Sonbal.MCP.JSON.Run_Process_Text)
  return Boolean
  is
    text : constant String := Sonbal.MCP.JSON.image(value);
  begin
    return kind = Sonbal.MCP.JSON.String_Value and then
      value.length in
        1 .. Sonbal.Workspace_Tokens.MAXIMUM_WORKSPACE_PATH_BYTES and then
      not contains_nul(text) and then supported_absolute_cwd(text);
  end workspace_root_is_valid;

  function rotate_workspace_token_projection_is_valid
    (message : Sonbal.MCP.JSON.Message;
     result  : in out Dispatch_Result)
  return Boolean
  is
  begin
    if (not arguments_object_is_valid (message, 1) and then
        not arguments_object_is_valid (message, 2)) or else
       not workspace_root_is_valid
         (message.argument_workspace_root_kind,
          message.argument_workspace_root) or else
       (message.argument_operation_id_kind /= Sonbal.MCP.JSON.Absent and then
          (message.argument_operation_id_kind /=
             Sonbal.MCP.JSON.String_Value or else
           not opaque_identifier_is_valid
             (message.argument_operation_id,
              "o-",
              Sonbal.Workspace_Tokens.MAXIMUM_OPERATION_ID_BYTES)))
    then
      return False;
    end if;

    result.rotate_workspace_token.root := message.argument_workspace_root;
    if message.argument_operation_id_kind = Sonbal.MCP.JSON.String_Value then
      result.rotate_workspace_token.operation_id :=
        message.argument_operation_id;
    end if;
    return True;
  end rotate_workspace_token_projection_is_valid;


  function process_projection_is_valid
    (message         : Sonbal.MCP.JSON.Message;
     maximum_timeout : Positive;
     request         : out Run_Process_Request)
  return Boolean
  is
    timeout_ms : Natural := 0;
  begin
    request := (others => <>);
    if not arguments_object_is_valid(message, 5) or else
       message.argument_workspace_token_kind /=
         Sonbal.MCP.JSON.String_Value or else
       not opaque_identifier_is_valid
         (message.argument_workspace_token,
          "w-",
          Sonbal.Workspace_Tokens.MAXIMUM_WORKSPACE_TOKEN_BYTES) or else
       message.argument_argv_kind /= Sonbal.MCP.JSON.Array_Value
    then
      return False;
    end if;

    if not Sonbal.MCP.JSON.project_run_process_arguments
      (message.argument_argv, request.argv)
    then
      return False;
    end if;

    if message.argument_resolution_kind /= Sonbal.MCP.JSON.String_Value or else
       message.argument_cwd_kind /= Sonbal.MCP.JSON.String_Value or else
       message.argument_cwd.length not in
         1 .. Sonbal.MCP.JSON.MAX_RUN_PROCESS_CWD_BYTES or else
       contains_nul(Sonbal.MCP.JSON.image(message.argument_cwd)) or else
       not supported_absolute_cwd
         (Sonbal.MCP.JSON.image(message.argument_cwd)) or else
       message.argument_timeout_ms_kind /= Sonbal.MCP.JSON.Number_Value or else
       not Sonbal.MCP.JSON.parse_bounded_natural
         (Sonbal.MCP.JSON.image(message.argument_timeout_ms_raw),
          1,
          maximum_timeout,
          timeout_ms)
    then
      return False;
    end if;

    if Sonbal.MCP.JSON.equals(message.argument_resolution, "exact_path") then
      request.resolution := Exact_Path;
    elsif Sonbal.MCP.JSON.equals
      (message.argument_resolution, "search_path")
    then
      request.resolution := Search_Path;
    else
      return False;
    end if;

    request.workspace_token := message.argument_workspace_token;
    request.cwd := message.argument_cwd;
    request.timeout_ms := timeout_ms;
    return True;
  end process_projection_is_valid;

  function read_file_projection_is_valid
    (message : Sonbal.MCP.JSON.Message;
     result  : in out Dispatch_Result)
  return Boolean
  is
    request : Read_File_Request;
    member_count : Natural := 2;
    wide_offset : Interfaces.Unsigned_64 := 0;
    maximum_bytes : Natural := Sonbal.File_Read.MAXIMUM_CONTENT_BYTES;
  begin
    if message.argument_offset_kind /= Sonbal.MCP.JSON.Absent then
      member_count := member_count + 1;
    end if;
    if message.argument_maximum_bytes_kind /= Sonbal.MCP.JSON.Absent then
      member_count := member_count + 1;
    end if;
    if message.argument_expected_revision_kind /= Sonbal.MCP.JSON.Absent then
      member_count := member_count + 1;
    end if;

    if not arguments_object_is_valid (message, member_count) or else
       message.argument_workspace_token_kind /=
         Sonbal.MCP.JSON.String_Value or else
       not opaque_identifier_is_valid
         (message.argument_workspace_token,
          "w-",
          Sonbal.Workspace_Tokens.MAXIMUM_WORKSPACE_TOKEN_BYTES) or else
       message.argument_path_kind /= Sonbal.MCP.JSON.String_Value or else
       not Sonbal.File_Read.is_valid_path
         (Sonbal.MCP.JSON.image(message.argument_path))
    then
      return False;
    end if;

    if message.argument_offset_kind /= Sonbal.MCP.JSON.Absent then
      if message.argument_offset_kind /= Sonbal.MCP.JSON.Number_Value or else
         not Sonbal.MCP.JSON.parse_bounded_unsigned_64
           (Sonbal.MCP.JSON.image(message.argument_offset_raw),
            0,
            Interfaces.Unsigned_64
              (Sonbal.File_Read.MAXIMUM_PUBLIC_FILE_OFFSET),
            wide_offset)
      then
        return False;
      end if;
    end if;

    if message.argument_maximum_bytes_kind /= Sonbal.MCP.JSON.Absent then
      if message.argument_maximum_bytes_kind /=
           Sonbal.MCP.JSON.Number_Value or else
         not Sonbal.MCP.JSON.parse_bounded_natural
           (Sonbal.MCP.JSON.image(message.argument_maximum_bytes_raw),
            1,
            Sonbal.File_Read.MAXIMUM_CONTENT_BYTES,
            maximum_bytes)
      then
        return False;
      end if;
    end if;

    if message.argument_expected_revision_kind /= Sonbal.MCP.JSON.Absent and then
       (message.argument_expected_revision_kind /=
          Sonbal.MCP.JSON.String_Value or else
        not Sonbal.File_Read.is_valid_revision
          (Sonbal.MCP.JSON.image(message.argument_expected_revision)))
    then
      return False;
    end if;

    request.workspace_token := message.argument_workspace_token;
    request.path := message.argument_path;
    request.offset := Clair.IO.File_Offset(wide_offset);
    request.maximum_bytes := Positive(maximum_bytes);
    if message.argument_expected_revision_kind = Sonbal.MCP.JSON.String_Value
    then
      request.expected_revision := message.argument_expected_revision;
    end if;
    result.read_file := request;
    return True;
  end read_file_projection_is_valid;

  function run_process_projection_is_valid
    (message : Sonbal.MCP.JSON.Message;
     result  : in out Dispatch_Result)
  return Boolean
  is
  begin
    return process_projection_is_valid
      (message,
       MAXIMUM_RUN_PROCESS_TIMEOUT_MS,
       result.run_process);
  end run_process_projection_is_valid;

  function start_process_projection_is_valid
    (message : Sonbal.MCP.JSON.Message;
     result  : in out Dispatch_Result)
  return Boolean
  is
  begin
    return process_projection_is_valid
      (message, MAXIMUM_START_PROCESS_TIMEOUT_MS, result.start_process);
  end start_process_projection_is_valid;

  function poll_process_projection_is_valid
    (message : Sonbal.MCP.JSON.Message;
     result  : in out Dispatch_Result)
  return Boolean
  is
    cursor : constant String :=
      Sonbal.MCP.JSON.image(message.argument_poll_cursor);
  begin
    if not arguments_object_is_valid(message, 2) or else
       message.argument_job_id_kind /= Sonbal.MCP.JSON.String_Value or else
       not opaque_identifier_is_valid
         (message.argument_job_id,
          "j-",
          Sonbal.Process_Jobs.MAXIMUM_JOB_ID_BYTES) or else
       message.argument_poll_cursor_kind /= Sonbal.MCP.JSON.String_Value or else
       cursor'length not in
         1 .. Sonbal.Process_Jobs.MAXIMUM_CURSOR_BYTES or else
       contains_nul(cursor)
    then
      return False;
    end if;

    result.poll_process.job_id := message.argument_job_id;
    result.poll_process.cursor := message.argument_poll_cursor;
    return True;
  end poll_process_projection_is_valid;

  function cancel_process_projection_is_valid
    (message : Sonbal.MCP.JSON.Message;
     result  : in out Dispatch_Result)
  return Boolean
  is
  begin
    if not arguments_object_is_valid(message, 1) or else
       message.argument_job_id_kind /= Sonbal.MCP.JSON.String_Value or else
       not opaque_identifier_is_valid
         (message.argument_job_id,
          "j-",
          Sonbal.Process_Jobs.MAXIMUM_JOB_ID_BYTES)
    then
      return False;
    end if;

    result.cancel_process.job_id := message.argument_job_id;
    return True;
  end cancel_process_projection_is_valid;

  procedure begin_tool
    (result     : in out Dispatch_Result;
     request_id : Sonbal.MCP.JSON.Text;
     action     : Action_Kind)
  is
  begin
    result.action     := action;
    result.request_id := request_id;
  end begin_tool;

   procedure reject_request
     (self : in out Context;
      result  : in out Dispatch_Result;
      message : Sonbal.MCP.JSON.Message;
      kind    : Error_Kind)
   is
   begin
      build_error
        (self,
         result,
         kind,
         message.Request_Id_Raw,
         has_response_id (message));
   end reject_request;

  procedure handle_request
    (self : in out Context;
     message : Sonbal.MCP.JSON.Message;
     result  : in out Dispatch_Result)
  is
  begin
    if not request_meta_is_valid (message) then
      reject_request (self, result, message, Invalid_Params);
      return;
    end if;

    if not protocol_is_supported (message) then
      build_unsupported_protocol_version (self, result, message);
      return;
    end if;

    if Sonbal.MCP.JSON.Equals (message.Method, "server/discover") then
      if not discover_params_are_valid (message) then
        reject_request (self, result, message, Invalid_Params);
      else
        build_result
          (self,
           result,
           message.Request_Id_Raw,
           Discover_Result_Suffix);
      end if;
    elsif Sonbal.MCP.JSON.Equals (message.Method, "tools/list") then
      if not tools_list_params_are_valid (message) then
        reject_request (self, result, message, Invalid_Params);
      else
        build_result
          (self,
           result,
           message.Request_Id_Raw,
           TOOLS_LIST_RESULT_SUFFIX);
      end if;
    elsif Sonbal.MCP.JSON.Equals (message.Method, "tools/call") then
      if not tools_call_params_are_valid (message) then
        reject_request (self, result, message, Invalid_Params);
      elsif Sonbal.MCP.JSON.Equals (message.Tool_Name, "ping") then
        if not empty_arguments_are_valid (message) then
          reject_request (self, result, message, Invalid_Params);
        else
          begin_tool
            (result,
             message.Request_Id_Raw,
             Invoke_Ping);
        end if;
      elsif Sonbal.MCP.JSON.Equals
        (message.Tool_Name, "rotate_workspace_token")
      then
        if not rotate_workspace_token_projection_is_valid (message, result) then
          reject_request (self, result, message, Invalid_Params);
        else
          begin_tool
            (result,
             message.Request_Id_Raw,
             Invoke_Rotate_Workspace_Token);
        end if;
      elsif Sonbal.MCP.JSON.Equals(message.Tool_Name, "run_process") then
        if not run_process_projection_is_valid(message, result) then
          reject_request(self, result, message, Invalid_Params);
        else
          begin_tool(result, message.Request_Id_Raw, Invoke_Run_Process);
        end if;
      elsif Sonbal.MCP.JSON.Equals(message.Tool_Name, "start_process") then
        if not start_process_projection_is_valid(message, result) then
          reject_request(self, result, message, Invalid_Params);
        else
          begin_tool(result, message.Request_Id_Raw, Invoke_Start_Process);
        end if;
      elsif Sonbal.MCP.JSON.Equals(message.Tool_Name, "poll_process") then
        if not poll_process_projection_is_valid(message, result) then
          reject_request(self, result, message, Invalid_Params);
        else
          begin_tool(result, message.Request_Id_Raw, Invoke_Poll_Process);
        end if;
      elsif Sonbal.MCP.JSON.Equals(message.Tool_Name, "cancel_process") then
        if not cancel_process_projection_is_valid(message, result) then
          reject_request(self, result, message, Invalid_Params);
        else
          begin_tool(result, message.Request_Id_Raw, Invoke_Cancel_Process);
        end if;
      elsif Sonbal.MCP.JSON.Equals(message.Tool_Name, "read_file") then
        if not read_file_projection_is_valid(message, result) then
          reject_request(self, result, message, Invalid_Params);
        else
          begin_tool(result, message.Request_Id_Raw, Invoke_Read_File);
        end if;
      else
        reject_request (self, result, message, Invalid_Params);
      end if;
    else
      reject_request (self, result, message, Method_Not_Found);
    end if;
  end handle_request;

  procedure handle_parsed
    (self : in out Context;
     message : Sonbal.MCP.JSON.Message;
     status  : Sonbal.MCP.JSON.Parse_Status;
     result  : out Dispatch_Result)
  is
  begin
    clear_result (result);
    if self.state = Stopping then
      return;
    end if;

    if status /= Sonbal.MCP.JSON.Parse_OK then
      declare
        correlated_policy_rejection : constant Boolean :=
          status not in Sonbal.MCP.JSON.Input_Too_Long |
            Sonbal.MCP.JSON.Invalid_UTF8 |
            Sonbal.MCP.JSON.Invalid_Syntax
          and then has_response_id (message);
      begin
        build_error
          (self,
           result,
           (if correlated_policy_rejection
            then Invalid_Request
            else Parse_Error),
           message.Request_Id_Raw,
           correlated_policy_rejection);
      end;
      return;
    end if;

    if message.Root_Kind /= Sonbal.MCP.JSON.Object_Value then
      build_error
        (self, result, Invalid_Request, message.Request_Id_Raw, False);
      return;
    end if;

    if message.Request_Id_Kind = Sonbal.MCP.JSON.Invalid_Id then
      build_error
        (self, result, Invalid_Request, message.Request_Id_Raw, False);
      return;
    end if;

    if message.JSONRPC_Kind /= Sonbal.MCP.JSON.String_Value or else
       not Sonbal.MCP.JSON.Equals (message.JSONRPC, "2.0") or else
       message.Method_Kind /= Sonbal.MCP.JSON.String_Value
    then
      if has_response_id (message) then
        reject_request (self, result, message, Invalid_Request);
      end if;
      return;
    end if;

    if has_response_id (message) then
      handle_request (self, message, result);
    else
      --  FINAL MCP 2026-07-28 defines no client-to-server notification
      --  execution over Streamable HTTP. Preserve JSON-RPC no-response
      --  classification so a transport adapter may acknowledge receipt
      --  without invoking any ordinary Sonbal capability.
      result.notification := True;
    end if;
  end handle_parsed;

  procedure Handle
    (Self : in out Context;
     Input   : String;
     Result  : out Dispatch_Result)
  is
    message : Sonbal.MCP.JSON.Message;
    status  : Sonbal.MCP.JSON.Parse_Status;
  begin
    if Self.State = Stopping then
      clear_result (Result);
      return;
    end if;

    Sonbal.MCP.JSON.Parse (Input, message, status);
    handle_parsed (Self, message, status, Result);
  end Handle;

   procedure complete_ping
     (Self : in out Context;
      Result  : in out Dispatch_Result)
   is
      Request_Id : Sonbal.MCP.JSON.Text;
   begin
      if Self.State /= Running
        or else Result.Action /= Invoke_Ping
        or else Sonbal.MCP.JSON.Is_Empty (Result.Request_Id)
      then
         fail_internal (Self, Result);
         return;
      end if;

      Request_Id := Result.Request_Id;
      clear_result_for_completion (Result);
      build_result
        (Self,
         Result,
         Request_Id,
         Ping_Result_Suffix);
   end complete_ping;

  procedure append_tool_result_prefix
    (target     : in out Response_Text;
     request_id : Sonbal.MCP.JSON.Text;
     status     : String;
     succeeded  : in out Boolean)
  is
  begin
    append_response(target, "{""jsonrpc"":""2.0"",""id"":", succeeded);
    append_response(target, Sonbal.MCP.JSON.image(request_id), succeeded);
    append_response
      (target,
       ",""result"":{""resultType"":""complete""," &
       """content"":[{""type"":""text"",""text"":""" & status &
       """}],""structuredContent"":{""status"":""" & status & """",
       succeeded);
  end append_tool_result_prefix;

  procedure append_tool_result_string
    (target    : in out Response_Text;
     name      : String;
     value     : String;
     succeeded : in out Boolean)
  is
  begin
    append_response
      (target, ",""" & name & """:""" & value & """", succeeded);
  end append_tool_result_string;

  procedure append_tool_result_suffix
    (target    : in out Response_Text;
     is_error  : Boolean;
     succeeded : in out Boolean)
  is
  begin
    append_response
      (target,
       "},""isError"":" & (if is_error then "true" else "false") & "," &
       SERVER_INFO_META & "}}",
       succeeded);
  end append_tool_result_suffix;

  procedure begin_completion
    (self        : in out Context;
     result         : in out Dispatch_Result;
     expected_action : Action_Kind;
     request_id     : out Sonbal.MCP.JSON.Text;
     valid          : out Boolean)
  is
  begin
    valid := self.state = Running and then
      result.action = expected_action and then
      not Sonbal.MCP.JSON.is_empty(result.request_id);
    if not valid then
      request_id := (others => <>);
      fail_internal(self, result);
      return;
    end if;

    request_id := result.request_id;
    clear_result_for_completion (result);
  end begin_completion;

  procedure complete_rotate_workspace_token
    (self : in out Context;
     result  : in out Dispatch_Result;
     status  : Clair.Status.Code;
     rotation : Sonbal.Workspace_Tokens.Rotation_Result)
  is
    function status_image return String is
    begin
      if status /= Clair.Status.OK then
        return "rotation_failed";
      end if;
      case rotation.state is
        when Sonbal.Workspace_Tokens.Rotation_Prepared =>
          return "prepared";
        when Sonbal.Workspace_Tokens.Rotation_Rotated =>
          return "rotated";
        when Sonbal.Workspace_Tokens.Rotation_Cooldown =>
          return "cooldown";
        when Sonbal.Workspace_Tokens.Rotation_Capacity_Exceeded =>
          return "capacity_exceeded";
        when Sonbal.Workspace_Tokens.Rotation_Stale_Operation =>
          return "stale_operation";
      end case;
    end status_image;

    request_id : Sonbal.MCP.JSON.Text;
    valid      : Boolean;
    succeeded  : Boolean := True;
    text       : constant String := status_image;
    is_error   : constant Boolean :=
      status /= Clair.Status.OK or else
      rotation.state not in
        Sonbal.Workspace_Tokens.Rotation_Prepared |
        Sonbal.Workspace_Tokens.Rotation_Rotated;
  begin
    begin_completion
      (self,
       result,
       Invoke_Rotate_Workspace_Token,
       request_id,
       valid);
    if not valid then
      return;
    end if;

    append_tool_result_prefix (result.response, request_id, text, succeeded);
    if status = Clair.Status.OK and then
       Sonbal.Workspace_Tokens.image (rotation.operation_id) /= ""
    then
      append_tool_result_string
        (result.response,
         "operation_id",
         Sonbal.Workspace_Tokens.image (rotation.operation_id),
         succeeded);
    end if;

    if status = Clair.Status.OK and then
       rotation.state = Sonbal.Workspace_Tokens.Rotation_Rotated
    then
      append_tool_result_string
        (result.response,
         "workspace_token",
         Sonbal.Workspace_Tokens.image (rotation.token),
         succeeded);
    end if;

    append_tool_result_suffix (result.response, is_error, succeeded);
    finish_response (self, result, succeeded);
  end complete_rotate_workspace_token;


  procedure complete_read_file
    (self    : in out Context;
     result  : in out Dispatch_Result;
     status  : Clair.Status.Code;
     outcome : Clair.Process.Execution.Result)
  is
    request_id : Sonbal.MCP.JSON.Text;
    request : constant Read_File_Request := result.read_file;
    read_result : Sonbal.File_Read.Read_Result;
    parse_status : Clair.Status.Code;
    succeeded : Boolean := True;
    expected_revision : constant String :=
      Sonbal.MCP.JSON.image(request.expected_revision);
  begin
    if self.state /= Running or else
       result.action /= Invoke_Read_File or else
       Sonbal.MCP.JSON.is_empty (result.request_id)
    then
      fail_internal (self, result);
      return;
    end if;

    parse_status := Sonbal.File_Read.parse_helper_outcome
      (status            => status,
       outcome           => outcome,
       requested_offset  => request.offset,
       requested_maximum => request.maximum_bytes,
       expected_revision => expected_revision,
       result            => read_result);
    if parse_status /= Clair.Status.OK then
      fail_internal (self, result);
      return;
    end if;

    request_id := result.request_id;
    clear_result_for_completion (result);

    append_tool_result_prefix
      (result.response,
       request_id,
       Sonbal.File_Read.status_image(read_result.state),
       succeeded);

    if read_result.state = Sonbal.File_Read.Read_OK then
      append_tool_result_string
        (result.response,
         "revision",
         Sonbal.File_Read.image(read_result.file_revision),
         succeeded);
      append_response
        (result.response,
         ",""file_size"":" &
           compact_image
             (Clair.IO.File_Offset'image(read_result.file_size)) &
         ",""offset"":" &
           compact_image
             (Clair.IO.File_Offset'image(read_result.offset)) &
         ",""next_offset"":" &
           compact_image
             (Clair.IO.File_Offset'image(read_result.next_offset)) &
         ",""eof"":" &
           (if read_result.eof then "true" else "false") &
         ",""content"":",
         succeeded);
      append_read_file_content
        (result.response,
         read_result.content,
         read_result.content_length,
         succeeded);
    end if;

    append_tool_result_suffix
      (result.response,
       is_error => read_result.state /= Sonbal.File_Read.Read_OK,
       succeeded => succeeded);
    finish_response (self, result, succeeded);
  end complete_read_file;

  procedure complete_read_file_error_status
    (self        : in out Context;
     result      : in out Dispatch_Result;
     status_text : String)
  is
    request_id : Sonbal.MCP.JSON.Text;
    succeeded : Boolean := True;
  begin
    if self.state /= Running or else
       result.action /= Invoke_Read_File or else
       Sonbal.MCP.JSON.is_empty (result.request_id)
    then
      fail_internal (self, result);
      return;
    end if;

    request_id := result.request_id;
    clear_result_for_completion (result);
    append_tool_result_prefix
      (result.response, request_id, status_text, succeeded);
    append_tool_result_suffix
      (result.response, is_error => True, succeeded => succeeded);
    finish_response (self, result, succeeded);
  end complete_read_file_error_status;

  procedure complete_read_file_execution_busy
    (self   : in out Context;
     result : in out Dispatch_Result)
  is
  begin
    complete_read_file_error_status
      (self, result, "execution_busy");
  end complete_read_file_execution_busy;

  procedure complete_read_file_stale_workspace_token
    (self   : in out Context;
     result : in out Dispatch_Result)
  is
  begin
    complete_read_file_error_status
      (self, result, "stale_workspace_token");
  end complete_read_file_stale_workspace_token;

  procedure complete_run_process
    (self : in out Context;
     result  : in out Dispatch_Result;
     status  : Clair.Status.Code;
     outcome : Clair.Process.Execution.Result)
  is
    request_id : Sonbal.MCP.JSON.Text;
    available  : constant Boolean :=
      Clair.Process.Execution.is_available (outcome);
    infrastructure_failed : constant Boolean :=
      Clair.Process.Execution.has_infrastructure_failure (outcome);
    cleanup_failed : constant Boolean :=
      available and then
      Clair.Process.Execution.cleanup_status_of (outcome) /= Clair.Status.OK;
    failure_kind : constant Run_Process_Failure_Kind :=
      classify_run_process_failure
        (status_failed         => status /= Clair.Status.OK,
         infrastructure_failed => infrastructure_failed,
         cleanup_failed        => cleanup_failed);
    failed : constant Boolean := failure_kind /= Run_Process_No_Failure;

    procedure build
      (status_text     : String;
       is_error        : Boolean;
       extra_name      : String := "";
       extra_value     : String := "";
       extra_is_string : Boolean := False;
       ownership_stage : String := "")
    is
      succeeded : Boolean := True;
    begin
      result.response.length := 0;
      append_run_process_prefix
        (result.response, request_id, status_text, succeeded);

      if available then
        append_process_result_stream
          (result.response, outcome, Standard_Output_Stream, succeeded);
      else
        append_empty_run_process_stream (result.response, succeeded);
      end if;

      append_response (result.response, ",""stderr"":", succeeded);
      if available then
        append_process_result_stream
          (result.response, outcome, Standard_Error_Stream, succeeded);
      else
        append_empty_run_process_stream (result.response, succeeded);
      end if;

      append_run_process_suffix
        (result.response,
         is_error        => is_error,
         extra_name      => extra_name,
         extra_value     => extra_value,
         extra_is_string => extra_is_string,
         succeeded       => succeeded,
         ownership_stage => ownership_stage);
      finish_response (self, result, succeeded);
    end build;

    function current_ownership_stage return String is
    begin
      if available and then
         Clair.Process.Execution.has_ownership_failure (outcome)
      then
        return ownership_stage_image
          (Clair.Process.Execution.ownership_failure_stage_of (outcome));
      end if;
      return "";
    end current_ownership_stage;
  begin
    if self.state /= Running or else
       result.action /= Invoke_Run_Process or else
       Sonbal.MCP.JSON.is_empty (result.request_id)
    then
      fail_internal (self, result);
      return;
    end if;

    request_id := result.request_id;

    if not failed and then
       (not available or else
        not Clair.Process.Execution.has_completion (outcome))
    then
      fail_internal (self, result);
      return;
    end if;

    clear_result_for_completion (result);

    if failed then
      case failure_kind is
        when Run_Process_Infrastructure_Failure =>
          build
            ("execution_failed",
             True,
             "infrastructure_stage",
             infrastructure_stage_image
               (Clair.Process.Execution.infrastructure_stage_of (outcome)),
             True,
             ownership_stage => current_ownership_stage);
        when Run_Process_Cleanup_Failure =>
          build
            ("execution_failed",
             True,
             "infrastructure_stage",
             infrastructure_stage_image
               (Clair.Process.Execution.Resource_Cleanup_Stage),
             True,
             ownership_stage => current_ownership_stage);
        when Run_Process_Status_Failure =>
          build
            ("execution_failed",
             True,
             ownership_stage => current_ownership_stage);
        when Run_Process_No_Failure =>
          fail_internal (self, result);
      end case;
      return;
    end if;

    case Clair.Process.Execution.completion_of (outcome) is
      when Clair.Process.Execution.Exited =>
        build
          ("exited",
           False,
           "exit_code",
           compact_image
             (Clair.Process.Exit_Code'image
                (Clair.Process.Execution.exit_code_of (outcome))));
      when Clair.Process.Execution.Signaled =>
        build ("signaled", False);
      when Clair.Process.Execution.Timed_Out =>
        build ("timed_out", False);
      when Clair.Process.Execution.Launch_Failed =>
        build
          ("launch_failed",
           False,
           "launch_stage",
           launch_stage_image
             (Clair.Process.Execution.launch_stage_of (outcome)),
           True);
    end case;
  end complete_run_process;

  procedure complete_run_process_error_status
    (self     : in out Context;
     result      : in out Dispatch_Result;
     status_text : String)
  is
    request_id : Sonbal.MCP.JSON.Text;
    succeeded  : Boolean := True;
  begin
    if self.state /= Running or else
       result.action /= Invoke_Run_Process or else
       Sonbal.MCP.JSON.is_empty (result.request_id)
    then
      fail_internal (self, result);
      return;
    end if;

    request_id := result.request_id;
    clear_result_for_completion (result);
    append_run_process_prefix
      (result.response, request_id, status_text, succeeded);
    append_empty_run_process_stream (result.response, succeeded);
    append_response (result.response, ",""stderr"":", succeeded);
    append_empty_run_process_stream (result.response, succeeded);
    append_run_process_suffix
      (result.response, True, "", "", False, succeeded);
    finish_response (self, result, succeeded);
  end complete_run_process_error_status;

  procedure complete_run_process_execution_busy
    (self : in out Context; result : in out Dispatch_Result) is
  begin
    complete_run_process_error_status (self, result, "execution_busy");
  end complete_run_process_execution_busy;

  procedure complete_run_process_stale_workspace_token
    (self : in out Context;
     result  : in out Dispatch_Result)
  is
  begin
    complete_run_process_error_status
      (self, result, "stale_workspace_token");
  end complete_run_process_stale_workspace_token;

  procedure complete_run_process_outside_workspace
    (self : in out Context;
     result  : in out Dispatch_Result)
  is
  begin
    complete_run_process_error_status
      (self, result, "outside_workspace");
  end complete_run_process_outside_workspace;

  procedure complete_start_process
    (self : in out Context;
     result  : in out Dispatch_Result;
     start   : Sonbal.Process_Jobs.Start_Result)
  is
    function status_image return String is
    begin
      case start.state is
        when Sonbal.Process_Jobs.Start_Running =>
          return "running";
        when Sonbal.Process_Jobs.Start_Execution_Busy =>
          return "execution_busy";
        when Sonbal.Process_Jobs.Start_Stale_Workspace_Token =>
          return "stale_workspace_token";
        when Sonbal.Process_Jobs.Start_Outside_Workspace =>
          return "outside_workspace";
        when Sonbal.Process_Jobs.Start_Execution_Failed =>
          return "execution_failed";
      end case;
    end status_image;

    request_id : Sonbal.MCP.JSON.Text;
    valid      : Boolean;
    succeeded  : Boolean := True;
    text       : constant String := status_image;
    is_error   : constant Boolean :=
      start.state /= Sonbal.Process_Jobs.Start_Running;
  begin
    begin_completion
      (self, result, Invoke_Start_Process, request_id, valid);
    if not valid then
      return;
    end if;

    append_tool_result_prefix(result.response, request_id, text, succeeded);
    if start.state = Sonbal.Process_Jobs.Start_Running then
      append_tool_result_string
        (result.response,
         "job_id",
         Sonbal.Process_Jobs.image(start.job_id),
         succeeded);
      append_tool_result_string
        (result.response,
         "cursor",
         Sonbal.Process_Jobs.image(start.cursor),
         succeeded);
    end if;
    append_tool_result_suffix(result.response, is_error, succeeded);
    finish_response(self, result, succeeded);
  end complete_start_process;

  procedure complete_poll_process
    (self : in out Context;
     result  : in out Dispatch_Result;
     poll    : Sonbal.Process_Jobs.Poll_Result)
  is
    function status_image return String is
    begin
      case poll.state is
        when Sonbal.Process_Jobs.Poll_Running =>
          return "running";
        when Sonbal.Process_Jobs.Poll_Expired =>
          return "expired";
        when Sonbal.Process_Jobs.Poll_Stale_Instance =>
          return "stale_instance";
        when Sonbal.Process_Jobs.Poll_Not_Found =>
          return "not_found";
        when Sonbal.Process_Jobs.Poll_Invalid_Cursor =>
          return "invalid_cursor";
        when Sonbal.Process_Jobs.Poll_Execution_Failed =>
          return "execution_failed";
        when Sonbal.Process_Jobs.Poll_Terminal =>
          case poll.terminal is
            when Sonbal.Process_Jobs.Job_Exited =>
              return "exited";
            when Sonbal.Process_Jobs.Job_Signaled =>
              return "signaled";
            when Sonbal.Process_Jobs.Job_Timed_Out =>
              return "timed_out";
            when Sonbal.Process_Jobs.Job_Launch_Failed =>
              return "launch_failed";
            when Sonbal.Process_Jobs.Job_Cancelled =>
              return "cancelled";
            when Sonbal.Process_Jobs.Job_Execution_Failed =>
              return "execution_failed";
          end case;
      end case;
    end status_image;

    request_id : Sonbal.MCP.JSON.Text;
    valid      : Boolean;
    succeeded  : Boolean := True;
    text       : constant String := status_image;
    is_error   : constant Boolean :=
      poll.state in Sonbal.Process_Jobs.Poll_Expired |
        Sonbal.Process_Jobs.Poll_Stale_Instance |
        Sonbal.Process_Jobs.Poll_Not_Found |
        Sonbal.Process_Jobs.Poll_Invalid_Cursor |
        Sonbal.Process_Jobs.Poll_Execution_Failed or else
      (poll.state = Sonbal.Process_Jobs.Poll_Terminal and then
       poll.terminal = Sonbal.Process_Jobs.Job_Execution_Failed);
  begin
    begin_completion
      (self, result, Invoke_Poll_Process, request_id, valid);
    if not valid then
      return;
    end if;

    append_tool_result_prefix(result.response, request_id, text, succeeded);
    if poll.state in Sonbal.Process_Jobs.Poll_Running |
      Sonbal.Process_Jobs.Poll_Terminal
    then
      append_response(result.response, ",""stdout"":", succeeded);
      append_run_process_stream
        (result.response,
         poll.stdout.data,
         poll.stdout.length,
         poll.stdout.truncated,
         succeeded);
      append_response(result.response, ",""stderr"":", succeeded);
      append_run_process_stream
        (result.response,
         poll.stderr.data,
         poll.stderr.length,
         poll.stderr.truncated,
         succeeded);
      append_tool_result_string
        (result.response,
         "next_cursor",
         Sonbal.Process_Jobs.image(poll.next_cursor),
         succeeded);

      if poll.state = Sonbal.Process_Jobs.Poll_Terminal then
        if poll.has_exit_code then
          append_response
            (result.response,
             ",""exit_code"":" &
             compact_image(Interfaces.Unsigned_32'image(poll.exit_code)),
             succeeded);
        end if;
        if poll.has_launch_stage then
          append_tool_result_string
            (result.response,
             "launch_stage",
             launch_stage_image(poll.launch_stage),
             succeeded);
        end if;
        if poll.has_infrastructure_stage then
          append_tool_result_string
            (result.response,
             "infrastructure_stage",
             infrastructure_stage_image(poll.infrastructure_stage),
             succeeded);
        end if;
        if poll.has_ownership_stage then
          append_tool_result_string
            (result.response,
             "ownership_stage",
             ownership_stage_image(poll.ownership_stage),
             succeeded);
        end if;
      end if;
    end if;

    append_tool_result_suffix(result.response, is_error, succeeded);
    finish_response(self, result, succeeded);
  end complete_poll_process;

  procedure complete_cancel_process
    (self : in out Context;
     result  : in out Dispatch_Result;
     cancel  : Sonbal.Process_Jobs.Cancel_Result)
  is
    function status_image return String is
    begin
      case cancel.state is
        when Sonbal.Process_Jobs.Cancel_Cancelling =>
          return "cancelling";
        when Sonbal.Process_Jobs.Cancel_Already_Terminal =>
          return "already_terminal";
        when Sonbal.Process_Jobs.Cancel_Expired =>
          return "expired";
        when Sonbal.Process_Jobs.Cancel_Stale_Instance =>
          return "stale_instance";
        when Sonbal.Process_Jobs.Cancel_Not_Found =>
          return "not_found";
        when Sonbal.Process_Jobs.Cancel_Execution_Failed =>
          return "execution_failed";
      end case;
    end status_image;

    request_id : Sonbal.MCP.JSON.Text;
    valid      : Boolean;
    succeeded  : Boolean := True;
    text       : constant String := status_image;
    is_error   : constant Boolean :=
      cancel.state in Sonbal.Process_Jobs.Cancel_Expired |
        Sonbal.Process_Jobs.Cancel_Stale_Instance |
        Sonbal.Process_Jobs.Cancel_Not_Found |
        Sonbal.Process_Jobs.Cancel_Execution_Failed;
  begin
    begin_completion
      (self, result, Invoke_Cancel_Process, request_id, valid);
    if not valid then
      return;
    end if;

    append_tool_result_prefix(result.response, request_id, text, succeeded);
    append_tool_result_suffix(result.response, is_error, succeeded);
    finish_response(self, result, succeeded);
  end complete_cancel_process;

  procedure stop (self : in out Context) is
  begin
    self.state := Stopping;
  end stop;
end Sonbal.MCP.Dispatcher;
