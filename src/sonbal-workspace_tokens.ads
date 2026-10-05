-- ============================================================================
-- sonbal-workspace_tokens.ads
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Ada.Real_Time;
with Clair.Status;
with Interfaces;
with Sonbal.Configuration;

package Sonbal.Workspace_Tokens is

  MAXIMUM_WORKSPACE_PATH_BYTES       : constant Positive := 4_096;
  MAXIMUM_WORKSPACE_TOKEN_BYTES      : constant Positive := 66;
  MAXIMUM_OPERATION_ID_BYTES         : constant Positive := 50;
  ROTATE_WORKSPACE_TOKEN_COOLDOWN_MS : constant Positive := 1_000;

  type Workspace_Token is private;
  type Rotation_Operation_Id is private;
  type Canonical_Working_Directory is private;
  type Work_Ticket is private;

  function image (value : Workspace_Token) return String;
  function image (value : Rotation_Operation_Id) return String;
  function image (value : Canonical_Working_Directory) return String;
  function is_valid (value : Work_Ticket) return Boolean;

  type Rotation_State is
    (Rotation_Prepared,
     Rotation_Rotated,
     Rotation_Cooldown,
     Rotation_Capacity_Exceeded,
     Rotation_Stale_Operation);

  type Rotation_Result is record
    state        : Rotation_State := Rotation_Capacity_Exceeded;
    token        : Workspace_Token;
    operation_id : Rotation_Operation_Id;
  end record;

  type Work_State is
    (Work_Accepted,
     Work_Stale_Token,
     Work_Outside_Workspace,
     Work_Capacity_Exceeded);

  type Workspace_Root_Identity is record
    filesystem_id : Interfaces.Unsigned_64 := 0;
    object_id     : Interfaces.Unsigned_64 := 0;
  end record;

  type Work_Result is record
    state              : Work_State := Work_Stale_Token;
    ticket             : Work_Ticket;
    workspace_root     : Canonical_Working_Directory;
    workspace_identity : Workspace_Root_Identity;
    working_directory  : Canonical_Working_Directory;
  end record;

  type Context is limited private;
  type Context_Access is access all Context;

  --! summary Initialize one bounded owner-thread workspace-token registry.
  --! contract:
  --!   All operations on one context are serialized by the caller's owner
  --!   thread. At most `limit` workspace-token slots, `limit` rotation-operation
  --!   records, and `limit` active work tickets are retained. No filesystem
  --!   lock, lease, takeover, recovery state, or hidden work queue is created.
  function initialize
    (self  : in out Context;
     limit : Sonbal.Configuration.Work_Slot_Count)
  return Clair.Status.Code;

  --! summary Prepare, commit, or replay one workspace-token rotation.
  --! contract:
  --!   `root` must identify an existing absolute directory. With an empty
  --!   `operation_id`, the call prepares one bounded server-minted operation
  --!   without changing the current token. Supplying that operation commits
  --!   the rotation when the fixed one-second cooldown permits it. A successful
  --!   commit allocates one new generation and immediately makes every older
  --!   workspace token for the same normalized root stale. Replaying the committed
  --!   operation returns the same current token and never increments the
  --!   generation again. Cooldown and capacity refusal have no generation or
  --!   token side effect. When all token slots are occupied, an idle slot whose
  --!   cooldown has expired may be reused; its former token then becomes stale.
  function rotate
    (self         : in out Context;
     root         : String;
     operation_id : String;
     result       : out Rotation_Result)
  return Clair.Status.Code;

  --! summary Register one generic work item under a current token.
  --! contract:
  --!   Token freshness and bounded work capacity are checked without filesystem
  --!   lookup. Accepted work owns one ticket and returns the canonical workspace
  --!   root captured by token rotation. The ticket must be ended exactly once.
  --!   A later token rotation does not cancel already accepted work.
  function begin_current_work
    (self   : in out Context;
     token  : String;
     result : out Work_Result)
  return Clair.Status.Code;

  --! summary Register one process-creating work item under a current token.
  --! contract:
  --!   The token is checked before process admission. `cwd` must resolve to an
  --!   existing directory at or below the token's workspace root. Accepted work
  --!   owns one ticket and returns both the canonical workspace root and working
  --!   directory. The ticket must be ended exactly once.
  function begin_process_work
    (self   : in out Context;
     token  : String;
     cwd    : String;
     result : out Work_Result)
  return Clair.Status.Code;

  --! summary End exactly one previously accepted workspace work ticket.
  function end_work
    (self   : in out Context;
     ticket : in out Work_Ticket)
  return Clair.Status.Code;

  --! summary Stop new token rotations and new work for this registry lifetime.
  procedure stop (self : in out Context);

  --! summary Finalize one registry after every accepted work ticket settles.
  function finalize (self : in out Context) return Clair.Status.Code;

  function active_work_count (self : Context) return Natural;
  function token_count (self : Context) return Natural;
  function is_initialized (self : Context) return Boolean;

