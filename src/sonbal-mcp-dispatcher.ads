-- ============================================================================
-- sonbal-mcp-dispatcher.ads
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Clair.IO;
with Clair.Process.Execution;
with Clair.Status;
with Interfaces;
with Sonbal.File_Read;
with Sonbal.Process_Arguments;
with Sonbal.MCP.JSON;
with Sonbal.Process_Jobs;
with Sonbal.Release_Identity;
with Sonbal.Workspace_Tokens;
with System.Storage_Elements;

package Sonbal.MCP.Dispatcher is
   Protocol_Version : constant String := "2026-07-28";
   Server_Name      : constant String := "sonbal";
   Server_Version   : constant String := Sonbal.Release_Identity.Version;
   Server_Revision  : constant String := Sonbal.Release_Identity.Revision;

  --! summary Exact tools/list maximum, excluding newline.
  MAXIMUM_TOOLS_LIST_RESPONSE_BYTES : constant Positive := 9_164;

  MAXIMUM_RUN_PROCESS_TIMEOUT_MS   : constant Positive := 110_000;
  MAXIMUM_START_PROCESS_TIMEOUT_MS : constant Positive := 3_600_000;

  --! summary Maximum retained process-stream data field bytes.
  MAXIMUM_RUN_PROCESS_STREAM_DATA_BYTES : constant Positive := 43_692;

  --! summary Maximum serialized run_process response, excluding newline.
  MAXIMUM_RUN_PROCESS_RESPONSE_BYTES : constant Positive := 88_129;

  --! summary Maximum serialized read_file response, excluding newline.
  MAXIMUM_READ_FILE_RESPONSE_BYTES : constant Positive := 22_609;

  --! summary Maximum serialized MCP response payload, excluding newline.
  MAXIMUM_MCP_RESPONSE_BYTES : constant Positive :=
    MAXIMUM_RUN_PROCESS_RESPONSE_BYTES;

   --  This is local dispatcher lifetime, not MCP protocol session state.
   type Dispatcher_State is (Running, Stopping);

  type Action_Kind is
    (No_Action,
     Write_Response,
     Invoke_Ping,
     Invoke_Rotate_Workspace_Token,
     Invoke_Read_File,
     Invoke_Run_Process,
     Invoke_Start_Process,
     Invoke_Poll_Process,
     Invoke_Cancel_Process,
     Fatal_Error);

   type Response_Text is private;

  type Run_Process_Resolution is (Exact_Path, Search_Path);

  type Workspace_Token_Rotate_Request is record
    root         : Sonbal.MCP.JSON.Run_Process_Text;
    operation_id : Sonbal.MCP.JSON.Text;
  end record;


  type Read_File_Request is record
    workspace_token   : Sonbal.MCP.JSON.Text;
    path              : Sonbal.MCP.JSON.Run_Process_Text;
    offset            : Clair.IO.File_Offset := 0;
    maximum_bytes     : Positive range 1 ..
      Sonbal.File_Read.MAXIMUM_CONTENT_BYTES :=
        Sonbal.File_Read.MAXIMUM_CONTENT_BYTES;
    expected_revision : Sonbal.MCP.JSON.Text;
  end record;

  type Run_Process_Request is record
    workspace_token : Sonbal.MCP.JSON.Text;
    argv       : Sonbal.Process_Arguments.Arguments;
    resolution : Run_Process_Resolution := Exact_Path;
    cwd        : Sonbal.MCP.JSON.Run_Process_Text;
    timeout_ms : Natural range 0 .. MAXIMUM_START_PROCESS_TIMEOUT_MS := 0;
  end record;

  subtype Start_Process_Request is Run_Process_Request;

  type Poll_Process_Request is record
    job_id : Sonbal.MCP.JSON.Text;
    cursor : Sonbal.MCP.JSON.Text;
  end record;

  type Cancel_Process_Request is record
    job_id : Sonbal.MCP.JSON.Text;
  end record;

   function Image (Value : Response_Text) return String;

   function Length (Value : Response_Text) return Natural;

   -- Copy a zero-based response slice without materializing the full image.
   procedure Copy_Response
     (Value  : in Response_Text;
      Offset : in Natural;
      Target : out String;
      Copied : out Natural);

   function Is_Empty (Value : Response_Text) return Boolean;

  type Dispatch_Result is record
    action                 : Action_Kind := No_Action;
    response               : Response_Text;
    request_id             : Sonbal.MCP.JSON.Text;
    notification           : Boolean := False;
    diagnostic_action      : Action_Kind := No_Action;
    diagnostic_correlation : Interfaces.Unsigned_64 := 0;
    rotate_workspace_token : Workspace_Token_Rotate_Request;
    read_file              : Read_File_Request;
    run_process         : Run_Process_Request;
    start_process       : Start_Process_Request;
    poll_process        : Poll_Process_Request;
    cancel_process      : Cancel_Process_Request;
  end record;

   type Context is limited private;

   function Current_State (Self : Context) return Dispatcher_State;

   --  Handle validates one complete JSON frame. It performs no I/O and no tool
   --  side effect. A valid tools/call request becomes an Invoke_* action.
   procedure Handle
     (Self : in out Context;
      Input   : String;
      Result  : out Dispatch_Result);

  -- Handle a message already parsed by a transport adapter. This preserves the
  -- same dispatcher validation and error mapping without reparsing the body.
  procedure handle_parsed
    (self : in out Context;
     message : Sonbal.MCP.JSON.Message;
     status  : Sonbal.MCP.JSON.Parse_Status;
     result  : out Dispatch_Result);

   --  Complete_Ping consumes an Invoke_Ping result returned by Handle and
   --  replaces it with the bounded JSON-RPC success response. The request ID
   --  is owned by Result so outstanding calls may complete out of order.
   --  An inconsistent invocation is fatal.
   procedure Complete_Ping
     (Self : in out Context;
      Result  : in out Dispatch_Result);

  procedure complete_rotate_workspace_token
    (self : in out Context;
     result  : in out Dispatch_Result;
     status  : Clair.Status.Code;
     rotation : Sonbal.Workspace_Tokens.Rotation_Result);


  --! summary Complete one settled helper-backed file-read result.
  procedure complete_read_file
    (self    : in out Context;
     result  : in out Dispatch_Result;
     status  : Clair.Status.Code;
     outcome : Clair.Process.Execution.Result);

  procedure complete_read_file_execution_busy
    (self   : in out Context;
     result : in out Dispatch_Result);

  procedure complete_read_file_stale_workspace_token
    (self   : in out Context;
     result : in out Dispatch_Result);

  --! summary Complete one settled portable process result.
  procedure complete_run_process
    (self : in out Context;
     result  : in out Dispatch_Result;
     status  : Clair.Status.Code;
     outcome : Clair.Process.Execution.Result);

  procedure complete_run_process_execution_busy
    (self : in out Context;
     result  : in out Dispatch_Result);

  procedure complete_run_process_stale_workspace_token
    (self : in out Context;
     result  : in out Dispatch_Result);

  procedure complete_run_process_outside_workspace
    (self : in out Context;
     result  : in out Dispatch_Result);

  procedure complete_start_process
    (self : in out Context;
     result  : in out Dispatch_Result;
     start   : Sonbal.Process_Jobs.Start_Result);

  procedure complete_poll_process
    (self : in out Context;
     result  : in out Dispatch_Result;
     poll    : Sonbal.Process_Jobs.Poll_Result);

  procedure complete_cancel_process
    (self : in out Context;
     result  : in out Dispatch_Result;
     cancel  : Sonbal.Process_Jobs.Cancel_Result);

   procedure Stop (Self : in out Context);

