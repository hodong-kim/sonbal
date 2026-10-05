-- ============================================================================
-- sonbal-workspace_tokens.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Ada.Directories;
with Ada.Unchecked_Deallocation;
with Clair.Random;
with Clair.Unix.File;
with System.Storage_Elements;

package body Sonbal.Workspace_Tokens is

  use type Ada.Directories.File_Kind;
  use type Ada.Real_Time.Time;
  use type Ada.Real_Time.Time_Span;
  use type Clair.Status.Code;
  use type Clair.Unix.File.Entry_Kind;
  use type Interfaces.Unsigned_64;

  INSTANCE_RANDOM_BYTES  : constant Positive := 16;
  TOKEN_RANDOM_BYTES   : constant Positive := 8;
  OPERATION_RANDOM_BYTES : constant Positive := 16;
  HEX_DIGITS             : constant String := "0123456789abcdef";
  ROTATION_COOLDOWN_DURATION : constant Ada.Real_Time.Time_Span :=
    Ada.Real_Time.Milliseconds (ROTATE_WORKSPACE_TOKEN_COOLDOWN_MS);

  procedure free_tokens is new Ada.Unchecked_Deallocation
    (Token_Slot_Array, Token_Slot_Array_Access);
  procedure free_rotation_operations is new Ada.Unchecked_Deallocation
    (Rotation_Operation_Array, Rotation_Operation_Array_Access);
  procedure free_work_records is new Ada.Unchecked_Deallocation
    (Work_Record_Array, Work_Record_Array_Access);

  function image (value : Workspace_Token) return String is
  begin
    if value.length = 0 then
      return "";
    end if;
    return value.data(1 .. value.length);
  end image;

  function image (value : Rotation_Operation_Id) return String is
  begin
    if value.length = 0 then
      return "";
    end if;
    return value.data(1 .. value.length);
  end image;

  function image (value : Canonical_Working_Directory) return String is
  begin
    if value.length = 0 then
      return "";
    end if;
    return value.data(1 .. value.length);
  end image;

  function is_valid (value : Work_Ticket) return Boolean is
    (value.index /= 0 and then
     value.generation /= 0 and then
     value.serial /= 0);

  function contains_nul (value : String) return Boolean is
  begin
    for item of value loop
      if item = Character'val (0) then
        return True;
      end if;
    end loop;
    return False;
  end contains_nul;

  function token_matches
    (stored : String;
     length : Natural;
     value  : String)
  return Boolean
  is
    matches : Boolean := True;
  begin
    if length = 0 or else value'length /= length then
      return False;
    end if;

    for index in 1 .. length loop
      matches := matches and
        stored(index) = value(value'first + index - 1);
    end loop;
    return matches;
  end token_matches;

  procedure wipe (value : in out Workspace_Token) is
  begin
    value.data := [others => Character'val (0)];
    value.length := 0;
  end wipe;

  procedure clear_token (item : in out Token_Slot) is
  begin
    item := (others => <>);
  end clear_token;

  procedure clear_rotation_operation
    (item : in out Rotation_Operation_Record) is
  begin
    item := (others => <>);
  end clear_rotation_operation;

  procedure clear_work_record (item : in out Work_Record) is
  begin
    item := (others => <>);
  end clear_work_record;

  function canonicalize_directory
    (path   : String;
     result : out Canonical_Working_Directory)
  return Clair.Status.Code
  is
  begin
    result := (others => <>);
    if path'length not in 1 .. MAXIMUM_WORKSPACE_PATH_BYTES or else
       path(path'first) /= '/' or else contains_nul (path)
    then
      return Clair.Status.INVALID_ARGUMENT;
    end if;

    begin
      declare
        full_name : constant String := Ada.Directories.Full_Name (path);
      begin
        if full_name'length not in 1 .. MAXIMUM_WORKSPACE_PATH_BYTES or else
           full_name(full_name'first) /= '/' or else contains_nul (full_name)
        then
          return Clair.Status.RANGE_ERROR;
        elsif Ada.Directories.Kind (full_name) /= Ada.Directories.Directory then
          return Clair.Status.INVALID_ARGUMENT;
        end if;

        result.data(1 .. full_name'length) := full_name;
        result.length := full_name'length;
        return Clair.Status.OK;
      end;
    exception
      when Ada.Directories.Name_Error | Ada.Directories.Use_Error =>
        return Clair.Status.INVALID_ARGUMENT;
      when Storage_Error =>
        return Clair.Status.OUT_OF_MEMORY;
      when others =>
        return Clair.Status.INTERNAL_ERROR;
    end;
  end canonicalize_directory;

  function query_root_identity
    (root     : Canonical_Working_Directory;
     identity : out Workspace_Root_Identity)
  return Clair.Status.Code
  is
    metadata : Clair.Unix.File.Metadata;
    status   : Clair.Status.Code;
  begin
    identity := (others => <>);
    if root.length = 0 then
      return Clair.Status.INVALID_ARGUMENT;
    end if;

    status := Clair.Unix.File.query_metadata
      (path          => image (root),
       link_policy   => Clair.Unix.File.Do_Not_Follow_Symbolic_Links,
       file_metadata => metadata);
    if status /= Clair.Status.OK then
      return status;
    elsif metadata.kind /= Clair.Unix.File.Directory then
      return Clair.Status.INVALID_ARGUMENT;
    end if;

    identity.filesystem_id := Interfaces.Unsigned_64(metadata.filesystem_id);
    identity.object_id := Interfaces.Unsigned_64(metadata.object_id);
    return Clair.Status.OK;
  end query_root_identity;

  function same_root
    (left  : Canonical_Working_Directory;
     right : Canonical_Working_Directory)
  return Boolean
  is
  begin
    return left.length /= 0 and then
      left.length = right.length and then
      left.data(1 .. left.length) = right.data(1 .. right.length);
  end same_root;

  function slot_root
    (slot : Token_Slot) return Canonical_Working_Directory
  is
    result : Canonical_Working_Directory;
  begin
    if slot.root_length /= 0 then
      result.data := slot.root;
      result.length := slot.root_length;
    end if;
    return result;
  end slot_root;

  function path_is_within
    (root  : Token_Slot;
     child : Canonical_Working_Directory)
  return Boolean
  is
  begin
    if root.root_length = 0 or else child.length = 0 then
      return False;
    end if;

    declare
      root_text  : constant String := root.root(1 .. root.root_length);
      child_text : constant String := image (child);
    begin
      if root_text = "/" then
        return child_text(child_text'first) = '/';
      elsif child_text = root_text then
        return True;
      elsif child_text'length <= root_text'length then
        return False;
      end if;

      return
        child_text
          (child_text'first .. child_text'first + root_text'length - 1) =
        root_text and then
        child_text(child_text'first + root_text'length) = '/';
    end;
  end path_is_within;

  function cooldown_active
    (slot : Token_Slot;
     now  : Ada.Real_Time.Time)
  return Boolean
  is
  begin
    return slot.has_last_rotation and then
      now - slot.last_rotation < ROTATION_COOLDOWN_DURATION;
  end cooldown_active;

  function find_token_by_root
    (self : Context;
     root : Canonical_Working_Directory)
  return Natural
  is
  begin
    if self.tokens = null then
      return 0;
    end if;

    for index in 1 .. self.capacity loop
      if self.tokens(index).root_length /= 0 and then
         same_root (slot_root (self.tokens(index)), root)
      then
        return index;
      end if;
    end loop;
    return 0;
  end find_token_by_root;

  function find_token_by_generation
    (self       : Context;
     generation : Interfaces.Unsigned_64)
  return Natural
  is
  begin
    if self.tokens = null or else generation = 0 then
      return 0;
    end if;

    for index in 1 .. self.capacity loop
      if self.tokens(index).root_length /= 0 and then
         self.tokens(index).has_current and then
         self.tokens(index).generation = generation
      then
        return index;
      end if;
    end loop;
    return 0;
  end find_token_by_generation;

  function find_token_by_value
    (self  : Context;
     value : String)
  return Natural
  is
  begin
    if self.tokens = null then
      return 0;
    end if;

    for index in 1 .. self.capacity loop
      if self.tokens(index).has_current and then
         token_matches
           (self.tokens(index).token.data,
            self.tokens(index).token.length,
            value)
      then
        return index;
      end if;
    end loop;
    return 0;
  end find_token_by_value;

  function find_available_token_slot
    (self : Context;
     now  : Ada.Real_Time.Time)
  return Natural
  is
    oldest_index      : Natural := 0;
    oldest_generation : Interfaces.Unsigned_64 := 0;
  begin
    if self.tokens = null then
      return 0;
    end if;

    for index in 1 .. self.capacity loop
      if self.tokens(index).root_length = 0 then
        return index;
      end if;
    end loop;

    for index in 1 .. self.capacity loop
      if self.tokens(index).active_work_count = 0 and then
         not cooldown_active (self.tokens(index), now) and then
         (oldest_index = 0 or else
          self.tokens(index).generation < oldest_generation)
      then
        oldest_index := index;
        oldest_generation := self.tokens(index).generation;
      end if;
    end loop;
    return oldest_index;
  end find_available_token_slot;

  function find_free_work_record (self : Context) return Natural is
  begin
    if self.work_records = null then
      return 0;
    end if;

    for index in 1 .. self.capacity loop
      if not self.work_records(index).active then
        return index;
      end if;
    end loop;
    return 0;
  end find_free_work_record;

  function request_root_matches
    (item  : Rotation_Operation_Record;
     value : String)
  return Boolean
  is
  begin
    return value'length /= 0 and then
      item.request_root_length = value'length and then
      item.request_root(1 .. item.request_root_length) = value;
  end request_root_matches;

  function find_rotation_operation
    (self  : Context;
     value : String)
  return Natural
  is
  begin
    if self.rotation_operations = null then
      return 0;
    end if;

    for index in 1 .. self.capacity loop
      if self.rotation_operations(index).state /= Operation_Empty and then
         token_matches
           (self.rotation_operations(index).operation_id.data,
            self.rotation_operations(index).operation_id.length,
            value)
      then
        return index;
      end if;
    end loop;
    return 0;
  end find_rotation_operation;

  function find_prepared_rotation
    (self         : Context;
     root         : Canonical_Working_Directory;
     request_root : String)
  return Natural
  is
  begin
    if self.rotation_operations = null then
      return 0;
    end if;

    for index in 1 .. self.capacity loop
      if self.rotation_operations(index).state = Operation_Prepared and then
         same_root (self.rotation_operations(index).root, root) and then
         request_root_matches (self.rotation_operations(index), request_root)
      then
        return index;
      end if;
    end loop;
    return 0;
  end find_prepared_rotation;

  function rotation_operation_slot (self : Context) return Natural is
    oldest_index  : Natural := 0;
    oldest_serial : Interfaces.Unsigned_64 := 0;
  begin
    if self.rotation_operations = null then
      return 0;
    end if;

    for index in 1 .. self.capacity loop
      if self.rotation_operations(index).state = Operation_Empty then
        return index;
      elsif oldest_index = 0 or else
            self.rotation_operations(index).serial < oldest_serial
      then
        oldest_index := index;
        oldest_serial := self.rotation_operations(index).serial;
      end if;
    end loop;
    return oldest_index;
  end rotation_operation_slot;

  function initialize_instance_prefix
    (self : in out Context)
  return Clair.Status.Code
  is
    bytes : System.Storage_Elements.Storage_Array
      (1 .. System.Storage_Elements.Storage_Offset (INSTANCE_RANDOM_BYTES)) :=
        [others => 0];
    status : Clair.Status.Code;
    target : Positive := self.instance_prefix'first;
    value  : Natural;
  begin
    self.instance_prefix := [others => Character'val (0)];
    status := Clair.Random.fill (bytes);
    if status /= Clair.Status.OK then
      bytes := [others => 0];
      return status;
    end if;

    for item of bytes loop
      value := Natural (item);
      self.instance_prefix(target) := HEX_DIGITS(value / 16 + 1);
      self.instance_prefix(target + 1) := HEX_DIGITS(value mod 16 + 1);
      target := target + 2;
    end loop;
    bytes := [others => 0];
    return Clair.Status.OK;
  end initialize_instance_prefix;

  function allocate_operation_id
    (self   : in out Context;
     result : out Rotation_Operation_Id;
     serial : out Interfaces.Unsigned_64)
  return Clair.Status.Code
  is
    bytes : System.Storage_Elements.Storage_Array
      (1 .. System.Storage_Elements.Storage_Offset (OPERATION_RANDOM_BYTES)) :=
        [others => 0];
    status : Clair.Status.Code;
    target : Positive;
    value  : Natural;
    item   : Interfaces.Unsigned_64;
  begin
    result := (others => <>);
    serial := 0;
    if self.next_operation_serial = Interfaces.Unsigned_64'Last then
      self.stopping := True;
      return Clair.Status.RANGE_ERROR;
    end if;

    status := Clair.Random.fill (bytes);
    if status /= Clair.Status.OK then
      bytes := [others => 0];
      return status;
    end if;

    result.data(1 .. 2) := "o-";
    target := 3;
    for byte of bytes loop
      value := Natural (byte);
      result.data(target) := HEX_DIGITS(value / 16 + 1);
      result.data(target + 1) := HEX_DIGITS(value mod 16 + 1);
      target := target + 2;
    end loop;

    serial := self.next_operation_serial;
    item := serial;
    target := MAXIMUM_OPERATION_ID_BYTES;
    while target >= 35 loop
      result.data(target) := HEX_DIGITS(Natural(item mod 16) + 1);
      item := item / 16;
      exit when target = 35;
      target := target - 1;
    end loop;

    result.length := MAXIMUM_OPERATION_ID_BYTES;
    self.next_operation_serial := self.next_operation_serial + 1;
    bytes := [others => 0];
    return Clair.Status.OK;
  exception
    when others =>
      bytes := [others => 0];
      result := (others => <>);
      serial := 0;
      self.stopping := True;
      return Clair.Status.INTERNAL_ERROR;
  end allocate_operation_id;

  function prepare_rotation_operation
    (self         : in out Context;
     root         : Canonical_Working_Directory;
     request_root : String;
     result       : out Rotation_Operation_Id)
  return Clair.Status.Code
  is
    index  : Natural;
    serial : Interfaces.Unsigned_64 := 0;
    status : Clair.Status.Code;
  begin
    result := (others => <>);
    index := find_prepared_rotation (self, root, request_root);
    if index /= 0 then
      result := self.rotation_operations(index).operation_id;
      return Clair.Status.OK;
    end if;

    index := rotation_operation_slot (self);
    if index = 0 then
      return Clair.Status.INTERNAL_ERROR;
    end if;

    clear_rotation_operation (self.rotation_operations(index));
    status := allocate_operation_id (self, result, serial);
    if status /= Clair.Status.OK then
      return status;
    end if;

    self.rotation_operations(index).state := Operation_Prepared;
    self.rotation_operations(index).operation_id := result;
    self.rotation_operations(index).request_root(1 .. request_root'length) :=
      request_root;
    self.rotation_operations(index).request_root_length := request_root'length;
    self.rotation_operations(index).root := root;
    self.rotation_operations(index).serial := serial;
    return Clair.Status.OK;
  end prepare_rotation_operation;

  function allocate_generation
    (self   : in out Context;
     result : out Interfaces.Unsigned_64)
  return Clair.Status.Code
  is
  begin
    result := 0;
    if self.next_generation = Interfaces.Unsigned_64'Last then
      self.stopping := True;
      return Clair.Status.RANGE_ERROR;
    end if;

    result := self.next_generation;
    self.next_generation := self.next_generation + 1;
    return Clair.Status.OK;
  end allocate_generation;

  function allocate_work_serial
    (self   : in out Context;
     result : out Interfaces.Unsigned_64)
  return Clair.Status.Code
  is
  begin
    result := 0;
    if self.next_work_serial = Interfaces.Unsigned_64'Last then
      self.stopping := True;
      return Clair.Status.RANGE_ERROR;
    end if;

    result := self.next_work_serial;
    self.next_work_serial := self.next_work_serial + 1;
    return Clair.Status.OK;
  end allocate_work_serial;

  function make_token
    (self       : Context;
     generation : Interfaces.Unsigned_64;
     result     : out Workspace_Token)
  return Clair.Status.Code
  is
    bytes : System.Storage_Elements.Storage_Array
      (1 .. System.Storage_Elements.Storage_Offset (TOKEN_RANDOM_BYTES)) :=
        [others => 0];
    status : Clair.Status.Code;
    target : Positive;
    value  : Natural;
    item   : Interfaces.Unsigned_64;
  begin
    result := (others => <>);
    if self.instance_prefix(self.instance_prefix'first) =
         Character'val (0) or else
       generation = 0
    then
      return Clair.Status.INVALID_STATE;
    end if;

    status := Clair.Random.fill (bytes);
    if status /= Clair.Status.OK then
      bytes := [others => 0];
      return status;
    end if;

    result.data(1 .. 2) := "w-";
    result.data(3 .. 34) := self.instance_prefix;

    item := generation;
    target := 50;
    while target >= 35 loop
      result.data(target) := HEX_DIGITS(Natural(item mod 16) + 1);
      item := item / 16;
      exit when target = 35;
      target := target - 1;
    end loop;

    target := 51;
    for byte of bytes loop
      value := Natural (byte);
      result.data(target) := HEX_DIGITS(value / 16 + 1);
      result.data(target + 1) := HEX_DIGITS(value mod 16 + 1);
      target := target + 2;
    end loop;

    result.length := MAXIMUM_WORKSPACE_TOKEN_BYTES;
    bytes := [others => 0];
    return Clair.Status.OK;
  exception
    when others =>
      bytes := [others => 0];
      result := (others => <>);
      return Clair.Status.INTERNAL_ERROR;
  end make_token;

  function initialize
    (self  : in out Context;
     limit : Sonbal.Configuration.Work_Slot_Count)
  return Clair.Status.Code
  is
    status : Clair.Status.Code;
  begin
    if self.initialized or else self.tokens /= null or else
       self.rotation_operations /= null or else self.work_records /= null
    then
      return Clair.Status.INVALID_STATE;
    end if;

    begin
      self.tokens := new Token_Slot_Array (1 .. Positive (limit));
      self.rotation_operations :=
        new Rotation_Operation_Array (1 .. Positive (limit));
      self.work_records := new Work_Record_Array (1 .. Positive (limit));
    exception
      when Storage_Error =>
        if self.work_records /= null then
          free_work_records (self.work_records);
        end if;
        if self.rotation_operations /= null then
          free_rotation_operations (self.rotation_operations);
        end if;
        if self.tokens /= null then
          free_tokens (self.tokens);
        end if;
        return Clair.Status.OUT_OF_MEMORY;
    end;

    self.capacity := Natural (limit);
    self.next_generation := 1;
    self.next_operation_serial := 1;
    self.next_work_serial := 1;
    status := initialize_instance_prefix (self);
    if status /= Clair.Status.OK then
      free_work_records (self.work_records);
      free_rotation_operations (self.rotation_operations);
      free_tokens (self.tokens);
      self.capacity := 0;
      return status;
    end if;

    self.initialized := True;
    self.stopping := False;
    return Clair.Status.OK;
  end initialize;

  function rotate
    (self         : in out Context;
     root         : String;
     operation_id : String;
     result       : out Rotation_Result)
  return Clair.Status.Code
  is
    resolved        : Canonical_Working_Directory;
    token           : Workspace_Token;
    root_identity   : Workspace_Root_Identity;
    generation      : Interfaces.Unsigned_64 := 0;
    operation_index : Natural := 0;
    token_index   : Natural := 0;
    now             : Ada.Real_Time.Time;
    status          : Clair.Status.Code;
  begin
    result := (others => <>);
    if not self.initialized or else self.stopping or else
       self.tokens = null or else self.rotation_operations = null or else
       self.work_records = null
    then
      return Clair.Status.INVALID_STATE;
    end if;

    status := canonicalize_directory (root, resolved);
    if status /= Clair.Status.OK then
      return status;
    end if;

    if operation_id'length = 0 then
      status := prepare_rotation_operation
        (self, resolved, root, result.operation_id);
      if status /= Clair.Status.OK then
        return status;
      end if;
      result.state := Rotation_Prepared;
      return Clair.Status.OK;
    end if;

    operation_index := find_rotation_operation (self, operation_id);
    if operation_index = 0 or else
       not request_root_matches (self.rotation_operations(operation_index), root) or
       else not same_root (self.rotation_operations(operation_index).root, resolved)
    then
      result.state := Rotation_Stale_Operation;
      return Clair.Status.OK;
    end if;

    result.operation_id := self.rotation_operations(operation_index).operation_id;

    if self.rotation_operations(operation_index).state = Operation_Rotated then
      token_index := find_token_by_generation
        (self, self.rotation_operations(operation_index).rotation_generation);
      if token_index = 0 or else
         not same_root (slot_root (self.tokens(token_index)), resolved)
      then
        result := (others => <>);
        result.state := Rotation_Stale_Operation;
      else
        result.state := Rotation_Rotated;
        result.operation_id :=
          self.rotation_operations(operation_index).operation_id;
        result.token := self.tokens(token_index).token;
      end if;
      return Clair.Status.OK;
    end if;

    now := Ada.Real_Time.Clock;
    token_index := find_token_by_root (self, resolved);
    if token_index /= 0 and then
       cooldown_active (self.tokens(token_index), now)
    then
      result.state := Rotation_Cooldown;
      return Clair.Status.OK;
    end if;

    if token_index = 0 then
      token_index := find_available_token_slot (self, now);
      if token_index = 0 then
        result.state := Rotation_Capacity_Exceeded;
        return Clair.Status.OK;
      end if;
    end if;

    status := query_root_identity (resolved, root_identity);
    if status /= Clair.Status.OK then
      return status;
    end if;

    status := make_token (self, self.next_generation, token);
    if status /= Clair.Status.OK then
      return status;
    end if;

    status := allocate_generation (self, generation);
    if status /= Clair.Status.OK then
      wipe (token);
      return status;
    end if;

    if self.tokens(token_index).root_length /= 0 and then
       not same_root (slot_root (self.tokens(token_index)), resolved)
    then
      clear_token (self.tokens(token_index));
    end if;

    self.tokens(token_index).root := resolved.data;
    self.tokens(token_index).root_length := resolved.length;
    self.tokens(token_index).root_identity := root_identity;
    self.tokens(token_index).generation := generation;
    self.tokens(token_index).token := token;
    self.tokens(token_index).has_current := True;
    self.tokens(token_index).has_last_rotation := True;
    self.tokens(token_index).last_rotation := now;

    self.rotation_operations(operation_index).state := Operation_Rotated;
    self.rotation_operations(operation_index).rotation_generation := generation;

    result.state := Rotation_Rotated;
    result.token := token;
    return Clair.Status.OK;
  exception
    when others =>
      self.stopping := True;
      result := (others => <>);
      return Clair.Status.INTERNAL_ERROR;
  end rotate;

  function prepare_work_admission
    (self        : in out Context;
     token       : String;
     result      : in out Work_Result;
     token_index : out Natural;
     work_index  : out Natural)
  return Clair.Status.Code
  is
  begin
    token_index := 0;
    work_index := 0;

    if not self.initialized or else self.stopping or else
       self.tokens = null or else self.work_records = null
    then
      return Clair.Status.INVALID_STATE;
    end if;

    token_index := find_token_by_value (self, token);
    if token_index = 0 then
      result.state := Work_Stale_Token;
      return Clair.Status.OK;
    end if;

    work_index := find_free_work_record (self);
    if work_index = 0 then
      result.state := Work_Capacity_Exceeded;
    end if;
    return Clair.Status.OK;
  end prepare_work_admission;

  function accept_work
    (self        : in out Context;
     token_index : Positive;
     work_index  : Positive;
     result      : in out Work_Result)
  return Clair.Status.Code
  is
    serial : Interfaces.Unsigned_64 := 0;
    status : Clair.Status.Code;
  begin
    status := allocate_work_serial (self, serial);
    if status /= Clair.Status.OK then
      return status;
    end if;

    self.work_records(work_index).active := True;
    self.work_records(work_index).token_index := token_index;
    self.work_records(work_index).generation :=
      self.tokens(token_index).generation;
    self.work_records(work_index).serial := serial;
    self.tokens(token_index).active_work_count :=
      self.tokens(token_index).active_work_count + 1;

    result.state := Work_Accepted;
    result.workspace_root := slot_root (self.tokens(token_index));
    result.workspace_identity := self.tokens(token_index).root_identity;
    result.ticket.index := work_index;
    result.ticket.generation := self.tokens(token_index).generation;
    result.ticket.serial := serial;
    return Clair.Status.OK;
  end accept_work;

  function begin_current_work
    (self   : in out Context;
     token  : String;
     result : out Work_Result)
  return Clair.Status.Code
  is
    token_index : Natural := 0;
    work_index  : Natural := 0;
    status      : Clair.Status.Code;
  begin
    result := (others => <>);
    status := prepare_work_admission
      (self, token, result, token_index, work_index);
    if status /= Clair.Status.OK or else
       result.state /= Work_Stale_Token
    then
      return status;
    elsif token_index = 0 then
      return Clair.Status.OK;
    elsif work_index = 0 then
      result.state := Work_Capacity_Exceeded;
      return Clair.Status.OK;
    end if;

    return accept_work
      (self, Positive(token_index), Positive(work_index), result);
  exception
    when others =>
      self.stopping := True;
      result := (others => <>);
      return Clair.Status.INTERNAL_ERROR;
  end begin_current_work;

  function begin_process_work
    (self   : in out Context;
     token  : String;
     cwd    : String;
     result : out Work_Result)
  return Clair.Status.Code
  is
    resolved    : Canonical_Working_Directory;
    token_index : Natural := 0;
    work_index  : Natural := 0;
    status      : Clair.Status.Code;
  begin
    result := (others => <>);
    status := prepare_work_admission
      (self, token, result, token_index, work_index);
    if status /= Clair.Status.OK then
      return status;
    elsif token_index = 0 then
      return Clair.Status.OK;
    elsif work_index = 0 then
      result.state := Work_Capacity_Exceeded;
      return Clair.Status.OK;
    end if;

    status := canonicalize_directory (cwd, resolved);
    if status /= Clair.Status.OK then
      return status;
    elsif not path_is_within (self.tokens(token_index), resolved) then
      result.state := Work_Outside_Workspace;
      return Clair.Status.OK;
    end if;

    status := accept_work
      (self, Positive(token_index), Positive(work_index), result);
    if status = Clair.Status.OK then
      result.working_directory := resolved;
    end if;
    return status;
  exception
    when others =>
      self.stopping := True;
      result := (others => <>);
      return Clair.Status.INTERNAL_ERROR;
  end begin_process_work;

  function end_work
    (self   : in out Context;
     ticket : in out Work_Ticket)
  return Clair.Status.Code
  is
    token_index : Natural;
  begin
    if not self.initialized or else self.tokens = null or else
       self.work_records = null or else not is_valid (ticket) or else
       ticket.index > self.capacity
    then
      return Clair.Status.INVALID_STATE;
    end if;

    if not self.work_records(ticket.index).active or else
       self.work_records(ticket.index).generation /= ticket.generation or else
       self.work_records(ticket.index).serial /= ticket.serial
    then
      return Clair.Status.INVALID_STATE;
    end if;

    token_index := self.work_records(ticket.index).token_index;
    if token_index not in 1 .. self.capacity or else
       self.tokens(token_index).root_length = 0 or else
       self.tokens(token_index).active_work_count = 0
    then
      self.stopping := True;
      return Clair.Status.INTERNAL_ERROR;
    end if;

    clear_work_record (self.work_records(ticket.index));
    self.tokens(token_index).active_work_count :=
      self.tokens(token_index).active_work_count - 1;
    ticket := (others => <>);
    return Clair.Status.OK;
  exception
    when others =>
      self.stopping := True;
      return Clair.Status.INTERNAL_ERROR;
  end end_work;

  procedure stop (self : in out Context) is
  begin
    if self.initialized then
      self.stopping := True;
    end if;
  end stop;

  function finalize (self : in out Context) return Clair.Status.Code is
  begin
    if not self.initialized then
      return Clair.Status.INVALID_STATE;
    end if;

    if active_work_count (self) /= 0 then
      return Clair.Status.INVALID_STATE;
    end if;

    free_work_records (self.work_records);
    free_rotation_operations (self.rotation_operations);
    free_tokens (self.tokens);
    self.capacity := 0;
    self.next_generation := 1;
    self.next_operation_serial := 1;
    self.next_work_serial := 1;
    self.instance_prefix := [others => Character'val (0)];
    self.initialized := False;
    self.stopping := False;
    return Clair.Status.OK;
  exception
    when others =>
      return Clair.Status.INTERNAL_ERROR;
  end finalize;

  function active_work_count (self : Context) return Natural is
    result : Natural := 0;
  begin
    if not self.initialized or else self.tokens = null then
      return 0;
    end if;

    for index in 1 .. self.capacity loop
      result := result + self.tokens(index).active_work_count;
    end loop;
    return result;
  end active_work_count;

  function token_count (self : Context) return Natural is
    result : Natural := 0;
  begin
    if not self.initialized or else self.tokens = null then
      return 0;
    end if;

    for index in 1 .. self.capacity loop
      if self.tokens(index).has_current then
        result := result + 1;
      end if;
    end loop;
    return result;
  end token_count;

  function is_initialized (self : Context) return Boolean is
    (self.initialized);

end Sonbal.Workspace_Tokens;