private
  subtype Workspace_Path is String (1 .. MAXIMUM_WORKSPACE_PATH_BYTES);

  type Workspace_Token is record
    data   : String (1 .. MAXIMUM_WORKSPACE_TOKEN_BYTES) :=
      [others => Character'val (0)];
    length : Natural range 0 .. MAXIMUM_WORKSPACE_TOKEN_BYTES := 0;
  end record;

  type Rotation_Operation_Id is record
    data   : String (1 .. MAXIMUM_OPERATION_ID_BYTES) :=
      [others => Character'val (0)];
    length : Natural range 0 .. MAXIMUM_OPERATION_ID_BYTES := 0;
  end record;

  type Canonical_Working_Directory is record
    data   : Workspace_Path := [others => Character'val (0)];
    length : Natural range 0 .. MAXIMUM_WORKSPACE_PATH_BYTES := 0;
  end record;

  type Work_Ticket is record
    index      : Natural range
      0 .. Sonbal.Configuration.ABSOLUTE_MAX_WORK_SLOTS := 0;
    generation : Interfaces.Unsigned_64 := 0;
    serial     : Interfaces.Unsigned_64 := 0;
  end record;

  type Token_Slot is record
    root                : Workspace_Path := [others => Character'val (0)];
    root_length         : Natural range 0 .. MAXIMUM_WORKSPACE_PATH_BYTES := 0;
    root_identity       : Workspace_Root_Identity;
    generation          : Interfaces.Unsigned_64 := 0;
    token               : Workspace_Token;
    has_current         : Boolean := False;
    has_last_rotation   : Boolean := False;
    last_rotation       : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
    active_work_count   : Natural range
      0 .. Sonbal.Configuration.ABSOLUTE_MAX_WORK_SLOTS := 0;
  end record;

  type Token_Slot_Array is array (Positive range <>) of Token_Slot;
  type Token_Slot_Array_Access is access Token_Slot_Array;

  type Rotation_Operation_State is
    (Operation_Empty,
     Operation_Prepared,
     Operation_Rotated);

  type Rotation_Operation_Record is record
    state               : Rotation_Operation_State := Operation_Empty;
    operation_id        : Rotation_Operation_Id;
    request_root        : Workspace_Path := [others => Character'val (0)];
    request_root_length : Natural range 0 .. MAXIMUM_WORKSPACE_PATH_BYTES := 0;
    root                : Canonical_Working_Directory;
    serial              : Interfaces.Unsigned_64 := 0;
    rotation_generation : Interfaces.Unsigned_64 := 0;
  end record;

  type Rotation_Operation_Array is
    array (Positive range <>) of Rotation_Operation_Record;
  type Rotation_Operation_Array_Access is access Rotation_Operation_Array;

  type Work_Record is record
    active      : Boolean := False;
    token_index : Natural range
      0 .. Sonbal.Configuration.ABSOLUTE_MAX_WORK_SLOTS := 0;
    generation  : Interfaces.Unsigned_64 := 0;
    serial      : Interfaces.Unsigned_64 := 0;
  end record;

  type Work_Record_Array is array (Positive range <>) of Work_Record;
  type Work_Record_Array_Access is access Work_Record_Array;

  type Context is limited record
    tokens                : Token_Slot_Array_Access := null;
    rotation_operations   : Rotation_Operation_Array_Access := null;
    work_records          : Work_Record_Array_Access := null;
    capacity              : Natural range
      0 .. Sonbal.Configuration.ABSOLUTE_MAX_WORK_SLOTS := 0;
    next_generation       : Interfaces.Unsigned_64 := 1;
    next_operation_serial : Interfaces.Unsigned_64 := 1;
    next_work_serial      : Interfaces.Unsigned_64 := 1;
    instance_prefix       : String (1 .. 32) := [others => Character'val (0)];
    initialized           : Boolean := False;
    stopping              : Boolean := False;
  end record;

end Sonbal.Workspace_Tokens;