private
  READ_FILE_INPUT_SCHEMA : constant String :=
    "{""type"":""object"",""properties"":{" &
    """workspace_token"":{""type"":""string""," &
    """minLength"":1,""maxLength"":66}," &
    """path"":{""type"":""string"",""minLength"":1," &
    """maxLength"":4096}," &
    """offset"":{""type"":""integer"",""minimum"":0," &
    """maximum"":9007199254740991}," &
    """maximum_bytes"":{""type"":""integer"",""minimum"":1," &
    """maximum"":16384}," &
    """expected_revision"":{""type"":""string""," &
    """minLength"":99,""maxLength"":99," &
    """pattern"":""^r1-[0-9a-f]{96}$""}}," &
    """required"": [""workspace_token"",""path""]," &
    """additionalProperties"":false}";

  READ_FILE_CONTENT_OUTPUT_SCHEMA : constant String :=
    "{""type"":""object"",""properties"":{" &
    """encoding"":{""type"":""string"",""enum"":" &
    "[""utf8"",""base64""]}," &
    """bytes"":{""type"":""integer"",""minimum"":0," &
    """maximum"":16384}," &
    """data"":{""type"":""string"",""maxLength"":21848}}," &
    """required"": [""encoding"",""bytes"",""data""]," &
    """additionalProperties"":false}";

  READ_FILE_OUTPUT_SCHEMA : constant String :=
    "{""type"":""object"",""properties"":{" &
    """status"":{""type"":""string"",""enum"":" &
    "[""ok"",""stale_workspace_token"",""execution_busy""," &
    """path_refused"",""not_found"",""access_denied""," &
    """not_regular_file"",""file_too_large""," &
    """offset_out_of_range"",""revision_mismatch""," &
    """file_changed"",""timed_out"",""read_failed""," &
    """execution_failed""]}," &
    """revision"":{""type"":""string"",""minLength"":99," &
    """maxLength"":99}," &
    """file_size"":{""type"":""integer"",""minimum"":0," &
    """maximum"":9007199254740991}," &
    """offset"":{""type"":""integer"",""minimum"":0," &
    """maximum"":9007199254740991}," &
    """next_offset"":{""type"":""integer"",""minimum"":0," &
    """maximum"":9007199254740991}," &
    """eof"":{""type"":""boolean""}," &
    """content"":" & READ_FILE_CONTENT_OUTPUT_SCHEMA & "}," &
    """required"": [""status""]," &
    """additionalProperties"":false}";

  READ_FILE_ANNOTATIONS : constant String :=
    "{""readOnlyHint"":true,""destructiveHint"":false," &
    """idempotentHint"":true,""openWorldHint"":false}";

  READ_FILE_TOOL_DESCRIPTOR : constant String :=
    "{""name"":""read_file"",""description"":""" &
    "Reads one bounded byte range from a regular file below a current " &
    "workspace token. Paths are workspace-relative and symbolic-link " &
    "traversal is refused." &
    """,""inputSchema"":" & READ_FILE_INPUT_SCHEMA &
    ",""outputSchema"":" & READ_FILE_OUTPUT_SCHEMA &
    ",""annotations"":" & READ_FILE_ANNOTATIONS & "}";

  RUN_PROCESS_INPUT_SCHEMA : constant String :=
    "{""type"":""object"",""properties"":{" &
    """workspace_token"":{""type"":""string""," &
    """minLength"":1,""maxLength"":66}," &
    """argv"":{""type"":""array"",""minItems"":1," &
    """maxItems"":65,""items"":{""type"":""string""," &
    """maxLength"":32768}}," &
    """resolution"":{""type"":""string"",""enum"":" &
    "[""exact_path"",""search_path""]}," &
    """cwd"":{""type"":""string"",""minLength"":1," &
    """maxLength"":4096,""pattern"":""^/([^\\n]|\\n)*$""}," &
    """timeout_ms"":{""type"":""integer"",""minimum"":1," &
    """maximum"":110000}}," &
    """required"":[""workspace_token"",""argv""," &
    """resolution"",""cwd"",""timeout_ms""]," &
    """additionalProperties"":false}";

  RUN_PROCESS_STREAM_OUTPUT_SCHEMA : constant String :=
    "{""type"":""object"",""properties"":{" &
    """encoding"":{""type"":""string"",""enum"":" &
    "[""utf8"",""base64""]}," &
    """bytes"":{""type"":""integer"",""minimum"":0," &
    """maximum"":32768}," &
    """data"":{""type"":""string"",""maxLength"":43692}," &
    """truncated"":{""type"":""boolean""}}," &
    """required"":[""encoding"",""bytes"",""data"",""truncated""]," &
    """additionalProperties"":false}";

  RUN_PROCESS_OUTPUT_SCHEMA : constant String :=
    "{""type"":""object"",""properties"":{" &
    """status"":{""type"":""string"",""enum"":" &
    "[""exited"",""signaled"",""timed_out"",""launch_failed""," &
    """execution_failed"",""execution_busy"",""stale_workspace_token""," &
    """outside_workspace""]}," &
    """stdout"":" & RUN_PROCESS_STREAM_OUTPUT_SCHEMA & "," &
    """stderr"":" & RUN_PROCESS_STREAM_OUTPUT_SCHEMA & "," &
    """exit_code"":{""type"":""integer"",""minimum"":0," &
    """maximum"":4294967295}," &
    """launch_stage"":{""type"":""string"",""enum"":" &
    "[""executable_resolution"",""working_directory""," &
    """standard_stream"",""environment_construction""," &
    """program_execution""]}," &
    """infrastructure_stage"":{""type"":""string"",""enum"":" &
    "[""execution_preparation"",""process_creation""," &
    """process_monitoring"",""process_termination""," &
    """output_drain"",""process_wait"",""resource_cleanup""]}," &
    """ownership_stage"":{""type"":""string"",""enum"":" &
    "[""setup"",""launch"",""settlement""]}}," &
    """required"":[""status"",""stdout"",""stderr""]," &
    """additionalProperties"":false}";

  RUN_PROCESS_ANNOTATIONS : constant String :=
    "{""readOnlyHint"":false,""destructiveHint"":true," &
    """idempotentHint"":false,""openWorldHint"":true}";

  RUN_PROCESS_TOOL_DESCRIPTOR : constant String :=
    "{""name"":""run_process"",""description"":""" &
    "Runs one bounded synchronous noninteractive process. " &
    "Use start_process for expected long-running work. " &
    "No shell or PTY is implicit." &
    """,""inputSchema"":" & RUN_PROCESS_INPUT_SCHEMA &
    ",""outputSchema"":" & RUN_PROCESS_OUTPUT_SCHEMA &
    ",""annotations"":" & RUN_PROCESS_ANNOTATIONS & "}";

  ROTATE_WORKSPACE_TOKEN_INPUT_SCHEMA : constant String :=
    "{""type"":""object"",""properties"":{" &
    """root"":{""type"":""string"",""minLength"":1," &
    """maxLength"":4096,""pattern"":""^/([^\n]|\n)*$""}," &
    """operation_id"":{""type"":""string"",""minLength"":50," &
    """maxLength"":50,""pattern"":""^o-[0-9a-f]{48}$""}}," &
    """required"":[""root""],""additionalProperties"":false}";

  ROTATE_WORKSPACE_TOKEN_OUTPUT_SCHEMA : constant String :=
    "{""type"":""object"",""properties"":{" &
    """status"":{""type"":""string"",""enum"":" &
    "[""prepared"",""rotated"",""cooldown"",""capacity_exceeded""," &
    """stale_operation"",""rotation_failed""]}," &
    """workspace_token"":{""type"":""string"",""maxLength"":66}," &
    """operation_id"":{""type"":""string"",""maxLength"":50}}," &
    """required"":[""status""],""additionalProperties"":false}";

  START_PROCESS_INPUT_SCHEMA : constant String :=
    "{""type"":""object"",""properties"":{" &
    """workspace_token"":{""type"":""string""," &
    """minLength"":1,""maxLength"":66}," &
    """argv"":{""type"":""array"",""minItems"":1," &
    """maxItems"":65,""items"":{""type"":""string""," &
    """maxLength"":32768}}," &
    """resolution"":{""type"":""string"",""enum"":" &
    "[""exact_path"",""search_path""]}," &
    """cwd"":{""type"":""string"",""minLength"":1," &
    """maxLength"":4096,""pattern"":""^/([^\\n]|\\n)*$""}," &
    """timeout_ms"":{""type"":""integer"",""minimum"":1," &
    """maximum"":3600000}}," &
    """required"":[""workspace_token"",""argv""," &
    """resolution"",""cwd"",""timeout_ms""]," &
    """additionalProperties"":false}";

  START_PROCESS_OUTPUT_SCHEMA : constant String :=
    "{""type"":""object"",""properties"":{" &
    """status"":{""type"":""string"",""enum"":" &
    "[""running"",""execution_busy"",""stale_workspace_token""," &
    """outside_workspace"",""execution_failed""]}," &
    """job_id"":{""type"":""string"",""maxLength"":82}," &
    """cursor"":{""type"":""string"",""maxLength"":94}}," &
    """required"":[""status""],""additionalProperties"":false}";

  POLL_PROCESS_INPUT_SCHEMA : constant String :=
    "{""type"":""object"",""properties"":{" &
    """job_id"":{""type"":""string"",""minLength"":1," &
    """maxLength"":82}," &
    """cursor"":{""type"":""string"",""minLength"":1," &
    """maxLength"":94}}," &
    """required"":[""job_id"",""cursor""]," &
    """additionalProperties"":false}";

  POLL_PROCESS_STREAM_OUTPUT_SCHEMA : constant String :=
    "{""type"":""object"",""properties"":{" &
    """encoding"":{""type"":""string"",""enum"":" &
    "[""utf8"",""base64""]}," &
    """bytes"":{""type"":""integer"",""minimum"":0," &
    """maximum"":8192}," &
    """data"":{""type"":""string"",""maxLength"":10924}," &
    """truncated"":{""type"":""boolean""}}," &
    """required"":[""encoding"",""bytes"",""data"",""truncated""]," &
    """additionalProperties"":false}";

  POLL_PROCESS_OUTPUT_SCHEMA : constant String :=
    "{""type"":""object"",""properties"":{" &
    """status"":{""type"":""string"",""enum"":" &
    "[""running"",""exited"",""signaled"",""timed_out""," &
    """launch_failed"",""cancelled"",""execution_failed""," &
    """expired"",""stale_instance"",""not_found""," &
    """invalid_cursor""]}," &
    """stdout"":" & POLL_PROCESS_STREAM_OUTPUT_SCHEMA & "," &
    """stderr"":" & POLL_PROCESS_STREAM_OUTPUT_SCHEMA & "," &
    """next_cursor"":{""type"":""string"",""maxLength"":94}," &
    """exit_code"":{""type"":""integer"",""minimum"":0," &
    """maximum"":4294967295}," &
    """launch_stage"":{""type"":""string"",""enum"":" &
    "[""executable_resolution"",""working_directory""," &
    """standard_stream"",""environment_construction""," &
    """program_execution""]}," &
    """infrastructure_stage"":{""type"":""string"",""enum"":" &
    "[""execution_preparation"",""process_creation""," &
    """process_monitoring"",""process_termination""," &
    """output_drain"",""process_wait"",""resource_cleanup""]}," &
    """ownership_stage"":{""type"":""string"",""enum"":" &
    "[""setup"",""launch"",""settlement""]}}," &
    """required"":[""status""],""additionalProperties"":false}";

  CANCEL_PROCESS_INPUT_SCHEMA : constant String :=
    "{""type"":""object"",""properties"":{" &
    """job_id"":{""type"":""string"",""minLength"":1," &
    """maxLength"":82}}," &
    """required"":[""job_id""],""additionalProperties"":false}";

  CANCEL_PROCESS_OUTPUT_SCHEMA : constant String :=
    "{""type"":""object"",""properties"":{" &
    """status"":{""type"":""string"",""enum"":" &
    "[""cancelling"",""already_terminal"",""expired""," &
    """stale_instance"",""not_found"",""execution_failed""]}}," &
    """required"":[""status""],""additionalProperties"":false}";

  WORKSPACE_ANNOTATIONS : constant String :=
    "{""readOnlyHint"":false,""destructiveHint"":false," &
    """idempotentHint"":false,""openWorldHint"":false}";

  POLL_PROCESS_ANNOTATIONS : constant String :=
    "{""readOnlyHint"":true,""destructiveHint"":false," &
    """idempotentHint"":true,""openWorldHint"":false}";

  CANCEL_PROCESS_ANNOTATIONS : constant String :=
    "{""readOnlyHint"":false,""destructiveHint"":true," &
    """idempotentHint"":true,""openWorldHint"":false}";

  ROTATE_WORKSPACE_TOKEN_TOOL_DESCRIPTOR : constant String :=
    "{""name"":""rotate_workspace_token"",""description"":""" &
    "Publishes one fresh generation-fenced workspace token. " &
    "A newer token makes older tokens for the same root stale." &
    """,""inputSchema"":" & ROTATE_WORKSPACE_TOKEN_INPUT_SCHEMA &
    ",""outputSchema"":" & ROTATE_WORKSPACE_TOKEN_OUTPUT_SCHEMA &
    ",""annotations"":" & WORKSPACE_ANNOTATIONS & "}";

  START_PROCESS_TOOL_DESCRIPTOR : constant String :=
    "{""name"":""start_process"",""description"":""" &
    "Starts one bounded server-owned noninteractive process for work " &
    "that may outlive one synchronous request." &
    """,""inputSchema"":" & START_PROCESS_INPUT_SCHEMA &
    ",""outputSchema"":" & START_PROCESS_OUTPUT_SCHEMA &
    ",""annotations"":" & RUN_PROCESS_ANNOTATIONS & "}";

  POLL_PROCESS_TOOL_DESCRIPTOR : constant String :=
    "{""name"":""poll_process"",""description"":""" &
    "Reads one bounded process-output increment at an opaque cursor." &
    """,""inputSchema"":" & POLL_PROCESS_INPUT_SCHEMA &
    ",""outputSchema"":" & POLL_PROCESS_OUTPUT_SCHEMA &
    ",""annotations"":" & POLL_PROCESS_ANNOTATIONS & "}";

  CANCEL_PROCESS_TOOL_DESCRIPTOR : constant String :=
    "{""name"":""cancel_process"",""description"":""" &
    "Requests cancellation of one server-owned process job." &
    """,""inputSchema"":" & CANCEL_PROCESS_INPUT_SCHEMA &
    ",""outputSchema"":" & CANCEL_PROCESS_OUTPUT_SCHEMA &
    ",""annotations"":" & CANCEL_PROCESS_ANNOTATIONS & "}";

  type Run_Process_Failure_Kind is
    (Run_Process_No_Failure,
     Run_Process_Status_Failure,
     Run_Process_Infrastructure_Failure,
     Run_Process_Cleanup_Failure);

  function classify_run_process_failure
    (status_failed         : Boolean;
     infrastructure_failed : Boolean;
     cleanup_failed        : Boolean)
  return Run_Process_Failure_Kind;

  procedure append_run_process_stream
    (target    : in out Response_Text;
     data      : System.Storage_Elements.Storage_Array;
     length    : Natural;
     truncated : Boolean;
     succeeded : in out Boolean);

  --! notes:
  --!   M4-02 currently supports Linux and FreeBSD, so absolute `cwd`
  --!   validation uses the supported POSIX path syntax.
  function run_process_projection_is_valid
    (message : Sonbal.MCP.JSON.Message;
     result  : in out Dispatch_Result)
  return Boolean;

  type Response_Text is record
    data   : String (1 .. MAXIMUM_MCP_RESPONSE_BYTES);
    length : Natural range 0 .. MAXIMUM_MCP_RESPONSE_BYTES := 0;
  end record;

  procedure append_response
    (target    : in out Response_Text;
     item      : String;
     succeeded : in out Boolean);

   type Context is limited record
      State : Dispatcher_State := Running;
   end record;
end Sonbal.MCP.Dispatcher;
