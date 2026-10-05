-- ============================================================================
-- sonbal-mcp-dispatcher-tester.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Sonbal.MCP.JSON;
with System.Storage_Elements;

package body Sonbal.MCP.Dispatcher.Tester is

  use type Sonbal.MCP.JSON.Parse_Status;

  function response_boundary_is_enforced return Boolean is
    target    : Response_Text;
    succeeded : Boolean := True;
  begin
    target.length := MAXIMUM_MCP_RESPONSE_BYTES - 1;
    append_response (target, "x", succeeded);

    if not succeeded or else
      target.length /= MAXIMUM_MCP_RESPONSE_BYTES
    then
      return False;
    end if;

    append_response (target, "x", succeeded);

    return not succeeded and then
      target.length = MAXIMUM_MCP_RESPONSE_BYTES;
  end response_boundary_is_enforced;

  function run_process_input_schema return String is
    (Sonbal.MCP.Dispatcher.RUN_PROCESS_INPUT_SCHEMA);

  function run_process_output_schema return String is
    (Sonbal.MCP.Dispatcher.RUN_PROCESS_OUTPUT_SCHEMA);

  function poll_process_output_schema return String is
    (Sonbal.MCP.Dispatcher.POLL_PROCESS_OUTPUT_SCHEMA);

  function run_process_tool_descriptor return String is
    (Sonbal.MCP.Dispatcher.RUN_PROCESS_TOOL_DESCRIPTOR);

  function run_process_response_bound_is_exact return Boolean is
    request_id : String (1 .. Sonbal.MCP.JSON.Max_Request_Id_Bytes) :=
      [others => 'x'];
    stream_data : String (1 .. MAXIMUM_RUN_PROCESS_STREAM_DATA_BYTES) :=
      [others => 'A'];
    target : Response_Text :=
      (data   => [others => Character'val (0)],
       length => 0);
    succeeded : Boolean := True;

    procedure append (item : String) is
    begin
      append_response (target, item, succeeded);
    end append;
  begin
    request_id(request_id'first) := '"';
    request_id(request_id'last) := '"';
    stream_data(stream_data'last) := '=';

    append ("{""jsonrpc"":""2.0"",""id"":");
    append (request_id);
    append
      (",""result"":{""resultType"":""complete""," &
       """content"":[{""type"":""text"",""text"":""" &
       "execution_failed" &
       """}],""structuredContent"":{""status"":""" &
       "execution_failed" &
       """,""stdout"":{""encoding"":""base64""," &
       """bytes"":32768,""data"":""");
    append (stream_data);
    append
      (""",""truncated"":false}," &
       """stderr"":{""encoding"":""base64""," &
       """bytes"":32768,""data"":""");
    append (stream_data);
    append
      (""",""truncated"":false}," &
       """infrastructure_stage"":""execution_preparation""," &
       """ownership_stage"":""settlement""}," &
       """isError"":true," &
       """_meta"":{""io.modelcontextprotocol/serverInfo"":{" &
       """name"":""" & Server_Name & """," &
       """version"":""" & Server_Version & """}}}}");

    if not succeeded or else
       target.length /= MAXIMUM_RUN_PROCESS_RESPONSE_BYTES
    then
      return False;
    end if;

    append ("x");
    return not succeeded and then
      target.length = MAXIMUM_RUN_PROCESS_RESPONSE_BYTES;
  end run_process_response_bound_is_exact;

  function read_file_maximum_response_length return Natural
  is
    request_id : String (1 .. Sonbal.MCP.JSON.Max_Request_Id_Bytes) :=
      [others => 'i'];
    revision : constant String
      (1 .. Sonbal.File_Read.MAXIMUM_REVISION_BYTES) :=
      [1 => 'r', 2 => '1', 3 => '-', others => 'f'];
    content_data : String (1 .. 21_848) := [others => 'A'];
    target : Response_Text :=
      (data   => [others => Character'val (0)],
       length => 0);
    succeeded : Boolean := True;

    procedure append (item : String) is
    begin
      append_response (target, item, succeeded);
    end append;
  begin
    request_id(request_id'first) := '"';
    request_id(request_id'last) := '"';
    content_data(content_data'last) := '=';

    append ("{""jsonrpc"":""2.0"",""id"":");
    append (request_id);
    append
      (",""result"":{""resultType"":""complete""," &
       """content"":[{""type"":""text"",""text"":""ok""}]," &
       """structuredContent"":{""status"":""ok""," &
       """revision"":""");
    append (revision);
    append
      (""",""file_size"":9007199254740991" &
       ",""offset"":9007199254724606" &
       ",""next_offset"":9007199254740990" &
       ",""eof"":false,""content"":{" &
       """encoding"":""base64"",""bytes"":16384," &
       """data"":""");
    append (content_data);
    append
      ("""}},""isError"":false," &
       """_meta"":{""io.modelcontextprotocol/serverInfo"":{" &
       """name"":""" & Server_Name & """," &
       """version"":""" & Server_Version & """}}}}");

    if not succeeded then
      return 0;
    end if;
    return target.length;
  end read_file_maximum_response_length;

  function run_process_stream_image
    (data      : String;
     truncated : Boolean)
  return String
  is
    target : Response_Text :=
      (data   => [others => Character'val (0)],
       length => 0);
    succeeded : Boolean := True;
  begin
    if data'length = 0 then
      declare
        raw : constant System.Storage_Elements.Storage_Array (1 .. 1)
            := [others => 0];
      begin
        append_run_process_stream
          (target,
           data      => raw,
           length    => 0,
           truncated => truncated,
           succeeded => succeeded);
      end;
    else
      declare
        raw : System.Storage_Elements.Storage_Array
          (1 .. System.Storage_Elements.Storage_Offset(data'length)) :=
            [others => 0];
      begin
        for offset in 0 .. data'length - 1 loop
          raw(System.Storage_Elements.Storage_Offset(offset + 1)) :=
            System.Storage_Elements.Storage_Element
              (Character'pos (data(data'first + offset)));
        end loop;

        append_run_process_stream
          (target,
           data      => raw,
           length    => data'length,
           truncated => truncated,
           succeeded => succeeded);
      end;
    end if;

    if not succeeded then
      return "";
    end if;

    return image (target);
  end run_process_stream_image;

  function run_process_result_image
    (status  : Clair.Status.Code;
     outcome : Clair.Process.Execution.Result)
  return String
  is
    self : Context;
    result  : Dispatch_Result :=
      (response =>
         (data   => [others => Character'val (0)],
          length => 0),
       others => <>);
  begin
    result.action := Invoke_Run_Process;
    result.request_id.data(1) := '7';
    result.request_id.length := 1;
    complete_run_process (self, result, status, outcome);

    if result.action /= Write_Response then
      return "";
    end if;

    return image (result.response);
  end run_process_result_image;

  function run_process_failure_classification
    (status_failed         : Boolean;
     infrastructure_failed : Boolean;
     cleanup_failed        : Boolean)
  return String
  is
    kind : constant Run_Process_Failure_Kind :=
      classify_run_process_failure
        (status_failed         => status_failed,
         infrastructure_failed => infrastructure_failed,
         cleanup_failed        => cleanup_failed);
  begin
    case kind is
      when Run_Process_No_Failure =>
        return "none";
      when Run_Process_Status_Failure =>
        return "status";
      when Run_Process_Infrastructure_Failure =>
        return "infrastructure";
      when Run_Process_Cleanup_Failure =>
        return "cleanup";
    end case;
  end run_process_failure_classification;

  function poll_process_result_image
    (poll : Sonbal.Process_Jobs.Poll_Result)
  return String
  is
    self : Context;
    result  : Dispatch_Result :=
      (response =>
         (data   => [others => Character'val (0)],
          length => 0),
       others => <>);
  begin
    result.action := Invoke_Poll_Process;
    result.request_id.data(1) := '8';
    result.request_id.length := 1;
    complete_poll_process (self, result, poll);

    if result.action /= Write_Response then
      return "";
    end if;

    return image (result.response);
  end poll_process_result_image;

  function run_process_projection_validate (input : String) return Boolean is
    message : Sonbal.MCP.JSON.Message;
    status  : Sonbal.MCP.JSON.Parse_Status;
    result  : Dispatch_Result :=
      (response =>
         (data   => [others => Character'val (0)],
          length => 0),
       others => <>);
  begin
    Sonbal.MCP.JSON.parse (input, message, status);

    if status /= Sonbal.MCP.JSON.Parse_OK then
      return False;
    end if;

    return run_process_projection_is_valid (message, result);
  end run_process_projection_validate;

end Sonbal.MCP.Dispatcher.Tester;
