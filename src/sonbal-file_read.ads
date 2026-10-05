-- ============================================================================
-- sonbal-file_read.ads
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Clair.IO;
with Clair.Process.Execution;
with Clair.Status;
with Interfaces;
with Sonbal.Process_Arguments;
with System.Storage_Elements;

package Sonbal.File_Read is

  MAXIMUM_PATH_BYTES       : constant Positive := 4_096;
  MAXIMUM_CONTENT_BYTES    : constant Positive := 16_384;
  MAXIMUM_REVISION_BYTES   : constant Positive := 99;
  HELPER_TIMEOUT_MS        : constant Positive := 10_000;

  MAXIMUM_PUBLIC_FILE_OFFSET : constant Clair.IO.File_Offset :=
    9_007_199_254_740_991;

  type Read_State is
    (Read_OK,
     Read_Path_Refused,
     Read_Not_Found,
     Read_Access_Denied,
     Read_Not_Regular_File,
     Read_File_Too_Large,
     Read_Offset_Out_Of_Range,
     Read_Revision_Mismatch,
     Read_File_Changed,
     Read_Timed_Out,
     Read_Failed,
     Read_Execution_Failed);

  type Revision is private;

  function image (value : Revision) return String;
  function is_empty (value : Revision) return Boolean;
  function is_valid_revision (value : String) return Boolean;
  function is_valid_path (path : String) return Boolean;
  function status_image (state : Read_State) return String;

  subtype Content_Buffer is System.Storage_Elements.Storage_Array
    (1 .. System.Storage_Elements.Storage_Offset (MAXIMUM_CONTENT_BYTES));

  type Read_Result is record
    state          : Read_State := Read_Execution_Failed;
    file_revision  : Revision;
    file_size      : Clair.IO.File_Offset := 0;
    offset         : Clair.IO.File_Offset := 0;
    next_offset    : Clair.IO.File_Offset := 0;
    eof            : Boolean := False;
    content        : Content_Buffer := [others => 0];
    content_length : Natural range 0 .. MAXIMUM_CONTENT_BYTES := 0;
  end record;

  --! summary Build the private same-image helper argument vector.
  --! contract:
  --!   workspace_root is one canonical absolute workspace root already
  --!   accepted by the workspace-token registry. path is one validated
  --!   relative read path. expected_revision is empty or canonical.
  --! outputs:
  --!   arguments is reset before validation and is valid only on OK.
  function build_helper_arguments
    (argument_zero          : String;
     workspace_root         : String;
     root_filesystem_id     : Interfaces.Unsigned_64;
     root_object_id         : Interfaces.Unsigned_64;
     path                   : String;
     offset            : Clair.IO.File_Offset;
     maximum_bytes     : Positive;
     expected_revision : String;
     arguments         : out Sonbal.Process_Arguments.Arguments)
  return Clair.Status.Code;

  --! summary Interpret one settled private helper process result.
  --! notes:
  --!   Malformed helper framing returns a non-OK status. Ordinary file-read
  --!   refusal and failure states are returned through result.state.
  function parse_helper_outcome
    (status             : Clair.Status.Code;
     outcome            : Clair.Process.Execution.Result;
     requested_offset   : Clair.IO.File_Offset;
     requested_maximum  : Positive;
     expected_revision  : String;
     result             : out Read_Result)
  return Clair.Status.Code;

  --! summary Run the private file-read helper protocol on standard output.
  --! notes:
  --!   This is an implementation entry point for the Sonbal executable, not a
  --!   public MCP or supported end-user CLI contract.
  function run_helper
    (workspace_root     : String;
     root_filesystem_id : String;
     root_object_id     : String;
     path               : String;
     offset_text       : String;
     maximum_text      : String;
     expected_revision : String)
  return Boolean;

private

  type Revision is record
    data   : String (1 .. MAXIMUM_REVISION_BYTES) :=
      [others => Character'val (0)];
    length : Natural range 0 .. MAXIMUM_REVISION_BYTES := 0;
  end record;

end Sonbal.File_Read;
