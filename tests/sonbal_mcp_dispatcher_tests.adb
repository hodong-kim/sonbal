-- ============================================================================
-- sonbal_mcp_dispatcher_tests.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Clair.IO;
with Clair.Process.Execution;
with Clair.Status;
with Sonbal.MCP.JSON;
with Sonbal.MCP.Dispatcher;
with Sonbal.MCP.Dispatcher.Tester;
with Sonbal.Process_Arguments;
with Sonbal.Process_Jobs;
with Sonbal.Workspace_Tokens;
with Sonbal_Test_Support;

package body Sonbal_MCP_Dispatcher_Tests is
  use type Clair.IO.File_Offset;
  use type Sonbal.MCP.Dispatcher.Action_Kind;
  use type Sonbal.MCP.Dispatcher.Dispatcher_State;
  use type Sonbal.MCP.Dispatcher.Run_Process_Resolution;
  function request_meta
    (version             : String := Sonbal.MCP.Dispatcher.Protocol_Version;
     include_client_info : Boolean := True)
  return String
  is
    client_info : constant String :=
      (if include_client_info
       then
         ",""io.modelcontextprotocol/clientInfo"":{" &
         """name"":""client"",""version"":""1""}"
       else "");
  begin
    return
      """_meta"":{" &
      """io.modelcontextprotocol/protocolVersion"":""" & version &
      """,""io.modelcontextprotocol/clientCapabilities"":{}" &
      client_info & "}";
  end request_meta;

  function discover_request (id : String) return String is
  begin
    return
      "{""jsonrpc"":""2.0"",""id"":" & id &
      ",""method"":""server/discover"",""params"":{" &
      request_meta & "}}";
  end discover_request;

  function tools_list_request (id : String) return String is
  begin
    return
      "{""jsonrpc"":""2.0"",""id"":" & id &
      ",""method"":""tools/list"",""params"":{" &
      request_meta & "}}";
  end tools_list_request;

  function tools_call_request
    (id        : String;
     name      : String;
     arguments : String := "")
  return String
  is
    arguments_field : constant String :=
      (if arguments'length = 0
       then ""
       else ",""arguments"":" & arguments);
  begin
    return
      "{""jsonrpc"":""2.0"",""id"":" & id &
      ",""method"":""tools/call"",""params"":{" &
      request_meta & ",""name"":""" & name & """" &
      arguments_field & "}}";
  end tools_call_request;

  function contains
    (text : String;
     item : String)
  return Boolean
  is
    (Ada.Strings.Fixed.Index (text, item) /= 0);

  function repeated
    (item  : Character;
     count : Natural)
  return String
  is
    result : String (1 .. count);
  begin
    for index in result'range loop
      result(index) := item;
    end loop;

    return result;
  end repeated;

  function repeated_string_array
    (count : Positive;
     item  : String)
  return String
  is
    result : Ada.Strings.Unbounded.Unbounded_String :=
      Ada.Strings.Unbounded.to_unbounded_string ("[");
  begin
    for index in 1 .. count loop
      if index > 1 then
        Ada.Strings.Unbounded.append (result, ",");
      end if;

      Ada.Strings.Unbounded.append (result, """" & item & """");
    end loop;

    Ada.Strings.Unbounded.append (result, "]");
    return Ada.Strings.Unbounded.to_string (result);
  end repeated_string_array;

  function total_overflow_argv return String is
  begin
    return
      "[""" &
      repeated ('a', Sonbal.MCP.JSON.MAX_RUN_PROCESS_ARGUMENT_BYTES) &
      """,""x""]";
  end total_overflow_argv;

  function valid_workspace_token return String is
    ("w-" & repeated('a', 64));

  function valid_operation_id return String is
    ("o-" & repeated('b', 48));

  function valid_job_id return String is
    ("j-" & repeated('c', 80));

  function run_process_projection
    (argv       : String;
     resolution : String;
     cwd        : String;
     timeout    : String;
     extra      : String := "")
  return String
  is
  begin
    return
      "{""params"":{""arguments"":{" &
      """workspace_token"":""" & valid_workspace_token & """," &
      """argv"":" & argv & "," &
      """resolution"":""" & resolution & """," &
      """cwd"":""" & cwd & """," &
      """timeout_ms"":" & timeout & extra & "}}}";
  end run_process_projection;

  procedure parse_error
    (reporter : in out Clair.Test.Reporter.Context)
  is
    self : Sonbal.MCP.Dispatcher.Context;
    result  : Sonbal.MCP.Dispatcher.Dispatch_Result;
  begin
    Sonbal.MCP.Dispatcher.handle (self, "{", result);
    Sonbal_Test_Support.check
      (reporter,
       result.action = Sonbal.MCP.Dispatcher.Write_Response,
       "malformed JSON produces a response");
    Sonbal_Test_Support.check
      (reporter,
       contains (Sonbal.MCP.Dispatcher.image (result.response), "-32700") and then
         contains
           (Sonbal.MCP.Dispatcher.image (result.response), """id"":null"),
       "malformed JSON maps to an uncorrelated parse error");
    Sonbal_Test_Support.check
      (reporter,
       Sonbal.MCP.Dispatcher.current_state (self) =
         Sonbal.MCP.Dispatcher.Running,
       "parse error preserves dispatcher state");
  end parse_error;

  procedure bounded_policy_rejection_preserves_request_id
    (reporter : in out Clair.Test.Reporter.Context)
  is
    self : Sonbal.MCP.Dispatcher.Context;
    result  : Sonbal.MCP.Dispatcher.Dispatch_Result;
    input   : constant String :=
      "{""jsonrpc"":""2.0"",""id"":0," &
      """method"":""" &
      repeated ('x', Sonbal.MCP.JSON.Max_Decoded_String_Bytes + 1) &
      """,""params"":{}}";
  begin
    Sonbal.MCP.Dispatcher.handle (self, input, result);
    declare
      response : constant String :=
        Sonbal.MCP.Dispatcher.image (result.response);
    begin
      Sonbal_Test_Support.check
        (reporter,
         result.action = Sonbal.MCP.Dispatcher.Write_Response and then
           contains (response, """id"":0") and then
           contains (response, "-32600"),
         "bounded parser policy rejection preserves request correlation");
    end;
    Sonbal_Test_Support.check
      (reporter,
       Sonbal.MCP.Dispatcher.current_state (self) =
         Sonbal.MCP.Dispatcher.Running,
       "bounded parser policy rejection preserves dispatcher state");
  end bounded_policy_rejection_preserves_request_id;

  procedure discovery_reports_current_protocol
    (reporter : in out Clair.Test.Reporter.Context)
  is
    self : Sonbal.MCP.Dispatcher.Context;
    result  : Sonbal.MCP.Dispatcher.Dispatch_Result;
  begin
    Sonbal.MCP.Dispatcher.handle (self, discover_request ("1"), result);

    declare
      response : constant String :=
        Sonbal.MCP.Dispatcher.image (result.response);
    begin
      Sonbal_Test_Support.check
        (reporter,
         result.action = Sonbal.MCP.Dispatcher.Write_Response,
         "server/discover produces a response");
      Sonbal_Test_Support.check
        (reporter,
         contains (response, Sonbal.MCP.Dispatcher.Protocol_Version),
         "discovery reports the supported protocol version");
      Sonbal_Test_Support.check
        (reporter,
         contains (response, Sonbal.MCP.Dispatcher.Server_Version) and then
           contains (response, "sonbal"),
         "discovery reports Sonbal server identity");
    end;
  end discovery_reports_current_protocol;

  procedure tool_list_exposes_current_process_surface
    (reporter : in out Clair.Test.Reporter.Context)
  is
    self : Sonbal.MCP.Dispatcher.Context;
    result  : Sonbal.MCP.Dispatcher.Dispatch_Result;
  begin
    Sonbal.MCP.Dispatcher.handle (self, tools_list_request ("2"), result);

    declare
      response : constant String :=
        Sonbal.MCP.Dispatcher.image (result.response);
    begin
      Sonbal_Test_Support.check
        (reporter,
         result.action = Sonbal.MCP.Dispatcher.Write_Response,
         "tools/list produces a response");
      Sonbal_Test_Support.check
        (reporter,
         contains (response, """name"":""ping""") and then
           contains (response, """name"":""rotate_workspace_token""") and then
           not contains (response, """name"":""takeover_workspace""") and then
           not contains (response, """name"":""deactivate_workspace""") and then
           contains (response, """name"":""run_process""") and then
           contains (response, """name"":""start_process""") and then
           contains (response, """name"":""poll_process""") and then
           contains (response, """name"":""cancel_process""") and then
           contains (response, """name"":""read_file""") and then
           contains
             (response,
              "Reads one bounded byte range from a regular file") and then
           contains
             (response,
              "Use start_process for expected long-running work.") and then
           contains
             (response,
              "that may outlive one synchronous request.") and then
           not contains (response, """name"":""recover_workspace"""),
         "tools/list exposes the ordinary workspace-token tool surface");
    end;
  end tool_list_exposes_current_process_surface;

  procedure ping_completion_reports_release_identity
    (reporter : in out Clair.Test.Reporter.Context)
  is
    self : Sonbal.MCP.Dispatcher.Context;
    result  : Sonbal.MCP.Dispatcher.Dispatch_Result;
  begin
    Sonbal.MCP.Dispatcher.handle
      (self, tools_call_request ("3", "ping", "{}"), result);
    Sonbal_Test_Support.check
      (reporter,
       result.action = Sonbal.MCP.Dispatcher.Invoke_Ping,
       "ping request dispatches without side effects");

    Sonbal.MCP.Dispatcher.complete_ping (self, result);

    declare
      response : constant String :=
        Sonbal.MCP.Dispatcher.image (result.response);
    begin
      Sonbal_Test_Support.check
        (reporter,
         result.action = Sonbal.MCP.Dispatcher.Write_Response,
         "ping completion produces a response");
      Sonbal_Test_Support.check
        (reporter,
         contains (response, Sonbal.MCP.Dispatcher.Server_Version) and then
           contains (response, Sonbal.MCP.Dispatcher.Server_Revision),
         "ping completion carries release identity");
    end;
  end ping_completion_reports_release_identity;





  procedure unknown_tool_and_argument_are_rejected
    (reporter : in out Clair.Test.Reporter.Context)
  is
    dispatcher : Sonbal.MCP.Dispatcher.Context;
    result     : Sonbal.MCP.Dispatcher.Dispatch_Result;
    input      : constant String :=
      tools_call_request
        ("27",
         "run_process",
         "{""unexpected"":1," &
         """workspace_token"":""" & valid_workspace_token &
         """,""argv"":[""/usr/bin/true""]," &
         """resolution"":""exact_path""," &
         """cwd"":""/"",""timeout_ms"":1000}");
  begin
    Sonbal.MCP.Dispatcher.handle
      (dispatcher,
       tools_call_request ("26", "unknown_tool", "{}"),
       result);
    Sonbal_Test_Support.check
      (reporter,
       result.action = Sonbal.MCP.Dispatcher.Write_Response and then
         contains (Sonbal.MCP.Dispatcher.image (result.response), "-32602"),
       "unknown tool name is rejected");

    Sonbal.MCP.Dispatcher.handle (dispatcher, input, result);
    Sonbal_Test_Support.check
      (reporter,
       result.action = Sonbal.MCP.Dispatcher.Write_Response and then
         contains (Sonbal.MCP.Dispatcher.image (result.response), "-32602"),
       "unknown run_process argument is rejected");
  end unknown_tool_and_argument_are_rejected;

  procedure unknown_method_is_rejected
    (reporter : in out Clair.Test.Reporter.Context)
  is
    dispatcher : Sonbal.MCP.Dispatcher.Context;
    result     : Sonbal.MCP.Dispatcher.Dispatch_Result;
    input      : constant String :=
      "{""jsonrpc"":""2.0"",""id"":8," &
      """method"":""initialize"",""params"":{" & request_meta & "}}";
  begin
    Sonbal.MCP.Dispatcher.handle (dispatcher, input, result);
    Sonbal_Test_Support.check
      (reporter,
       result.action = Sonbal.MCP.Dispatcher.Write_Response and then
         contains (Sonbal.MCP.Dispatcher.image (result.response), "-32601"),
       "unsupported method maps to method-not-found");
  end unknown_method_is_rejected;

  procedure invalid_top_level_array_is_rejected
    (reporter : in out Clair.Test.Reporter.Context)
  is
    dispatcher : Sonbal.MCP.Dispatcher.Context;
    result     : Sonbal.MCP.Dispatcher.Dispatch_Result;
  begin
    Sonbal.MCP.Dispatcher.handle (dispatcher, "[]", result);
    Sonbal_Test_Support.check
      (reporter,
       result.action = Sonbal.MCP.Dispatcher.Write_Response and then
         contains (Sonbal.MCP.Dispatcher.image (result.response), "-32600"),
       "top-level JSON array is rejected as an invalid JSON-RPC request");
    Sonbal_Test_Support.check
      (reporter,
       Sonbal.MCP.Dispatcher.current_state (dispatcher) =
         Sonbal.MCP.Dispatcher.Running,
       "invalid top-level JSON preserves dispatcher state");
  end invalid_top_level_array_is_rejected;

  procedure unknown_notification_is_silent
    (reporter : in out Clair.Test.Reporter.Context)
  is
    dispatcher : Sonbal.MCP.Dispatcher.Context;
    result     : Sonbal.MCP.Dispatcher.Dispatch_Result;
  begin
    Sonbal.MCP.Dispatcher.handle
      (dispatcher,
       "{""jsonrpc"":""2.0"",""method"":""resources/list""}",
       result);
    Sonbal_Test_Support.check
      (reporter,
       result.action = Sonbal.MCP.Dispatcher.No_Action and then
         result.notification and then
         Sonbal.MCP.Dispatcher.is_empty (result.response),
       "unknown notification remains silent and explicitly classified");
    Sonbal_Test_Support.check
      (reporter,
       Sonbal.MCP.Dispatcher.current_state (dispatcher) =
         Sonbal.MCP.Dispatcher.Running,
       "unknown notification preserves dispatcher state");
  end unknown_notification_is_silent;

  procedure malformed_notification_is_not_classified
    (reporter : in out Clair.Test.Reporter.Context)
  is
    dispatcher : Sonbal.MCP.Dispatcher.Context;
    result     : Sonbal.MCP.Dispatcher.Dispatch_Result;
  begin
    Sonbal.MCP.Dispatcher.handle
      (dispatcher,
       "{""jsonrpc"":""1.0"",""method"":""notifications/progress""}",
       result);
    Sonbal_Test_Support.check
      (reporter,
       result.action = Sonbal.MCP.Dispatcher.No_Action and then
         not result.notification and then
         Sonbal.MCP.Dispatcher.is_empty (result.response),
       "malformed no-id message is not promoted to notification receipt");
  end malformed_notification_is_not_classified;

  procedure unsupported_protocol_version_is_rejected
    (reporter : in out Clair.Test.Reporter.Context)
  is
    dispatcher : Sonbal.MCP.Dispatcher.Context;
    result     : Sonbal.MCP.Dispatcher.Dispatch_Result;
    input      : constant String :=
      "{""jsonrpc"":""2.0"",""id"":10," &
      """method"":""server/discover"",""params"":{" &
      request_meta ("2027-01-01") & "}}";
  begin
    Sonbal.MCP.Dispatcher.handle (dispatcher, input, result);
    Sonbal_Test_Support.check
      (reporter,
       result.action = Sonbal.MCP.Dispatcher.Write_Response and then
         contains (Sonbal.MCP.Dispatcher.image (result.response), "-32022") and then
         contains
           (Sonbal.MCP.Dispatcher.image (result.response), "2027-01-01"),
       "unsupported protocol version uses the version-negotiation error");
    Sonbal_Test_Support.check
      (reporter,
       Sonbal.MCP.Dispatcher.current_state (dispatcher) =
         Sonbal.MCP.Dispatcher.Running,
       "unsupported protocol version preserves dispatcher state");
  end unsupported_protocol_version_is_rejected;

  procedure discovery_client_info_is_optional
    (reporter : in out Clair.Test.Reporter.Context)
  is
    dispatcher : Sonbal.MCP.Dispatcher.Context;
    result     : Sonbal.MCP.Dispatcher.Dispatch_Result;
    input      : constant String :=
      "{""jsonrpc"":""2.0"",""id"":11," &
      """method"":""server/discover"",""params"":{" &
      request_meta (include_client_info => False) & "}}";
  begin
    Sonbal.MCP.Dispatcher.handle (dispatcher, input, result);
    Sonbal_Test_Support.check
      (reporter,
       result.action = Sonbal.MCP.Dispatcher.Write_Response and then
         contains
           (Sonbal.MCP.Dispatcher.image (result.response),
            Sonbal.MCP.Dispatcher.Protocol_Version),
       "clientInfo remains optional in per-request metadata");
  end discovery_client_info_is_optional;

  procedure incomplete_client_info_is_rejected
    (reporter : in out Clair.Test.Reporter.Context)
  is
    dispatcher : Sonbal.MCP.Dispatcher.Context;
    result     : Sonbal.MCP.Dispatcher.Dispatch_Result;
    input      : constant String :=
      "{""jsonrpc"":""2.0"",""id"":12," &
      """method"":""server/discover"",""params"":{" &
      """_meta"":{" &
      """io.modelcontextprotocol/protocolVersion"":""" &
      Sonbal.MCP.Dispatcher.Protocol_Version &
      """,""io.modelcontextprotocol/clientCapabilities"":{}," &
      """io.modelcontextprotocol/clientInfo"":{""name"":""client""}}}}";
  begin
    Sonbal.MCP.Dispatcher.handle (dispatcher, input, result);
    Sonbal_Test_Support.check
      (reporter,
       result.action = Sonbal.MCP.Dispatcher.Write_Response and then
         contains (Sonbal.MCP.Dispatcher.image (result.response), "-32602"),
       "present clientInfo requires both name and version");
    Sonbal_Test_Support.check
      (reporter,
       Sonbal.MCP.Dispatcher.current_state (dispatcher) =
         Sonbal.MCP.Dispatcher.Running,
       "invalid clientInfo preserves dispatcher state");
  end incomplete_client_info_is_rejected;

  procedure repeated_discovery_is_stateless
    (reporter : in out Clair.Test.Reporter.Context)
  is
    dispatcher : Sonbal.MCP.Dispatcher.Context;
    result     : Sonbal.MCP.Dispatcher.Dispatch_Result;
  begin
    Sonbal.MCP.Dispatcher.handle (dispatcher, discover_request ("13"), result);
    Sonbal.MCP.Dispatcher.handle (dispatcher, discover_request ("14"), result);
    Sonbal_Test_Support.check
      (reporter,
       result.action = Sonbal.MCP.Dispatcher.Write_Response and then
         contains (Sonbal.MCP.Dispatcher.image (result.response), """id"":14"),
       "repeated discovery remains independent and stateless");
  end repeated_discovery_is_stateless;

  procedure tools_list_cursor_and_unknown_params_are_bounded
    (reporter : in out Clair.Test.Reporter.Context)
  is
    dispatcher : Sonbal.MCP.Dispatcher.Context;
    result     : Sonbal.MCP.Dispatcher.Dispatch_Result;
  begin
    Sonbal.MCP.Dispatcher.handle
      (dispatcher,
       "{""jsonrpc"":""2.0"",""id"":15," &
       """method"":""tools/list"",""params"":{" &
       request_meta & ",""cursor"":""""}}",
       result);
    Sonbal_Test_Support.check
      (reporter,
       result.action = Sonbal.MCP.Dispatcher.Write_Response and then
         contains (Sonbal.MCP.Dispatcher.image (result.response), """tools"""),
       "empty tools/list cursor receives the static tool list");

    Sonbal.MCP.Dispatcher.handle
      (dispatcher,
       "{""jsonrpc"":""2.0"",""id"":16," &
       """method"":""tools/list"",""params"":{" &
       request_meta & ",""cursor"":""next""}}",
       result);
    Sonbal_Test_Support.check
      (reporter,
       result.action = Sonbal.MCP.Dispatcher.Write_Response and then
         contains (Sonbal.MCP.Dispatcher.image (result.response), "-32602"),
       "nonempty tools/list cursor is rejected");

    Sonbal.MCP.Dispatcher.handle
      (dispatcher,
       "{""jsonrpc"":""2.0"",""id"":17," &
       """method"":""tools/list"",""params"":{" &
       request_meta & ",""extra"":0}}",
       result);
    Sonbal_Test_Support.check
      (reporter,
       result.action = Sonbal.MCP.Dispatcher.Write_Response and then
         contains (Sonbal.MCP.Dispatcher.image (result.response), "-32602"),
       "unknown tools/list parameter is rejected");
  end tools_list_cursor_and_unknown_params_are_bounded;

  procedure ping_preserves_request_id_spelling
    (reporter : in out Clair.Test.Reporter.Context)
  is
    dispatcher : Sonbal.MCP.Dispatcher.Context;
    result     : Sonbal.MCP.Dispatcher.Dispatch_Result;
    id         : constant String := """p\u0069ng""";
  begin
    Sonbal.MCP.Dispatcher.handle
      (dispatcher, tools_call_request (id, "ping", "{}"), result);
    Sonbal_Test_Support.check
      (reporter,
       result.action = Sonbal.MCP.Dispatcher.Invoke_Ping and then
         Sonbal.MCP.JSON.image (result.request_id) = id and then
         Sonbal.MCP.Dispatcher.is_empty (result.response),
       "ping invocation preserves exact request ID spelling before completion");

    Sonbal.MCP.Dispatcher.complete_ping (dispatcher, result);
    Sonbal_Test_Support.check
      (reporter,
       result.action = Sonbal.MCP.Dispatcher.Write_Response and then
         contains (Sonbal.MCP.Dispatcher.image (result.response), id),
       "ping completion returns the preserved request ID spelling");
  end ping_preserves_request_id_spelling;



  procedure unknown_modern_request_is_rejected
    (reporter : in out Clair.Test.Reporter.Context)
  is
    dispatcher : Sonbal.MCP.Dispatcher.Context;
    result     : Sonbal.MCP.Dispatcher.Dispatch_Result;
    input      : constant String :=
      "{""jsonrpc"":""2.0"",""id"":24," &
      """method"":""resources/list"",""params"":{" & request_meta & "}}";
  begin
    Sonbal.MCP.Dispatcher.handle (dispatcher, input, result);
    Sonbal_Test_Support.check
      (reporter,
       result.action = Sonbal.MCP.Dispatcher.Write_Response and then
         contains (Sonbal.MCP.Dispatcher.image (result.response), "-32601"),
       "unknown modern request maps to method-not-found");
  end unknown_modern_request_is_rejected;

  procedure run_process_schema_is_frozen
    (reporter : in out Clair.Test.Reporter.Context)
  is
    expected : constant String :=
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
  begin
    Sonbal_Test_Support.check
      (reporter,
       Sonbal.MCP.Dispatcher.Tester.run_process_input_schema = expected,
       "run_process input schema matches the workspace-owned contract");
  end run_process_schema_is_frozen;

  procedure run_process_output_contract_is_frozen
    (reporter : in out Clair.Test.Reporter.Context)
  is
    schema : constant String :=
      Sonbal.MCP.Dispatcher.Tester.run_process_output_schema;
    poll_schema : constant String :=
      Sonbal.MCP.Dispatcher.Tester.poll_process_output_schema;
    descriptor : constant String :=
      Sonbal.MCP.Dispatcher.Tester.run_process_tool_descriptor;
  begin
    Sonbal_Test_Support.check
      (reporter,
       contains
           (schema,
            """status"":{""type"":""string"",""enum"":" &
            "[""exited"",""signaled"",""timed_out"",""launch_failed""," &
            """execution_failed"",""execution_busy"",""stale_workspace_token""," &
            """outside_workspace""]") and then
         contains
           (schema,
            """data"":{""type"":""string"",""maxLength"":43692") and then
         contains (schema, """maximum"":4294967295") and then
         contains
           (schema,
            "[""executable_resolution"",""working_directory""," &
            """standard_stream"",""environment_construction""," &
            """program_execution""]") and then
         contains
           (schema,
            "[""execution_preparation"",""process_creation""," &
            """process_monitoring"",""process_termination""," &
            """output_drain"",""process_wait"",""resource_cleanup""]") and then
         contains
           (schema, "[""setup"",""launch"",""settlement""]") and then
         contains
           (poll_schema, "[""setup"",""launch"",""settlement""]") and then
         contains
           (schema,
            """required"":[""status"",""stdout"",""stderr""]") and then
         contains (schema, """additionalProperties"":false"),
       "run_process output schema freezes portable result fields");

    Sonbal_Test_Support.check
      (reporter,
       contains (descriptor, """name"":""run_process""") and then
         contains (descriptor, """outputSchema"":") and then
         contains
           (descriptor,
            """readOnlyHint"":false,""destructiveHint"":true," &
            """idempotentHint"":false,""openWorldHint"":true"),
       "exposed run_process descriptor remains byte-stable");
  end run_process_output_contract_is_frozen;

  procedure ownership_stage_result_contract_is_frozen
    (reporter : in out Clair.Test.Reporter.Context)
  is
    procedure check
      (stage : Clair.Process.Execution.Ownership_Failure_Stage;
       wire  : String)
    is
      poll : Sonbal.Process_Jobs.Poll_Result;
    begin
      poll.state := Sonbal.Process_Jobs.Poll_Terminal;
      poll.terminal := Sonbal.Process_Jobs.Job_Execution_Failed;
      poll.has_infrastructure_stage := True;
      poll.infrastructure_stage := Clair.Process.Execution.Resource_Cleanup_Stage;
      poll.has_ownership_stage := True;
      poll.ownership_stage := stage;

      declare
        response : constant String :=
          Sonbal.MCP.Dispatcher.Tester.poll_process_result_image (poll);
      begin
        Sonbal_Test_Support.check
          (reporter,
           contains
             (response,
              """infrastructure_stage"":""resource_cleanup""") and then
           contains
             (response, """ownership_stage"":""" & wire & """") and then
           contains (response, """status"":""execution_failed"""),
           "terminal poll maps ownership " & wire &
             " independently from infrastructure stage");
      end;
    end check;
  begin
    check (Clair.Process.Execution.Ownership_Setup_Stage, "setup");
    check (Clair.Process.Execution.Ownership_Launch_Stage, "launch");
    check (Clair.Process.Execution.Ownership_Settlement_Stage, "settlement");
  end ownership_stage_result_contract_is_frozen;

  procedure run_process_static_bounds_are_exact
    (reporter : in out Clair.Test.Reporter.Context)
  is
    dispatcher : Sonbal.MCP.Dispatcher.Context;
    result     : Sonbal.MCP.Dispatcher.Dispatch_Result;
    request_id : constant String :=
      """" &
      repeated ('i', Sonbal.MCP.JSON.Max_Request_Id_Bytes - 2) &
      """";
  begin
    Sonbal.MCP.Dispatcher.handle
      (dispatcher, tools_list_request (request_id), result);

    Sonbal_Test_Support.check
      (reporter,
       result.action = Sonbal.MCP.Dispatcher.Write_Response and then
         Sonbal.MCP.Dispatcher.length (result.response) =
           Sonbal.MCP.Dispatcher.MAXIMUM_TOOLS_LIST_RESPONSE_BYTES,
       "exposed tools/list maximum is exact");

    Sonbal_Test_Support.check
      (reporter,
       Sonbal.MCP.Dispatcher.Tester.run_process_response_bound_is_exact,
       "maximum run_process response fits exactly and one more byte fails");

    Sonbal_Test_Support.check
      (reporter,
       Sonbal.MCP.Dispatcher.Tester.read_file_maximum_response_length =
         Sonbal.MCP.Dispatcher.MAXIMUM_READ_FILE_RESPONSE_BYTES,
       "maximum read_file response bound is exact");
  end run_process_static_bounds_are_exact;

  procedure run_process_stream_representation_is_lossless
    (reporter : in out Clair.Test.Reporter.Context)
  is
    line_data : constant String := "line" & Character'val (10);
    quote_data : constant String :=
      String'(1 => Character'val (34), 2 => Character'val (92));
    nul_data : constant String := String'(1 => Character'val (0));
    invalid_data : constant String := String'(1 => Character'val (16#FF#));
    maximum_data : constant String (1 .. 32_768) :=
      [others => Character'val (16#FF#)];
    overflow_data : constant String (1 .. 32_769) :=
      [others => Character'val (16#FF#)];
    line_image : constant String :=
      Sonbal.MCP.Dispatcher.Tester.run_process_stream_image
        (line_data, truncated => True);
    quote_image : constant String :=
      Sonbal.MCP.Dispatcher.Tester.run_process_stream_image
        (quote_data, truncated => False);
    nul_image : constant String :=
      Sonbal.MCP.Dispatcher.Tester.run_process_stream_image
        (nul_data, truncated => False);
    invalid_image : constant String :=
      Sonbal.MCP.Dispatcher.Tester.run_process_stream_image
        (invalid_data, truncated => False);
    maximum_image : constant String :=
      Sonbal.MCP.Dispatcher.Tester.run_process_stream_image
        (maximum_data, truncated => True);
    overflow_image : constant String :=
      Sonbal.MCP.Dispatcher.Tester.run_process_stream_image
        (overflow_data, truncated => True);
    expected_line : constant String :=
      "{""encoding"":""utf8"",""bytes"":5,""data"":""line" &
      String'(1 => Character'val (92)) & "n" &
      """,""truncated"":true}";
    expected_quote : constant String :=
      "{""encoding"":""utf8"",""bytes"":2,""data"":""" &
      String'(1 => Character'val (92),
              2 => Character'val (34),
              3 => Character'val (92),
              4 => Character'val (92)) &
      """,""truncated"":false}";
  begin
    Sonbal_Test_Support.check
      (reporter,
       line_image = expected_line,
       "UTF-8 process output uses deterministic JSON escaping");
    Sonbal_Test_Support.check
      (reporter,
       quote_image = expected_quote,
       "UTF-8 quote and reverse-solidus escaping is byte-stable");
    Sonbal_Test_Support.check
      (reporter,
       nul_image =
         "{""encoding"":""base64"",""bytes"":1," &
         """data"":""AA=="",""truncated"":false}",
       "valid UTF-8 uses base64 when JSON escaping would be larger");
    Sonbal_Test_Support.check
      (reporter,
       invalid_image =
         "{""encoding"":""base64"",""bytes"":1," &
         """data"":""/w=="",""truncated"":false}",
       "invalid UTF-8 process output remains lossless through base64");
    Sonbal_Test_Support.check
      (reporter,
       maximum_image'length = 43_754 and then
         contains
           (maximum_image,
            "{""encoding"":""base64"",""bytes"":32768," &
            """data"":""") and then
         contains (maximum_image, """,""truncated"":true}"),
       "maximum retained process stream serializes within its exact bound");
    Sonbal_Test_Support.check
      (reporter,
       overflow_image'length = 0,
       "one-byte retained process stream overflow is rejected");
  end run_process_stream_representation_is_lossless;

  procedure run_process_arguments_are_bounded
    (reporter : in out Clair.Test.Reporter.Context)
  is
    function validate (input : String) return Boolean
      renames Sonbal.MCP.Dispatcher.Tester.run_process_projection_validate;
  begin
    Sonbal_Test_Support.check
      (reporter,
       validate
         (run_process_projection
            ("[""/bin/echo"",""hello"",""""]",
             "exact_path",
             "/tmp",
             "1000")),
       "bounded run_process projection is accepted");

    Sonbal_Test_Support.check
      (reporter,
       validate
         (run_process_projection
            (repeated_string_array
               (1,
                repeated
                  ('a', Sonbal.MCP.JSON.MAX_RUN_PROCESS_ARGUMENT_BYTES)),
             "search_path",
             "/" & repeated
               ('c', Sonbal.MCP.JSON.MAX_RUN_PROCESS_CWD_BYTES - 1),
             "110000")),
       "exact argv, cwd, and timeout maxima are accepted");

    Sonbal_Test_Support.check
      (reporter,
       validate
         (run_process_projection
            (repeated_string_array
               (Sonbal.MCP.JSON.MAX_RUN_PROCESS_ARGUMENT_COUNT, "x"),
             "exact_path",
             "/tmp",
             "1")),
       "maximum argv item count and minimum timeout are accepted");

    Sonbal_Test_Support.check
      (reporter,
       not validate
         (run_process_projection
            ("[""""]", "exact_path", "/tmp", "1000")),
       "empty executable selector is rejected");

    Sonbal_Test_Support.check
      (reporter,
       not validate
         (run_process_projection
            ("[""/bin/echo"",1]", "exact_path", "/tmp", "1000")),
       "non-string argv elements are rejected");

    Sonbal_Test_Support.check
      (reporter,
       not validate
         (run_process_projection
            (repeated_string_array
               (Sonbal.MCP.JSON.MAX_RUN_PROCESS_ARGUMENT_COUNT + 1, "x"),
             "exact_path",
             "/tmp",
             "1000")),
       "one-item argv count overflow is rejected");

    Sonbal_Test_Support.check
      (reporter,
       not validate
         (run_process_projection
            ("[""" &
             repeated
               ('a', Sonbal.MCP.JSON.MAX_RUN_PROCESS_ARGUMENT_BYTES + 1) &
             """]",
             "exact_path",
             "/tmp",
             "1000")),
       "one-byte argv element overflow is rejected");

    Sonbal_Test_Support.check
      (reporter,
       not validate
         (run_process_projection
            (total_overflow_argv, "exact_path", "/tmp", "1000")),
       "one-byte total argv overflow is rejected");

    Sonbal_Test_Support.check
      (reporter,
       not validate
         (run_process_projection
            ("[""/bin/echo""]", "shell", "/tmp", "1000")),
       "unknown executable resolution is rejected");

    Sonbal_Test_Support.check
      (reporter,
       not validate
         (run_process_projection
            ("[""/bin/echo""]", "exact_path", "", "1000")),
       "empty working directory is rejected");

    Sonbal_Test_Support.check
      (reporter,
       not validate
         (run_process_projection
            ("[""/bin/echo""]",
             "exact_path",
             repeated ('c', Sonbal.MCP.JSON.MAX_RUN_PROCESS_CWD_BYTES + 1),
             "1000")),
       "one-byte working-directory overflow is rejected");

    Sonbal_Test_Support.check
      (reporter,
       not validate
         (run_process_projection
            ("[""/bin/echo""]", "exact_path", "tmp", "1000")),
       "relative working directory is rejected before process creation");

    Sonbal_Test_Support.check
      (reporter,
       not validate
         (run_process_projection
            ("[""/bin/echo\u0000x""]",
             "exact_path",
             "/tmp",
             "1000")),
       "embedded NUL in argv is rejected");

    Sonbal_Test_Support.check
      (reporter,
       not validate
         (run_process_projection
            ("[""/bin/echo""]",
             "exact_path",
             "/tmp\u0000x",
             "1000")),
       "embedded NUL in cwd is rejected");

    Sonbal_Test_Support.check
      (reporter,
       not validate
         (run_process_projection
            ("[""/bin/echo""]", "exact_path", "/tmp", "0")) and then
         not validate
           (run_process_projection
              ("[""/bin/echo""]", "exact_path", "/tmp", "110001")),
       "timeout bounds are enforced exactly");

    Sonbal_Test_Support.check
      (reporter,
       not validate
         (run_process_projection
            ("[""/bin/echo""]",
             "exact_path",
             "/tmp",
             "1000",
             extra => ",""unexpected"":true")),
       "unknown run_process members are rejected");

    Sonbal_Test_Support.check
      (reporter,
       not validate
         (run_process_projection
            ("[""/bin/echo""]",
             "exact_path",
             "/tmp",
             "1000",
             extra => ",""env"":{""HOME"":""/tmp""}")),
       "run_process does not expose remote environment mutation");
  end run_process_arguments_are_bounded;

  procedure run_process_dispatches_bounded_projection
    (reporter : in out Clair.Test.Reporter.Context)
  is
    dispatcher : Sonbal.MCP.Dispatcher.Context;
    result     : Sonbal.MCP.Dispatcher.Dispatch_Result;
    arguments  : constant String :=
      "{""workspace_token"":""" & valid_workspace_token &
      """,""argv"":[""/bin/echo""]," &
      """resolution"":""exact_path"",""cwd"":""/tmp""," &
      """timeout_ms"":1000}";
  begin
    Sonbal.MCP.Dispatcher.handle
      (dispatcher, tools_call_request ("25", "run_process", arguments), result);
    Sonbal_Test_Support.check
      (reporter,
       result.action = Sonbal.MCP.Dispatcher.Invoke_Run_Process and then
         result.run_process.timeout_ms = 1_000 and then
         Sonbal.MCP.JSON.image(result.run_process.workspace_token) =
           valid_workspace_token and then
         result.run_process.resolution =
           Sonbal.MCP.Dispatcher.Exact_Path and then
         Sonbal.MCP.JSON.image (result.run_process.cwd) = "/tmp" and then
         Sonbal.Process_Arguments.argument_at
           (result.run_process.argv, 1) = "/bin/echo",
       "run_process dispatches only the validated bounded projection");
  end run_process_dispatches_bounded_projection;

  procedure read_file_dispatches_bounded_projection
    (reporter : in out Clair.Test.Reporter.Context)
  is
    dispatcher : Sonbal.MCP.Dispatcher.Context;
    result : Sonbal.MCP.Dispatcher.Dispatch_Result;
    revision : constant String := "r1-" & repeated ('a', 96);

    procedure expect_invalid
      (id        : String;
       arguments : String;
       label     : String)
    is
    begin
      Sonbal.MCP.Dispatcher.handle
        (dispatcher,
         tools_call_request (id, "read_file", arguments),
         result);
      Sonbal_Test_Support.check
        (reporter,
         result.action = Sonbal.MCP.Dispatcher.Write_Response and then
           contains
             (Sonbal.MCP.Dispatcher.image (result.response), "-32602"),
         label);
    end expect_invalid;
  begin
    Sonbal.MCP.Dispatcher.handle
      (dispatcher,
       tools_call_request
         ("60",
          "read_file",
          "{""workspace_token"":""" & valid_workspace_token &
          """,""path"":""src/main.adb""}"),
       result);
    Sonbal_Test_Support.check
      (reporter,
       result.action = Sonbal.MCP.Dispatcher.Invoke_Read_File and then
         Sonbal.MCP.JSON.image (result.read_file.workspace_token) =
           valid_workspace_token and then
         Sonbal.MCP.JSON.image (result.read_file.path) =
           "src/main.adb" and then
         result.read_file.offset = 0 and then
         result.read_file.maximum_bytes = 16_384 and then
         Sonbal.MCP.JSON.is_empty (result.read_file.expected_revision),
       "read_file required arguments project deterministic defaults");

    Sonbal.MCP.Dispatcher.handle
      (dispatcher,
       tools_call_request
         ("61",
          "read_file",
          "{""workspace_token"":""" & valid_workspace_token &
          """,""path"":""large.bin""," &
          """offset"":9007199254740991," &
          """maximum_bytes"":1," &
          """expected_revision"":""" & revision & """}"),
       result);
    Sonbal_Test_Support.check
      (reporter,
       result.action = Sonbal.MCP.Dispatcher.Invoke_Read_File and then
         result.read_file.offset = 9_007_199_254_740_991 and then
         result.read_file.maximum_bytes = 1 and then
         Sonbal.MCP.JSON.image (result.read_file.expected_revision) = revision,
       "read_file projects the exact JSON-safe maximum offset and revision");

    expect_invalid
      ("62",
       "{""workspace_token"":""" & valid_workspace_token &
       """,""path"":""/etc/passwd""}",
       "read_file rejects an absolute path");
    expect_invalid
      ("63",
       "{""workspace_token"":""" & valid_workspace_token &
       """,""path"":""src/../secret""}",
       "read_file rejects dot-dot traversal");
    expect_invalid
      ("64",
       "{""workspace_token"":""" & valid_workspace_token &
       """,""path"":""a"",""offset"":9007199254740992}",
       "read_file rejects offset above exact JSON policy");
    expect_invalid
      ("65",
       "{""workspace_token"":""" & valid_workspace_token &
       """,""path"":""a"",""maximum_bytes"":0}",
       "read_file rejects zero maximum_bytes");
    expect_invalid
      ("66",
       "{""workspace_token"":""" & valid_workspace_token &
       """,""path"":""a"",""expected_revision"":""r1-bad""}",
       "read_file rejects a malformed revision");
    expect_invalid
      ("67",
       "{""workspace_token"":""" & valid_workspace_token &
       """,""path"":""a"",""unexpected"":1}",
       "read_file rejects unknown arguments");
  end read_file_dispatches_bounded_projection;

  procedure workspace_and_job_tools_are_bounded
    (reporter : in out Clair.Test.Reporter.Context)
  is
    dispatcher : Sonbal.MCP.Dispatcher.Context;
    result     : Sonbal.MCP.Dispatcher.Dispatch_Result;
    start_args : constant String :=
      "{""workspace_token"":""" & valid_workspace_token &
      """,""argv"":[""/usr/bin/true""]," &
      """resolution"":""exact_path"",""cwd"":""/tmp""," &
      """timeout_ms"":3600000}";
    cursor : constant String := valid_job_id & ":0:0";
  begin
    Sonbal.MCP.Dispatcher.handle
      (dispatcher,
       tools_call_request
         ("31", "rotate_workspace_token", "{""root"":""/tmp""}"),
       result);
    Sonbal_Test_Support.check
      (reporter,
       result.action =
         Sonbal.MCP.Dispatcher.Invoke_Rotate_Workspace_Token and then
         Sonbal.MCP.JSON.image(result.rotate_workspace_token.root) = "/tmp",
       "rotate_workspace_token dispatches one bounded absolute root");

    Sonbal.MCP.Dispatcher.handle
      (dispatcher,
       tools_call_request
         ("32",
          "rotate_workspace_token",
          "{""root"":""/tmp"",""operation_id"":""" &
          valid_operation_id & """}"),
       result);
    Sonbal_Test_Support.check
      (reporter,
       result.action =
         Sonbal.MCP.Dispatcher.Invoke_Rotate_Workspace_Token and then
         Sonbal.MCP.JSON.image(result.rotate_workspace_token.operation_id) =
           valid_operation_id,
       "rotate_workspace_token accepts one canonical replay operation id");


    Sonbal.MCP.Dispatcher.handle
      (dispatcher,
       tools_call_request("35", "start_process", start_args),
       result);
    Sonbal_Test_Support.check
      (reporter,
       result.action = Sonbal.MCP.Dispatcher.Invoke_Start_Process and then
         result.start_process.timeout_ms = 3_600_000 and then
         Sonbal.MCP.JSON.image(result.start_process.workspace_token) =
           valid_workspace_token,
       "start_process accepts its exact one-hour internal timeout ceiling");

    Sonbal.MCP.Dispatcher.handle
      (dispatcher,
       tools_call_request
         ("36",
          "poll_process",
          "{""job_id"":""" & valid_job_id & """," &
          """cursor"":""" & cursor & """}"),
       result);
    Sonbal_Test_Support.check
      (reporter,
       result.action = Sonbal.MCP.Dispatcher.Invoke_Poll_Process and then
         Sonbal.MCP.JSON.image(result.poll_process.job_id) =
           valid_job_id and then
         Sonbal.MCP.JSON.image(result.poll_process.cursor) = cursor,
       "poll_process preserves bounded opaque job identity and cursor");

    Sonbal.MCP.Dispatcher.handle
      (dispatcher,
       tools_call_request
         ("37", "cancel_process", "{""job_id"":""" & valid_job_id & """}"),
       result);
    Sonbal_Test_Support.check
      (reporter,
       result.action = Sonbal.MCP.Dispatcher.Invoke_Cancel_Process and then
         Sonbal.MCP.JSON.image(result.cancel_process.job_id) = valid_job_id,
       "cancel_process accepts one canonical opaque job identity");

    Sonbal.MCP.Dispatcher.handle
      (dispatcher,
       tools_call_request
         ("38",
          "rotate_workspace_token",
          "{""root"":""/tmp"",""operation_id"":""o-" &
          repeated('A', 48) & """}"),
       result);
    Sonbal_Test_Support.check
      (reporter,
       result.action = Sonbal.MCP.Dispatcher.Write_Response and then
         contains(Sonbal.MCP.Dispatcher.image(result.response), "-32602"),
       "open operation ids reject noncanonical uppercase hex");

    Sonbal.MCP.Dispatcher.handle
      (dispatcher,
       tools_call_request
         ("39",
          "run_process",
          "{""workspace_token"":""w-" & repeated('A', 64) &
          """,""argv"":[""/usr/bin/true""]," &
          """resolution"":""exact_path"",""cwd"":""/tmp""," &
          """timeout_ms"":1000}"),
       result);
    Sonbal_Test_Support.check
      (reporter,
       result.action = Sonbal.MCP.Dispatcher.Write_Response and then
         contains(Sonbal.MCP.Dispatcher.image(result.response), "-32602"),
       "workspace tokens reject noncanonical uppercase hex");

    Sonbal.MCP.Dispatcher.handle
      (dispatcher,
       tools_call_request
         ("40",
          "start_process",
          "{""workspace_token"":""" & valid_workspace_token &
          """,""argv"":[""/usr/bin/true""]," &
          """resolution"":""exact_path"",""cwd"":""/tmp""," &
          """timeout_ms"":3600001}"),
       result);
    Sonbal_Test_Support.check
      (reporter,
       result.action = Sonbal.MCP.Dispatcher.Write_Response and then
         contains(Sonbal.MCP.Dispatcher.image(result.response), "-32602"),
       "start_process rejects one millisecond above its frozen ceiling");

    Sonbal.MCP.Dispatcher.handle
      (dispatcher,
       tools_call_request
         ("41",
          "poll_process",
          "{""job_id"":""" & valid_job_id & """," &
          """cursor"":""" & repeated('x', 95) & """}"),
       result);
    Sonbal_Test_Support.check
      (reporter,
       result.action = Sonbal.MCP.Dispatcher.Write_Response and then
         contains(Sonbal.MCP.Dispatcher.image(result.response), "-32602"),
       "poll_process rejects one byte beyond the cursor envelope");
  end workspace_and_job_tools_are_bounded;

  procedure retired_workspace_tools_are_absent
    (reporter : in out Clair.Test.Reporter.Context)
  is
    procedure check_absent
      (request_id : String;
       tool_name  : String)
    is
      dispatcher : Sonbal.MCP.Dispatcher.Context;
      message    : Sonbal.MCP.JSON.Message;
      status     : Sonbal.MCP.JSON.Parse_Status;
      result     : Sonbal.MCP.Dispatcher.Dispatch_Result;
      input      : constant String :=
        tools_call_request
          (request_id,
           tool_name,
           "{""root"":""/tmp""}");
    begin
      Sonbal.MCP.JSON.parse (input, message, status);
      Sonbal.MCP.Dispatcher.handle_parsed
        (dispatcher, message, status, result);
      Sonbal_Test_Support.check
        (reporter,
         result.action = Sonbal.MCP.Dispatcher.Write_Response and then
           contains (Sonbal.MCP.Dispatcher.image (result.response), "-32602"),
         "legacy " & tool_name & " is absent from ordinary dispatch");
    end check_absent;
  begin
    check_absent ("42", "recover_workspace");
    check_absent ("43", "takeover_workspace");
    check_absent ("44", "open_workspace_session");
    check_absent ("45", "close_workspace_session");
    check_absent ("46", "activate_workspace");
    check_absent ("47", "deactivate_workspace");
  end retired_workspace_tools_are_absent;

  procedure rotation_completion_reports_bounded_refusals
    (reporter : in out Clair.Test.Reporter.Context)
  is
    dispatcher : Sonbal.MCP.Dispatcher.Context;
    result     : Sonbal.MCP.Dispatcher.Dispatch_Result;
    rotation       : constant Sonbal.Workspace_Tokens.Rotation_Result :=
      (state => Sonbal.Workspace_Tokens.Rotation_Cooldown, others => <>);
  begin
    Sonbal.MCP.Dispatcher.handle
      (dispatcher,
       tools_call_request
         ("43", "rotate_workspace_token", "{""root"":""/tmp""}"),
       result);
    Sonbal.MCP.Dispatcher.complete_rotate_workspace_token
      (dispatcher, result, Clair.Status.OK, rotation);
    declare
      response : constant String :=
        Sonbal.MCP.Dispatcher.image (result.response);
    begin
      Sonbal_Test_Support.check
        (reporter,
         result.action = Sonbal.MCP.Dispatcher.Write_Response and then
           contains (response, """status"":""cooldown""") and then
           contains (response, """isError"":true") and then
           not contains (response, """workspace_token"""),
         "rotation cooldown reports a bounded refusal without token leakage");
    end;

  end rotation_completion_reports_bounded_refusals;

  procedure response_boundary_is_enforced
    (reporter : in out Clair.Test.Reporter.Context)
  is
  begin
    Sonbal_Test_Support.check
      (reporter,
       Sonbal.MCP.Dispatcher.Tester.response_boundary_is_enforced,
       "dispatcher refuses to grow a response past its fixed bound");
  end response_boundary_is_enforced;

  procedure stop_is_terminal_for_dispatcher_lifetime
    (reporter : in out Clair.Test.Reporter.Context)
  is
    dispatcher : Sonbal.MCP.Dispatcher.Context;
    result     : Sonbal.MCP.Dispatcher.Dispatch_Result;
  begin
    Sonbal.MCP.Dispatcher.stop (dispatcher);
    Sonbal.MCP.Dispatcher.handle (dispatcher, discover_request ("9"), result);
    Sonbal_Test_Support.check
      (reporter,
       Sonbal.MCP.Dispatcher.current_state (dispatcher) =
         Sonbal.MCP.Dispatcher.Stopping and then
         result.action = Sonbal.MCP.Dispatcher.No_Action,
       "stopped dispatcher accepts no further work");
  end stop_is_terminal_for_dispatcher_lifetime;

  procedure run (reporter : in out Clair.Test.Reporter.Context) is
  begin
    Clair.Test.Reporter.run_scenario
      (reporter, "parse error", parse_error'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "bounded policy rejection preserves request id",
       bounded_policy_rejection_preserves_request_id'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "discovery reports current protocol",
       discovery_reports_current_protocol'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "tool list exposes current process surface",
       tool_list_exposes_current_process_surface'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "ping completion reports release identity",
       ping_completion_reports_release_identity'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "unknown tool and argument are rejected",
       unknown_tool_and_argument_are_rejected'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "unknown method is rejected",
       unknown_method_is_rejected'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "invalid top-level array is rejected",
       invalid_top_level_array_is_rejected'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "unknown notification is silent",
       unknown_notification_is_silent'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "malformed notification is not classified",
       malformed_notification_is_not_classified'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "unsupported protocol version is rejected",
       unsupported_protocol_version_is_rejected'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "discovery client info is optional",
       discovery_client_info_is_optional'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "incomplete client info is rejected",
       incomplete_client_info_is_rejected'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "repeated discovery is stateless",
       repeated_discovery_is_stateless'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "tools list cursor and unknown params are bounded",
       tools_list_cursor_and_unknown_params_are_bounded'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "ping preserves request id spelling",
       ping_preserves_request_id_spelling'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "unknown modern request is rejected",
       unknown_modern_request_is_rejected'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "run_process schema is frozen",
       run_process_schema_is_frozen'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "run_process output contract is frozen",
       run_process_output_contract_is_frozen'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "ownership stage result contract is frozen",
       ownership_stage_result_contract_is_frozen'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "run_process static bounds are exact",
       run_process_static_bounds_are_exact'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "run_process stream representation is lossless",
       run_process_stream_representation_is_lossless'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "run_process arguments are bounded",
       run_process_arguments_are_bounded'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "run_process dispatches bounded projection",
       run_process_dispatches_bounded_projection'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "read_file dispatches bounded projection",
       read_file_dispatches_bounded_projection'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "workspace and job tools are bounded",
       workspace_and_job_tools_are_bounded'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "retired workspace tools are absent",
       retired_workspace_tools_are_absent'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "rotation completion reports bounded refusals",
       rotation_completion_reports_bounded_refusals'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "response boundary is enforced",
       response_boundary_is_enforced'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "stop is terminal for dispatcher lifetime",
       stop_is_terminal_for_dispatcher_lifetime'access);
  end run;

end Sonbal_MCP_Dispatcher_Tests;
