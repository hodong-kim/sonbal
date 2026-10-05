-- ============================================================================
-- sonbal-mcp-dispatcher-tester.ads
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Clair.Process.Execution;
with Clair.Status;
with Sonbal.Process_Jobs;

package Sonbal.MCP.Dispatcher.Tester is

  function response_boundary_is_enforced return Boolean;

  function run_process_input_schema return String;

  function run_process_output_schema return String;

  function poll_process_output_schema return String;

  function run_process_tool_descriptor return String;

  function run_process_response_bound_is_exact return Boolean;

  function read_file_maximum_response_length return Natural;

  function run_process_stream_image
    (data      : String;
     truncated : Boolean)
  return String;

  function run_process_result_image
    (status  : Clair.Status.Code;
     outcome : Clair.Process.Execution.Result)
  return String;

  function run_process_failure_classification
    (status_failed         : Boolean;
     infrastructure_failed : Boolean;
     cleanup_failed        : Boolean)
  return String;

  function poll_process_result_image
    (poll : Sonbal.Process_Jobs.Poll_Result)
  return String;

  function run_process_projection_validate (input : String) return Boolean;

end Sonbal.MCP.Dispatcher.Tester;
