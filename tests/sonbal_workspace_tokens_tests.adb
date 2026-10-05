-- ============================================================================
-- sonbal_workspace_tokens_tests.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Ada.Directories;
with Ada.Real_Time;
with Clair.Status;
with Interfaces;
with Sonbal.Configuration;
with Sonbal.Workspace_Tokens;
with Sonbal.Workspace_Tokens.Tester;

package body Sonbal_Workspace_Tokens_Tests is

  use type Ada.Real_Time.Time;
  use type Clair.Status.Code;
  use type Interfaces.Unsigned_64;
  use type Sonbal.Workspace_Tokens.Rotation_State;
  use type Sonbal.Workspace_Tokens.Work_State;

  procedure check
    (reporter  : in out Clair.Test.Reporter.Context;
     condition : Boolean;
     name      : String)
  is
  begin
    if condition then
      Clair.Test.Reporter.record_assertion_pass (reporter, name);
      Clair.Test.Reporter.pass (reporter, name);
    else
      Clair.Test.Reporter.record_assertion_failure (reporter, name);
    end if;
  end check;

  function prepare_rotation
    (workspace_tokens     : in out Sonbal.Workspace_Tokens.Context;
     root         : String;
     operation_id : out String)
  return Clair.Status.Code
  is
    prepared : Sonbal.Workspace_Tokens.Rotation_Result;
    status   : Clair.Status.Code;
  begin
    operation_id := [others => Character'val (0)];
    status := Sonbal.Workspace_Tokens.rotate
      (workspace_tokens, root, "", prepared);
    if status /= Clair.Status.OK or else
       prepared.state /= Sonbal.Workspace_Tokens.Rotation_Prepared
    then
      return status;
    end if;

    declare
      value : constant String :=
        Sonbal.Workspace_Tokens.image (prepared.operation_id);
    begin
      operation_id(operation_id'first ..
                   operation_id'first + value'length - 1) := value;
    end;
    return Clair.Status.OK;
  end prepare_rotation;

  function commit_rotation
    (workspace_tokens     : in out Sonbal.Workspace_Tokens.Context;
     root         : String;
     operation_id : String;
     result       : out Sonbal.Workspace_Tokens.Rotation_Result)
  return Clair.Status.Code
  is
    last : Natural := operation_id'last;
  begin
    while last >= operation_id'first and then
          operation_id(last) = Character'val (0)
    loop
      exit when last = operation_id'first;
      last := last - 1;
    end loop;

    if operation_id(last) = Character'val (0) then
      return Clair.Status.INVALID_ARGUMENT;
    end if;

    return Sonbal.Workspace_Tokens.rotate
      (workspace_tokens, root, operation_id(operation_id'first .. last), result);
  end commit_rotation;

  procedure wait_for_rotation_cooldown is
    deadline : constant Ada.Real_Time.Time :=
      Ada.Real_Time.Clock +
      Ada.Real_Time.Milliseconds
        (Sonbal.Workspace_Tokens.ROTATE_WORKSPACE_TOKEN_COOLDOWN_MS + 50);
  begin
    delay until deadline;
  end wait_for_rotation_cooldown;

  procedure stale_work_is_fenced
    (reporter : in out Clair.Test.Reporter.Context)
  is
    workspace_tokens  : Sonbal.Workspace_Tokens.Context;
    root      : constant String := Ada.Directories.Current_Directory;
    first_op  : String
      (1 .. Sonbal.Workspace_Tokens.MAXIMUM_OPERATION_ID_BYTES);
    second_op : String
      (1 .. Sonbal.Workspace_Tokens.MAXIMUM_OPERATION_ID_BYTES);
    first     : Sonbal.Workspace_Tokens.Rotation_Result;
    replay    : Sonbal.Workspace_Tokens.Rotation_Result;
    blocked   : Sonbal.Workspace_Tokens.Rotation_Result;
    second    : Sonbal.Workspace_Tokens.Rotation_Result;
    old_work  : Sonbal.Workspace_Tokens.Work_Result;
    stale     : Sonbal.Workspace_Tokens.Work_Result;
    first_token  : String
      (1 .. Sonbal.Workspace_Tokens.MAXIMUM_WORKSPACE_TOKEN_BYTES);
    second_token : String
      (1 .. Sonbal.Workspace_Tokens.MAXIMUM_WORKSPACE_TOKEN_BYTES);
    first_length  : Natural := 0;
    second_length : Natural := 0;
    status : Clair.Status.Code;
  begin
    status := Sonbal.Workspace_Tokens.initialize
      (workspace_tokens, Sonbal.Configuration.Work_Slot_Count (2));
    check
      (reporter,
       status = Clair.Status.OK and then
         Sonbal.Workspace_Tokens.is_initialized (workspace_tokens),
       "workspace rotation registry initializes");
    if status /= Clair.Status.OK then
      return;
    end if;

    status := prepare_rotation (workspace_tokens, root, first_op);
    check
      (reporter,
       status = Clair.Status.OK,
       "first workspace rotation open prepares without mutation");

    status := commit_rotation (workspace_tokens, root, first_op, first);
    first_length := Sonbal.Workspace_Tokens.image (first.token)'length;
    if first_length /= 0 then
      first_token(1 .. first_length) :=
        Sonbal.Workspace_Tokens.image (first.token);
    end if;
    check
      (reporter,
       status = Clair.Status.OK and then
         first.state = Sonbal.Workspace_Tokens.Rotation_Rotated and then
         first_length = Sonbal.Workspace_Tokens.MAXIMUM_WORKSPACE_TOKEN_BYTES and then
         Sonbal.Workspace_Tokens.token_count (workspace_tokens) = 1,
       "first workspace rotation open publishes one opaque current rotation");

    status := commit_rotation (workspace_tokens, root, first_op, replay);
    check
      (reporter,
       status = Clair.Status.OK and then
         replay.state = Sonbal.Workspace_Tokens.Rotation_Rotated and then
         Sonbal.Workspace_Tokens.image (replay.token) =
           first_token(1 .. first_length),
       "lost open response replay returns the same workspace token");

    status := Sonbal.Workspace_Tokens.begin_process_work
      (workspace_tokens,
       first_token(1 .. first_length),
       root,
       old_work);
    check
      (reporter,
       status = Clair.Status.OK and then
         old_work.state = Sonbal.Workspace_Tokens.Work_Accepted and then
         Sonbal.Workspace_Tokens.active_work_count (workspace_tokens) = 1,
       "current workspace rotation admits one process work ticket");

    status := prepare_rotation (workspace_tokens, root, second_op);
    check
      (reporter,
       status = Clair.Status.OK,
       "second workspace rotation open prepares during cooldown");

    status := commit_rotation (workspace_tokens, root, second_op, blocked);
    check
      (reporter,
       status = Clair.Status.OK and then
         blocked.state = Sonbal.Workspace_Tokens.Rotation_Cooldown and then
         Sonbal.Workspace_Tokens.token_count (workspace_tokens) = 1,
       "one-second open cooldown rejects rapid generation churn");

    status := Sonbal.Workspace_Tokens.begin_process_work
      (workspace_tokens,
       first_token(1 .. first_length),
       root,
       stale);
    check
      (reporter,
       status = Clair.Status.OK and then
         stale.state = Sonbal.Workspace_Tokens.Work_Accepted,
       "cooldown refusal has no current-rotation side effect");
    if stale.state = Sonbal.Workspace_Tokens.Work_Accepted then
      status := Sonbal.Workspace_Tokens.end_work (workspace_tokens, stale.ticket);
      check
        (reporter,
         status = Clair.Status.OK,
         "cooldown-side-effect probe work ticket settles");
    end if;

    wait_for_rotation_cooldown;
    status := commit_rotation (workspace_tokens, root, second_op, second);
    second_length := Sonbal.Workspace_Tokens.image (second.token)'length;
    if second_length /= 0 then
      second_token(1 .. second_length) :=
        Sonbal.Workspace_Tokens.image (second.token);
    end if;
    check
      (reporter,
       status = Clair.Status.OK and then
         second.state = Sonbal.Workspace_Tokens.Rotation_Rotated and then
         second_length =
           Sonbal.Workspace_Tokens.MAXIMUM_WORKSPACE_TOKEN_BYTES and then
         second_token(1 .. second_length) /=
           first_token(1 .. first_length),
       "later open publishes a distinct newer workspace rotation");

    status := commit_rotation (workspace_tokens, root, first_op, replay);
    check
      (reporter,
       status = Clair.Status.OK and then
         replay.state = Sonbal.Workspace_Tokens.Rotation_Stale_Operation and then
         Sonbal.Workspace_Tokens.token_count (workspace_tokens) = 1,
       "replaying an older open operation cannot revive its generation");

    status := Sonbal.Workspace_Tokens.begin_process_work
      (workspace_tokens,
       first_token(1 .. first_length),
       root,
       stale);
    check
      (reporter,
       status = Clair.Status.OK and then
         stale.state = Sonbal.Workspace_Tokens.Work_Stale_Token,
       "old delayed process work is rejected before admission");


    status := Sonbal.Workspace_Tokens.end_work (workspace_tokens, old_work.ticket);
    check
      (reporter,
       status = Clair.Status.OK and then
         Sonbal.Workspace_Tokens.active_work_count (workspace_tokens) = 0,
       "already accepted old-token work settles after a newer rotation");

    status := Sonbal.Workspace_Tokens.begin_process_work
      (workspace_tokens,
       second_token(1 .. second_length),
       root,
       stale);
    check
      (reporter,
       status = Clair.Status.OK and then
         stale.state = Sonbal.Workspace_Tokens.Work_Accepted,
       "new workspace rotation admits work after old work settles");
    if stale.state = Sonbal.Workspace_Tokens.Work_Accepted then
      status := Sonbal.Workspace_Tokens.end_work (workspace_tokens, stale.ticket);
      check
        (reporter,
         status = Clair.Status.OK,
         "new-token work ticket settles");
    end if;


    status := Sonbal.Workspace_Tokens.finalize (workspace_tokens);
    check
      (reporter,
       status = Clair.Status.OK,
       "settled workspace rotation registry finalizes");
  end stale_work_is_fenced;

  procedure rotation_cooldown_is_preserved
    (reporter : in out Clair.Test.Reporter.Context)
  is
    workspace_tokens : Sonbal.Workspace_Tokens.Context;
    root     : constant String := Ada.Directories.Current_Directory;
    first_op : String
      (1 .. Sonbal.Workspace_Tokens.MAXIMUM_OPERATION_ID_BYTES);
    next_op : String
      (1 .. Sonbal.Workspace_Tokens.MAXIMUM_OPERATION_ID_BYTES);
    first   : Sonbal.Workspace_Tokens.Rotation_Result;
    blocked : Sonbal.Workspace_Tokens.Rotation_Result;
    next    : Sonbal.Workspace_Tokens.Rotation_Result;
    first_token : String
      (1 .. Sonbal.Workspace_Tokens.MAXIMUM_WORKSPACE_TOKEN_BYTES);
    first_length : Natural := 0;
    status : Clair.Status.Code;
  begin
    status := Sonbal.Workspace_Tokens.initialize
      (workspace_tokens, Sonbal.Configuration.Work_Slot_Count (1));
    if status /= Clair.Status.OK then
      check
        (reporter, False, "rotation/cooldown token registry initializes");
      return;
    end if;

    status := prepare_rotation (workspace_tokens, root, first_op);
    if status = Clair.Status.OK then
      status := commit_rotation (workspace_tokens, root, first_op, first);
    end if;
    first_length := Sonbal.Workspace_Tokens.image (first.token)'length;
    if first_length /= 0 then
      first_token(1 .. first_length) :=
        Sonbal.Workspace_Tokens.image (first.token);
    end if;
    check
      (reporter,
       status = Clair.Status.OK and then
         first.state = Sonbal.Workspace_Tokens.Rotation_Rotated,
       "rotation/cooldown fixture publishes first token");


    status := prepare_rotation (workspace_tokens, root, next_op);
    if status = Clair.Status.OK then
      status := commit_rotation (workspace_tokens, root, next_op, blocked);
    end if;
    check
      (reporter,
       status = Clair.Status.OK and then
         blocked.state = Sonbal.Workspace_Tokens.Rotation_Cooldown and then
         Sonbal.Workspace_Tokens.token_count (workspace_tokens) = 1,
       "current workspace token remains published during rotation cooldown");

    wait_for_rotation_cooldown;
    status := commit_rotation (workspace_tokens, root, next_op, next);
    check
      (reporter,
       status = Clair.Status.OK and then
         next.state = Sonbal.Workspace_Tokens.Rotation_Rotated and then
         Sonbal.Workspace_Tokens.image (next.token) /=
           first_token(1 .. first_length),
       "reopen after cooldown receives a fresh workspace rotation");


    status := Sonbal.Workspace_Tokens.finalize (workspace_tokens);
    check
      (reporter,
       status = Clair.Status.OK,
       "rotation/cooldown workspace token registry finalizes");
  end rotation_cooldown_is_preserved;

  procedure idle_slot_reuse_fences_evicted_token
    (reporter : in out Clair.Test.Reporter.Context)
  is
    workspace_tokens : Sonbal.Workspace_Tokens.Context;
    base : constant String :=
      Ada.Directories.Full_Name ("build/tmp") & "/sonbal-token-slot-reuse";
    first_root  : constant String := base & "/first";
    second_root : constant String := base & "/second";
    first_op  : String (1 .. Sonbal.Workspace_Tokens.MAXIMUM_OPERATION_ID_BYTES);
    second_op : String (1 .. Sonbal.Workspace_Tokens.MAXIMUM_OPERATION_ID_BYTES);
    first   : Sonbal.Workspace_Tokens.Rotation_Result;
    blocked : Sonbal.Workspace_Tokens.Rotation_Result;
    second  : Sonbal.Workspace_Tokens.Rotation_Result;
    stale   : Sonbal.Workspace_Tokens.Work_Result;
    first_token : String (1 .. Sonbal.Workspace_Tokens.MAXIMUM_WORKSPACE_TOKEN_BYTES);
    first_length : Natural := 0;
    status : Clair.Status.Code;

    procedure cleanup is
    begin
      if Ada.Directories.Exists (base) then
        Ada.Directories.Delete_Tree (base);
      end if;
    exception
      when others => null;
    end cleanup;
  begin
    Ada.Directories.Create_Path ("build/tmp");
    cleanup;
    Ada.Directories.Create_Path (first_root);
    Ada.Directories.Create_Path (second_root);

    status := Sonbal.Workspace_Tokens.initialize
      (workspace_tokens, Sonbal.Configuration.Work_Slot_Count (1));
    check (reporter, status = Clair.Status.OK,
           "single-slot workspace token registry initializes");
    if status /= Clair.Status.OK then
      cleanup;
      return;
    end if;

    status := prepare_rotation (workspace_tokens, first_root, first_op);
    if status = Clair.Status.OK then
      status := commit_rotation (workspace_tokens, first_root, first_op, first);
    end if;
    first_length := Sonbal.Workspace_Tokens.image (first.token)'length;
    if first_length /= 0 then
      first_token (1 .. first_length) := Sonbal.Workspace_Tokens.image (first.token);
    end if;
    check
      (reporter,
       status = Clair.Status.OK and then
         first.state = Sonbal.Workspace_Tokens.Rotation_Rotated and then
         Sonbal.Workspace_Tokens.token_count (workspace_tokens) = 1,
       "first root publishes the only token slot");

    status := prepare_rotation (workspace_tokens, second_root, second_op);
    if status = Clair.Status.OK then
      status := commit_rotation (workspace_tokens, second_root, second_op, blocked);
    end if;
    check
      (reporter,
       status = Clair.Status.OK and then
         blocked.state = Sonbal.Workspace_Tokens.Rotation_Capacity_Exceeded and then
         Sonbal.Workspace_Tokens.token_count (workspace_tokens) = 1,
       "idle token slot is not reused before its cooldown expires");

    wait_for_rotation_cooldown;
    status := commit_rotation (workspace_tokens, second_root, second_op, second);
    check
      (reporter,
       status = Clair.Status.OK and then
         second.state = Sonbal.Workspace_Tokens.Rotation_Rotated and then
         Sonbal.Workspace_Tokens.token_count (workspace_tokens) = 1,
       "oldest idle token slot is reused after cooldown");

    status := Sonbal.Workspace_Tokens.begin_process_work
      (workspace_tokens, first_token (1 .. first_length), first_root, stale);
    check
      (reporter,
       status = Clair.Status.OK and then
         stale.state = Sonbal.Workspace_Tokens.Work_Stale_Token,
       "slot reuse permanently fences the evicted workspace token");

    status := Sonbal.Workspace_Tokens.finalize (workspace_tokens);
    check (reporter, status = Clair.Status.OK,
           "single-slot workspace token registry finalizes");
    cleanup;
  end idle_slot_reuse_fences_evicted_token;

  procedure server_restart_invalidates_old_token
    (reporter : in out Clair.Test.Reporter.Context)
  is
    workspace_tokens : Sonbal.Workspace_Tokens.Context;
    root     : constant String := Ada.Directories.Current_Directory;
    rotation_op  : String
      (1 .. Sonbal.Workspace_Tokens.MAXIMUM_OPERATION_ID_BYTES);
    rotation   : Sonbal.Workspace_Tokens.Rotation_Result;
    work     : Sonbal.Workspace_Tokens.Work_Result;
    old_token : String
      (1 .. Sonbal.Workspace_Tokens.MAXIMUM_WORKSPACE_TOKEN_BYTES);
    old_length : Natural := 0;
    status : Clair.Status.Code;
  begin
    status := Sonbal.Workspace_Tokens.initialize
      (workspace_tokens, Sonbal.Configuration.Work_Slot_Count (1));
    if status = Clair.Status.OK then
      status := prepare_rotation (workspace_tokens, root, rotation_op);
    end if;
    if status = Clair.Status.OK then
      status := commit_rotation (workspace_tokens, root, rotation_op, rotation);
    end if;
    old_length := Sonbal.Workspace_Tokens.image (rotation.token)'length;
    if old_length /= 0 then
      old_token(1 .. old_length) :=
        Sonbal.Workspace_Tokens.image (rotation.token);
    end if;
    check
      (reporter,
       status = Clair.Status.OK and then
         rotation.state = Sonbal.Workspace_Tokens.Rotation_Rotated,
       "restart fixture creates one rotation");

    status := Sonbal.Workspace_Tokens.finalize (workspace_tokens);
    check
      (reporter,
       status = Clair.Status.OK,
       "restart fixture finalizes first registry lifetime");

    status := Sonbal.Workspace_Tokens.initialize
      (workspace_tokens, Sonbal.Configuration.Work_Slot_Count (1));
    check
      (reporter,
       status = Clair.Status.OK,
       "restart fixture initializes replacement registry lifetime");

    status := Sonbal.Workspace_Tokens.begin_process_work
      (workspace_tokens, old_token(1 .. old_length), root, work);
    check
      (reporter,
       status = Clair.Status.OK and then
         work.state = Sonbal.Workspace_Tokens.Work_Stale_Token,
       "prior server-lifetime workspace rotation is stale");

    status := Sonbal.Workspace_Tokens.finalize (workspace_tokens);
    check
      (reporter,
       status = Clair.Status.OK,
       "replacement workspace rotation registry finalizes");
  end server_restart_invalidates_old_token;

  procedure thousand_generation_changes_remain_bounded
    (reporter : in out Clair.Test.Reporter.Context)
  is
    WORKSPACE_COUNT : constant Positive := 64;
    ROUND_COUNT     : constant Positive := 16;
    TOTAL_OPENS     : constant Positive := WORKSPACE_COUNT * ROUND_COUNT;

    subtype Workspace_Index is Positive range 1 .. WORKSPACE_COUNT;
    type Token_Buffer_Array is array (Workspace_Index) of
      String (1 .. Sonbal.Workspace_Tokens.MAXIMUM_WORKSPACE_TOKEN_BYTES);
    type Token_Length_Array is array (Workspace_Index) of
      Natural range 0 .. Sonbal.Workspace_Tokens.MAXIMUM_WORKSPACE_TOKEN_BYTES;

    workspace_tokens : Sonbal.Workspace_Tokens.Context;
    previous : Token_Buffer_Array :=
      [others => [others => Character'val (0)]];
    lengths  : Token_Length_Array := [others => 0];
    oldest_token : String
      (1 .. Sonbal.Workspace_Tokens.MAXIMUM_WORKSPACE_TOKEN_BYTES) :=
        [others => Character'val (0)];
    oldest_token_length : Natural := 0;
    oldest_operation : String
      (1 .. Sonbal.Workspace_Tokens.MAXIMUM_OPERATION_ID_BYTES) :=
        [others => Character'val (0)];
    base : constant String :=
      Ada.Directories.Full_Name ("build/tmp") &
      "/sonbal-rotation-generation-stress";
    status : Clair.Status.Code;
    valid  : Boolean := True;

    function two_digit (value : Workspace_Index) return String is
      tens : constant Natural := Natural (value) / 10;
      ones : constant Natural := Natural (value) mod 10;
    begin
      return
        String'
          (1 => Character'val (Character'pos ('0') + tens),
           2 => Character'val (Character'pos ('0') + ones));
    end two_digit;

    function root_for (value : Workspace_Index) return String is
      (base & "/" & two_digit (value));

    procedure cleanup is
    begin
      if Ada.Directories.Exists (base) then
        Ada.Directories.Delete_Tree (base);
      end if;
    exception
      when others =>
        null;
    end cleanup;
  begin
    Ada.Directories.Create_Path ("build/tmp");
    cleanup;
    Ada.Directories.Create_Path (base);
    for index in Workspace_Index loop
      Ada.Directories.Create_Path (root_for (index));
    end loop;

    status := Sonbal.Workspace_Tokens.initialize
      (workspace_tokens, Sonbal.Configuration.Work_Slot_Count (WORKSPACE_COUNT));
    check
      (reporter,
       status = Clair.Status.OK,
       "generation stress registry initializes at maximum bounded capacity");
    if status /= Clair.Status.OK then
      cleanup;
      return;
    end if;

    rounds :
    for round in 1 .. ROUND_COUNT loop
      if round > 1 then
        wait_for_rotation_cooldown;
      end if;

      for index in Workspace_Index loop
        declare
          operation_id : String
            (1 .. Sonbal.Workspace_Tokens.MAXIMUM_OPERATION_ID_BYTES);
          rotation : Sonbal.Workspace_Tokens.Rotation_Result;
          token_length : Natural := 0;
        begin
          status := prepare_rotation
            (workspace_tokens, root_for (index), operation_id);
          if status = Clair.Status.OK then
            status := commit_rotation
              (workspace_tokens, root_for (index), operation_id, rotation);
          end if;

          token_length :=
            Sonbal.Workspace_Tokens.image (rotation.token)'length;
          valid := valid and then
            status = Clair.Status.OK and then
            rotation.state = Sonbal.Workspace_Tokens.Rotation_Rotated and then
            token_length =
              Sonbal.Workspace_Tokens.MAXIMUM_WORKSPACE_TOKEN_BYTES;

          if valid and then round > 1 then
            valid := Sonbal.Workspace_Tokens.image (rotation.token) /=
              previous(index)(1 .. lengths(index));
          end if;

          if valid and then round = 1 and then
             index = Workspace_Index'first
          then
            oldest_token_length := token_length;
            oldest_token(1 .. token_length) :=
              Sonbal.Workspace_Tokens.image (rotation.token);
            oldest_operation := operation_id;
          end if;

          if valid then
            previous(index) := [others => Character'val (0)];
            previous(index)(1 .. token_length) :=
              Sonbal.Workspace_Tokens.image (rotation.token);
            lengths(index) := token_length;
          end if;
        end;
        exit rounds when not valid;
      end loop;

      valid := valid and then
        Sonbal.Workspace_Tokens.token_count (workspace_tokens) =
          WORKSPACE_COUNT and then
        Sonbal.Workspace_Tokens.Tester.next_generation (workspace_tokens) =
          Interfaces.Unsigned_64
            (1 + round * WORKSPACE_COUNT) and then
        Sonbal.Workspace_Tokens.Tester.retained_token_slot_count
          (workspace_tokens) = WORKSPACE_COUNT and then
        Sonbal.Workspace_Tokens.Tester.retained_rotation_operation_count
          (workspace_tokens) <= WORKSPACE_COUNT;
      exit rounds when not valid;

      if round = ROUND_COUNT then
        declare
          stale_work : Sonbal.Workspace_Tokens.Work_Result;
          stale_replay : Sonbal.Workspace_Tokens.Rotation_Result;
        begin
          status := Sonbal.Workspace_Tokens.begin_process_work
            (workspace_tokens,
             oldest_token(1 .. oldest_token_length),
             root_for (Workspace_Index'first),
             stale_work);
          valid := valid and then
            status = Clair.Status.OK and then
            stale_work.state =
              Sonbal.Workspace_Tokens.Work_Stale_Token;


          status := commit_rotation
            (workspace_tokens,
             root_for (Workspace_Index'first),
             oldest_operation,
             stale_replay);
          valid := valid and then
            status = Clair.Status.OK and then
            stale_replay.state =
              Sonbal.Workspace_Tokens.Rotation_Stale_Operation;
        end;
      end if;
      exit rounds when not valid;

      valid := valid and then
        Sonbal.Workspace_Tokens.token_count (workspace_tokens) = WORKSPACE_COUNT;
      exit rounds when not valid;
    end loop rounds;

    check
      (reporter,
       valid and then
         Sonbal.Workspace_Tokens.Tester.next_generation (workspace_tokens) =
           Interfaces.Unsigned_64 (TOTAL_OPENS + 1) and then
         Sonbal.Workspace_Tokens.Tester.retained_token_slot_count
           (workspace_tokens) = WORKSPACE_COUNT and then
         Sonbal.Workspace_Tokens.Tester.retained_rotation_operation_count
           (workspace_tokens) <= WORKSPACE_COUNT,
       "1,024 generation changes remain monotonic, stale-safe, and bounded");

    status := Sonbal.Workspace_Tokens.finalize (workspace_tokens);
    check
      (reporter,
       status = Clair.Status.OK,
       "generation stress registry finalizes after bounded churn");
    cleanup;
  end thousand_generation_changes_remain_bounded;

  procedure current_work_returns_workspace_root_without_cwd
    (reporter : in out Clair.Test.Reporter.Context)
  is
    workspace_tokens : Sonbal.Workspace_Tokens.Context;
    root : constant String := Ada.Directories.Current_Directory;
    operation_id : String
      (1 .. Sonbal.Workspace_Tokens.MAXIMUM_OPERATION_ID_BYTES);
    rotation : Sonbal.Workspace_Tokens.Rotation_Result;
    work : Sonbal.Workspace_Tokens.Work_Result;
    stale : Sonbal.Workspace_Tokens.Work_Result;
    token : String
      (1 .. Sonbal.Workspace_Tokens.MAXIMUM_WORKSPACE_TOKEN_BYTES);
    token_length : Natural := 0;
    status : Clair.Status.Code;
  begin
    status := Sonbal.Workspace_Tokens.initialize
      (workspace_tokens, Sonbal.Configuration.Work_Slot_Count (1));
    check
      (reporter,
       status = Clair.Status.OK,
       "token-only work registry initializes");
    if status /= Clair.Status.OK then
      return;
    end if;

    status := prepare_rotation (workspace_tokens, root, operation_id);
    if status = Clair.Status.OK then
      status := commit_rotation
        (workspace_tokens, root, operation_id, rotation);
    end if;
    token_length := Sonbal.Workspace_Tokens.image (rotation.token)'length;
    if token_length /= 0 then
      token(1 .. token_length) :=
        Sonbal.Workspace_Tokens.image (rotation.token);
    end if;

    check
      (reporter,
       status = Clair.Status.OK and then
         rotation.state = Sonbal.Workspace_Tokens.Rotation_Rotated,
       "token-only work fixture publishes one current token");

    status := Sonbal.Workspace_Tokens.begin_current_work
      (workspace_tokens,
       token(1 .. token_length),
       work);
    check
      (reporter,
       status = Clair.Status.OK and then
         work.state = Sonbal.Workspace_Tokens.Work_Accepted and then
         Sonbal.Workspace_Tokens.image (work.workspace_root) = root and then
         Sonbal.Workspace_Tokens.image (work.working_directory) = "" and then
         Sonbal.Workspace_Tokens.active_work_count (workspace_tokens) = 1,
       "token-only work returns root without resolving a working directory");

    status := Sonbal.Workspace_Tokens.end_work
      (workspace_tokens, work.ticket);
    check
      (reporter,
       status = Clair.Status.OK and then
         Sonbal.Workspace_Tokens.active_work_count (workspace_tokens) = 0,
       "token-only work ticket releases exactly once");

    status := Sonbal.Workspace_Tokens.begin_current_work
      (workspace_tokens,
       "w-stale",
       stale);
    check
      (reporter,
       status = Clair.Status.OK and then
         stale.state = Sonbal.Workspace_Tokens.Work_Stale_Token and then
         Sonbal.Workspace_Tokens.active_work_count (workspace_tokens) = 0,
       "token-only stale admission creates no work ticket");

    Sonbal.Workspace_Tokens.stop (workspace_tokens);
    status := Sonbal.Workspace_Tokens.finalize (workspace_tokens);
    check
      (reporter,
       status = Clair.Status.OK,
       "token-only work registry finalizes after settlement");
  end current_work_returns_workspace_root_without_cwd;

  procedure run (reporter : in out Clair.Test.Reporter.Context) is
  begin
    Clair.Test.Reporter.run_scenario
      (reporter,
       "current work returns workspace root without cwd",
       current_work_returns_workspace_root_without_cwd'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "stale work is fenced by token rotation",
       stale_work_is_fenced'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "workspace token rotation preserves cooldown",
       rotation_cooldown_is_preserved'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "idle token slot reuse fences evicted token",
       idle_slot_reuse_fences_evicted_token'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "server restart invalidates old workspace token",
       server_restart_invalidates_old_token'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "thousand generation changes remain bounded",
       thousand_generation_changes_remain_bounded'access);
  end run;

end Sonbal_Workspace_Tokens_Tests;
