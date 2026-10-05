-- ============================================================================
-- sonbal-process_jobs.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Ada.Strings;
with Ada.Strings.Fixed;
with Ada.Unchecked_Deallocation;
with Clair.Log;
with Clair.Random;

package body Sonbal.Process_Jobs is

  use type Ada.Real_Time.Time;
  use type Ada.Real_Time.Time_Span;
  use type Clair.Process.Execution.Event_Loop.Operation_Cause;
  use type Clair.Status.Code;
  use type Interfaces.Unsigned_64;
  use type Sonbal.Process_Admission.Context_Access;
  use type Sonbal.Workspace_Tokens.Context_Access;
  use type Sonbal.Process_Execution.Operation_Access;
  use type System.Storage_Elements.Storage_Offset;

  MAXIMUM_CLEANUP_RETRIES  : constant Positive := 3;
  RETAINED_STREAM_BYTES    : constant Positive := 32_768;
  RANDOM_INSTANCE_BYTES    : constant Positive := 16;
  RANDOM_JOB_SECRET_BYTES  : constant Positive := 16;
  INSTANCE_HEX_BYTES       : constant Positive := 32;
  SEQUENCE_HEX_BYTES       : constant Positive := 16;
  JOB_INSTANCE_FIRST       : constant Positive := 3;
  JOB_INSTANCE_LAST        : constant Positive :=
    JOB_INSTANCE_FIRST + INSTANCE_HEX_BYTES - 1;
  JOB_SEQUENCE_FIRST       : constant Positive := JOB_INSTANCE_LAST + 1;
  JOB_SEQUENCE_LAST        : constant Positive :=
    JOB_SEQUENCE_FIRST + SEQUENCE_HEX_BYTES - 1;
  JOB_SECRET_FIRST         : constant Positive := JOB_SEQUENCE_LAST + 1;
  HEX_DIGITS               : constant String := "0123456789abcdef";

  procedure free_buffer is new Ada.Unchecked_Deallocation
    (Retained_Buffer, Retained_Buffer_Access);
  procedure free_slots is new Ada.Unchecked_Deallocation
    (Job_Slot_Array, Job_Slot_Array_Access);

  function image (value : Job_Identifier) return String is
  begin
    if value.length = 0 then
      return "";
    end if;
    return value.data(1 .. value.length);
  end image;

  function image (value : Job_Cursor) return String is
  begin
    if value.length = 0 then
      return "";
    end if;
    return value.data(1 .. value.length);
  end image;

  function instance_image (value : Job_Instance_Identifier) return String is
  begin
    if value.length = 0 then
      return "";
    end if;
    return value.data(1 .. value.length);
  end instance_image;

  function compact_image (value : Natural) return String is
    (Ada.Strings.Fixed.Trim (Natural'image(value), Ada.Strings.Both));

  function compact_image (value : Interfaces.Unsigned_64) return String is
    (Ada.Strings.Fixed.Trim
       (Interfaces.Unsigned_64'image (value), Ada.Strings.Both));

  function trace_kind_image (value : Trace_Event_Kind) return String is
  begin
    case value is
      when Trace_Start_Request =>
        return "start_request";
      when Trace_Launch_Accepted =>
        return "launch_accepted";
      when Trace_Start_Response =>
        return "start_result";
      when Trace_Start_Response_Ready =>
        return "start_response_ready";
      when Trace_Poll_Request =>
        return "poll_request";
      when Trace_Poll_Response =>
        return "poll_result";
      when Trace_Poll_Response_Ready =>
        return "poll_response_ready";
      when Trace_Terminal_Observed =>
        return "terminal_observed";
      when Trace_Cancellation_Settled =>
        return "cancellation_settled";
      when Trace_Terminal_Published =>
        return "terminal_published";
      when Trace_Terminal_Evicted =>
        return "terminal_evicted";
      when Trace_Cancel_Request =>
        return "cancel_request";
      when Trace_Cancel_Response =>
        return "cancel_result";
      when Trace_Cancel_Response_Ready =>
        return "cancel_response_ready";
    end case;
  end trace_kind_image;

  function trace_outcome_image (value : Trace_Outcome) return String is
  begin
    case value is
      when Trace_None =>
        return "none";
      when Trace_Running =>
        return "running";
      when Trace_Terminal =>
        return "terminal";
      when Trace_Execution_Busy =>
        return "execution_busy";
      when Trace_Stale_Workspace_Token =>
        return "stale_workspace_token";
      when Trace_Outside_Workspace =>
        return "outside_workspace";
      when Trace_Expired =>
        return "expired";
      when Trace_Stale_Instance =>
        return "stale_instance";
      when Trace_Not_Found =>
        return "not_found";
      when Trace_Invalid_Cursor =>
        return "invalid_cursor";
      when Trace_Cancelling =>
        return "cancelling";
      when Trace_Already_Terminal =>
        return "already_terminal";
      when Trace_Exited =>
        return "exited";
      when Trace_Signaled =>
        return "signaled";
      when Trace_Timed_Out =>
        return "timed_out";
      when Trace_Launch_Failed =>
        return "launch_failed";
      when Trace_Cancelled =>
        return "cancelled";
      when Trace_Execution_Failed =>
        return "execution_failed";
    end case;
  end trace_outcome_image;

  function trace_outcome_of (value : Start_State) return Trace_Outcome is
  begin
    case value is
      when Start_Running =>
        return Trace_Running;
      when Start_Execution_Busy =>
        return Trace_Execution_Busy;
      when Start_Stale_Workspace_Token =>
        return Trace_Stale_Workspace_Token;
      when Start_Outside_Workspace =>
        return Trace_Outside_Workspace;
      when Start_Execution_Failed =>
        return Trace_Execution_Failed;
    end case;
  end trace_outcome_of;

  function trace_outcome_of (value : Poll_State) return Trace_Outcome is
  begin
    case value is
      when Poll_Running =>
        return Trace_Running;
      when Poll_Terminal =>
        return Trace_Terminal;
      when Poll_Expired =>
        return Trace_Expired;
      when Poll_Stale_Instance =>
        return Trace_Stale_Instance;
      when Poll_Not_Found =>
        return Trace_Not_Found;
      when Poll_Invalid_Cursor =>
        return Trace_Invalid_Cursor;
      when Poll_Execution_Failed =>
        return Trace_Execution_Failed;
    end case;
  end trace_outcome_of;

  function trace_outcome_of (value : Cancel_State) return Trace_Outcome is
  begin
    case value is
      when Cancel_Cancelling =>
        return Trace_Cancelling;
      when Cancel_Already_Terminal =>
        return Trace_Already_Terminal;
      when Cancel_Expired =>
        return Trace_Expired;
      when Cancel_Stale_Instance =>
        return Trace_Stale_Instance;
      when Cancel_Not_Found =>
        return Trace_Not_Found;
      when Cancel_Execution_Failed =>
        return Trace_Execution_Failed;
    end case;
  end trace_outcome_of;

  function trace_outcome_of (value : Terminal_State) return Trace_Outcome is
  begin
    case value is
      when Job_Exited =>
        return Trace_Exited;
      when Job_Signaled =>
        return Trace_Signaled;
      when Job_Timed_Out =>
        return Trace_Timed_Out;
      when Job_Launch_Failed =>
        return Trace_Launch_Failed;
      when Job_Cancelled =>
        return Trace_Cancelled;
      when Job_Execution_Failed =>
        return Trace_Execution_Failed;
    end case;
  end trace_outcome_of;

  procedure clear_trace (self : in out Context) is
  begin
    self.trace_events := [others => <>];
    self.trace_count := 0;
    self.trace_next_index := 1;
    self.trace_overwrite_count := 0;
    self.trace_next_ordinal := 1;
    self.trace_next_correlation := 1;
    self.trace_epoch := Ada.Real_Time.Time_First;
    self.trace_enabled := False;
    self.trace_log_enabled := False;
  end clear_trace;

  procedure configure_trace
    (self        : in out Context;
     enabled     : Boolean;
     log_enabled : Boolean)
  is
  begin
    clear_trace (self);
    if not enabled then
      return;
    end if;

    begin
      self.trace_epoch := Ada.Real_Time.Clock;
      self.trace_enabled := True;
      self.trace_log_enabled := log_enabled;
    exception
      when others =>
        clear_trace (self);
    end;
  end configure_trace;

  function allocate_trace_correlation
    (self : in out Context) return Interfaces.Unsigned_64
  is
    result : Interfaces.Unsigned_64;
  begin
    if not self.trace_enabled or else self.trace_next_correlation = 0 then
      return 0;
    end if;

    result := self.trace_next_correlation;
    if self.trace_next_correlation = Interfaces.Unsigned_64'Last then
      self.trace_next_correlation := 0;
    else
      self.trace_next_correlation := self.trace_next_correlation + 1;
    end if;
    return result;
  exception
    when others =>
      return 0;
  end allocate_trace_correlation;

  procedure record_trace
    (self        : in out Context;
     kind        : Trace_Event_Kind;
     correlation : Interfaces.Unsigned_64;
     outcome     : Trace_Outcome := Trace_None)
  is
    now     : Ada.Real_Time.Time;
    ordinal : Interfaces.Unsigned_64;
  begin
    if not self.trace_enabled or else self.trace_next_ordinal = 0 then
      return;
    end if;

    now := Ada.Real_Time.Clock;
    ordinal := self.trace_next_ordinal;
    if self.trace_next_ordinal = Interfaces.Unsigned_64'Last then
      self.trace_next_ordinal := 0;
    elsif self.trace_next_ordinal /= 0 then
      self.trace_next_ordinal := self.trace_next_ordinal + 1;
    end if;

    self.trace_events(self.trace_next_index) :=
      (ordinal     => ordinal,
       correlation => correlation,
       kind        => kind,
       outcome     => outcome,
       time_value  => now);

    if self.trace_count < MAXIMUM_TRACE_EVENTS then
      self.trace_count := self.trace_count + 1;
    elsif self.trace_overwrite_count < Interfaces.Unsigned_64'Last then
      self.trace_overwrite_count := self.trace_overwrite_count + 1;
    end if;

    if self.trace_next_index = MAXIMUM_TRACE_EVENTS then
      self.trace_next_index := 1;
    else
      self.trace_next_index := self.trace_next_index + 1;
    end if;

    if self.trace_log_enabled then
      declare
        elapsed : constant Duration :=
          (if self.trace_epoch = Ada.Real_Time.Time_First or else
              now < self.trace_epoch
           then 0.0
           else Ada.Real_Time.To_Duration (now - self.trace_epoch));
      begin
        Clair.Log.write
          (severity => Clair.Log.Info,
           message  =>
             "sonbal: trace scope=job event=" & trace_kind_image (kind) &
             " outcome=" & trace_outcome_image (outcome) &
             " ordinal=" & compact_image (ordinal) &
             " correlation=" & compact_image (correlation) &
             " monotonic_s=" &
               Ada.Strings.Fixed.Trim
                 (Duration'image (elapsed), Ada.Strings.Both),
           destinations => Clair.Log.Native_Diagnostic);
      exception
        when others =>
          null;
      end;
    end if;
  exception
    when others =>
      null;
  end record_trace;

  procedure clear_stream
    (data      : in out Retained_Buffer_Access;
     length    : in out Natural;
     truncated : in out Boolean)
  is
  begin
    if data /= null then
      if length > 0 then
        data.all
          (data.all'first ..
           data.all'first +
             System.Storage_Elements.Storage_Offset(length - 1)) :=
          [others => 0];
      end if;
      free_buffer (data);
    end if;
    length := 0;
    truncated := False;
  end clear_stream;

  procedure clear_slot (slot : in out Job_Slot) is
  begin
    clear_stream
      (slot.stdout_data, slot.stdout_length, slot.stdout_truncated);
    clear_stream
      (slot.stderr_data, slot.stderr_length, slot.stderr_truncated);
    slot.state := Slot_Empty;
    slot.job_id := (others => <>);
    slot.sequence := 0;
    slot.trace_correlation := 0;
    slot.terminal := Job_Execution_Failed;
    slot.has_exit_code := False;
    slot.exit_code := 0;
    slot.has_launch_stage := False;
    slot.launch_stage := Clair.Process.Execution.Program_Execution_Stage;
    slot.has_infrastructure_stage := False;
    slot.infrastructure_stage :=
      Clair.Process.Execution.Execution_Preparation_Stage;
    slot.has_ownership_stage := False;
    slot.ownership_stage := Clair.Process.Execution.Ownership_Setup_Stage;
  end clear_slot;

  procedure evict_terminal_slot
    (self  : in out Context;
     index : Positive)
  is
  begin
    if self.slots = null or else index > self.capacity then
      return;
    end if;

    if self.slots(index).state = Slot_Terminal then
      record_trace
        (self,
         Trace_Terminal_Evicted,
         self.slots(index).trace_correlation,
         trace_outcome_of (self.slots(index).terminal));
    end if;
    clear_slot (self.slots(index));
  end evict_terminal_slot;

  function terminal_count (self : Context) return Natural is
    result : Natural := 0;
  begin
    if self.slots = null then
      return 0;
    end if;

    for index in 1 .. self.capacity loop
      if self.slots(index).state = Slot_Terminal then
        result := result + 1;
      end if;
    end loop;
    return result;
  end terminal_count;

  function oldest_terminal
    (self          : Context;
     exclude_index : Natural := 0) return Natural
  is
    result          : Natural := 0;
    oldest_sequence : Interfaces.Unsigned_64 := Interfaces.Unsigned_64'Last;
  begin
    if self.slots = null then
      return 0;
    end if;

    for index in 1 .. self.capacity loop
      if index /= exclude_index and then
         self.slots(index).state = Slot_Terminal and then
         self.slots(index).sequence < oldest_sequence
      then
        result := index;
        oldest_sequence := self.slots(index).sequence;
      end if;
    end loop;
    return result;
  end oldest_terminal;

  procedure reserve_terminal_slot
    (self          : in out Context;
     current_index : Positive)
  is
    victim : Natural;
  begin
    if self.terminal_limit = 0 or else
       terminal_count(self) < self.terminal_limit
    then
      return;
    end if;

    victim := oldest_terminal(self, current_index);
    if victim /= 0 then
      evict_terminal_slot (self, Positive (victim));
    end if;
  end reserve_terminal_slot;

  function find_job
    (self   : Context;
     job_id : String) return Natural
  is
  begin
    if self.slots = null or else job_id'length = 0 then
      return 0;
    end if;

    for index in 1 .. self.capacity loop
      if self.slots(index).state /= Slot_Empty and then
         self.slots(index).job_id.length = job_id'length and then
         image(self.slots(index).job_id) = job_id
      then
        return index;
      end if;
    end loop;
    return 0;
  end find_job;

  function find_operation
    (self      : Context;
     operation : not null Sonbal.Process_Execution.Operation_Access)
  return Natural
  is
  begin
    if self.slots = null then
      return 0;
    end if;

    for index in 1 .. self.capacity loop
      if self.slots(index).process'unchecked_access = operation then
        return index;
      end if;
    end loop;
    return 0;
  end find_operation;

  function select_start_slot (self : Context) return Natural is
    victim : Natural;
  begin
    if self.slots = null then
      return 0;
    end if;

    for index in 1 .. self.capacity loop
      if self.slots(index).state = Slot_Empty then
        return index;
      end if;
    end loop;

    victim := oldest_terminal(self);
    return victim;
  end select_start_slot;

  function make_instance_id
    (result : out Job_Instance_Identifier) return Clair.Status.Code
  is
    bytes : System.Storage_Elements.Storage_Array
      (1 .. System.Storage_Elements.Storage_Offset(RANDOM_INSTANCE_BYTES)) :=
        [others => 0];
    status : Clair.Status.Code;
    target : Positive := 1;
    value  : Natural;
  begin
    result := (others => <>);
    status := Clair.Random.fill(bytes);
    if status /= Clair.Status.OK then
      bytes := [others => 0];
      return status;
    end if;

    for item of bytes loop
      value := Natural(item);
      result.data(target) := HEX_DIGITS(value / 16 + 1);
      result.data(target + 1) := HEX_DIGITS(value mod 16 + 1);
      target := target + 2;
    end loop;
    result.length := INSTANCE_HEX_BYTES;
    bytes := [others => 0];
    return Clair.Status.OK;
  end make_instance_id;

  function sequence_image (value : Interfaces.Unsigned_64) return String is
    result    : String (1 .. SEQUENCE_HEX_BYTES);
    remaining : Interfaces.Unsigned_64 := value;
  begin
    for index in reverse result'range loop
      result(index) := HEX_DIGITS(Natural(remaining mod 16) + 1);
      remaining := remaining / 16;
    end loop;
    return result;
  end sequence_image;

  function parse_sequence
    (text   : String;
     result : out Interfaces.Unsigned_64) return Boolean
  is
    value : Interfaces.Unsigned_64 := 0;
    digit : Natural;
  begin
    result := 0;
    if text'length /= SEQUENCE_HEX_BYTES then
      return False;
    end if;

    for item of text loop
      if item in '0' .. '9' then
        digit := Character'pos(item) - Character'pos('0');
      elsif item in 'a' .. 'f' then
        digit := 10 + Character'pos(item) - Character'pos('a');
      else
        return False;
      end if;
      value := value * 16 + Interfaces.Unsigned_64(digit);
    end loop;
    result := value;
    return True;
  end parse_sequence;

  function find_job_by_sequence
    (self     : Context;
     sequence : Interfaces.Unsigned_64) return Natural
  is
  begin
    if self.slots = null or else sequence = 0 then
      return 0;
    end if;

    for index in 1 .. self.capacity loop
      if self.slots(index).state /= Slot_Empty and then
         self.slots(index).sequence = sequence
      then
        return index;
      end if;
    end loop;
    return 0;
  end find_job_by_sequence;

  type Missing_Job_State is
    (Missing_Not_Found,
     Missing_Expired,
     Missing_Stale_Instance);

  function classify_missing_job
    (self   : Context;
     job_id : String) return Missing_Job_State
  is
    first    : constant Integer := job_id'first;
    sequence : Interfaces.Unsigned_64 := 0;
  begin
    if self.instance_id.length /= INSTANCE_HEX_BYTES or else
       job_id'length /= MAXIMUM_JOB_ID_BYTES or else
       job_id(first .. first + 1) /= "j-"
    then
      return Missing_Not_Found;
    end if;

    for index in first + 2 .. job_id'last loop
      if job_id(index) not in '0' .. '9' and then
         job_id(index) not in 'a' .. 'f'
      then
        return Missing_Not_Found;
      end if;
    end loop;

    if job_id
      (first + JOB_INSTANCE_FIRST - 1 ..
       first + JOB_INSTANCE_LAST - 1) /= instance_image(self.instance_id)
    then
      return Missing_Stale_Instance;
    end if;

    if not parse_sequence
      (job_id
         (first + JOB_SEQUENCE_FIRST - 1 ..
          first + JOB_SEQUENCE_LAST - 1),
       sequence) or else
       sequence = 0 or else
       sequence >= self.next_sequence
    then
      return Missing_Not_Found;
    end if;

    if find_job_by_sequence(self, sequence) /= 0 then
      return Missing_Not_Found;
    end if;
    return Missing_Expired;
  end classify_missing_job;

  function make_job_id
    (self     : Context;
     sequence : Interfaces.Unsigned_64;
     result   : out Job_Identifier) return Clair.Status.Code
  is
    bytes : System.Storage_Elements.Storage_Array
      (1 .. System.Storage_Elements.Storage_Offset(RANDOM_JOB_SECRET_BYTES)) :=
        [others => 0];
    status : Clair.Status.Code;
    target : Positive := JOB_SECRET_FIRST;
    value  : Natural;
  begin
    result := (others => <>);
    if self.instance_id.length /= INSTANCE_HEX_BYTES or else sequence = 0 then
      return Clair.Status.INVALID_STATE;
    end if;

    status := Clair.Random.fill(bytes);
    if status /= Clair.Status.OK then
      bytes := [others => 0];
      return status;
    end if;

    result.data(1 .. 2) := "j-";
    result.data(JOB_INSTANCE_FIRST .. JOB_INSTANCE_LAST) :=
      instance_image(self.instance_id);
    result.data(JOB_SEQUENCE_FIRST .. JOB_SEQUENCE_LAST) :=
      sequence_image(sequence);

    for item of bytes loop
      value := Natural(item);
      result.data(target) := HEX_DIGITS(value / 16 + 1);
      result.data(target + 1) := HEX_DIGITS(value mod 16 + 1);
      target := target + 2;
    end loop;

    result.length := MAXIMUM_JOB_ID_BYTES;
    bytes := [others => 0];
    return Clair.Status.OK;
  end make_job_id;

  function make_cursor
    (job_id        : Job_Identifier;
     stdout_offset : Natural;
     stderr_offset : Natural;
     result        : out Job_Cursor) return Boolean
  is
    text : constant String :=
      image(job_id) & ":" & compact_image(stdout_offset) & ":" &
      compact_image(stderr_offset);
  begin
    result := (others => <>);
    if text'length = 0 or else text'length > result.data'length then
      return False;
    end if;

    result.data(1 .. text'length) := text;
    result.length := text'length;
    return True;
  end make_cursor;

  function parse_decimal
    (text    : String;
     maximum : Natural;
     result  : out Natural) return Boolean
  is
    value : Natural := 0;
    digit : Natural;
  begin
    result := 0;
    if text'length = 0 then
      return False;
    end if;

    for item of text loop
      if item not in '0' .. '9' then
        return False;
      end if;
      digit := Character'pos(item) - Character'pos('0');
      if value > (maximum - digit) / 10 then
        return False;
      end if;
      value := value * 10 + digit;
    end loop;

    result := value;
    return True;
  end parse_decimal;

  function parse_cursor
    (job_id        : Job_Identifier;
     text          : String;
     stdout_offset : out Natural;
     stderr_offset : out Natural) return Boolean
  is
    prefix : constant String := image(job_id) & ":";
    split  : Natural := 0;
    canonical : Job_Cursor;
  begin
    stdout_offset := 0;
    stderr_offset := 0;

    if text'length <= prefix'length or else
       text'length > MAXIMUM_CURSOR_BYTES or else
       text(text'first .. text'first + prefix'length - 1) /= prefix
    then
      return False;
    end if;

    for index in text'first + prefix'length .. text'last loop
      if text(index) = ':' then
        if split /= 0 then
          return False;
        end if;
        split := index;
      end if;
    end loop;

    if split = 0 or else split = text'first + prefix'length or else
       split = text'last
    then
      return False;
    end if;

    if not parse_decimal
      (text(text'first + prefix'length .. split - 1),
       RETAINED_STREAM_BYTES,
       stdout_offset) or else
       not parse_decimal
         (text(split + 1 .. text'last),
          RETAINED_STREAM_BYTES,
          stderr_offset)
    then
      return False;
    end if;

    return make_cursor
      (job_id, stdout_offset, stderr_offset, canonical) and then
      image(canonical) = text;
  end parse_cursor;

  function copy_terminal_streams
    (slot    : in out Job_Slot;
     outcome : Clair.Process.Execution.Result) return Boolean
  is
    copied : Natural := 0;
    status : Clair.Status.Code;
  begin
    slot.stdout_length :=
      Clair.Process.Execution.standard_output_length(outcome);
    slot.stderr_length :=
      Clair.Process.Execution.standard_error_length(outcome);
    slot.stdout_truncated :=
      Clair.Process.Execution.is_standard_output_truncated(outcome);
    slot.stderr_truncated :=
      Clair.Process.Execution.is_standard_error_truncated(outcome);

    begin
      if slot.stdout_length > 0 then
        slot.stdout_data := new Retained_Buffer;
        status := Clair.Process.Execution.copy_standard_output
          (outcome => outcome,
           offset => 0,
           buffer => slot.stdout_data.all
             (1 .. System.Storage_Elements.Storage_Offset(slot.stdout_length)),
           copied => copied);
        if status /= Clair.Status.OK or else copied /= slot.stdout_length then
          return False;
        end if;
      end if;

      copied := 0;
      if slot.stderr_length > 0 then
        slot.stderr_data := new Retained_Buffer;
        status := Clair.Process.Execution.copy_standard_error
          (outcome => outcome,
           offset => 0,
           buffer => slot.stderr_data.all
             (1 .. System.Storage_Elements.Storage_Offset(slot.stderr_length)),
           copied => copied);
        if status /= Clair.Status.OK or else copied /= slot.stderr_length then
          return False;
        end if;
      end if;
    exception
      when Storage_Error =>
        return False;
    end;

    return True;
  end copy_terminal_streams;

  procedure mark_execution_failed
    (slot    : in out Job_Slot;
     outcome : Clair.Process.Execution.Result)
  is
  begin
    slot.terminal := Job_Execution_Failed;
    slot.has_exit_code := False;
    slot.has_launch_stage := False;
    if Clair.Process.Execution.has_infrastructure_failure(outcome) then
      slot.has_infrastructure_stage := True;
      slot.infrastructure_stage :=
        Clair.Process.Execution.infrastructure_stage_of(outcome);
    elsif Clair.Process.Execution.is_available(outcome) and then
          Clair.Process.Execution.cleanup_status_of(outcome) /= Clair.Status.OK
    then
      slot.has_infrastructure_stage := True;
      slot.infrastructure_stage := Clair.Process.Execution.Resource_Cleanup_Stage;
    else
      slot.has_infrastructure_stage := False;
    end if;

    slot.has_ownership_stage :=
      Clair.Process.Execution.has_ownership_failure(outcome);
    if slot.has_ownership_stage then
      slot.ownership_stage :=
        Clair.Process.Execution.ownership_failure_stage_of(outcome);
    end if;
  end mark_execution_failed;

  overriding function on_complete
    (handler   : in out Completion_Bridge;
     operation : not null Sonbal.Process_Execution.Operation_Access;
     cause     : Clair.Process.Execution.Event_Loop.Operation_Cause;
     status    : Clair.Status.Code;
     outcome   : Clair.Process.Execution.Result)
  return Clair.Status.Code
  is
    self   : constant access Context := handler.owner;
    index  : Natural;
    failed : Boolean;
  begin
    if self = null or else not self.initialized or else self.slots = null then
      return Clair.Status.INVALID_STATE;
    end if;

    index := find_operation (self.all, operation);
    if index = 0 or else
       self.slots(index).state not in Slot_Running | Slot_Cancelling
    then
      return Clair.Status.INTERNAL_ERROR;
    end if;

    reserve_terminal_slot (self.all, Positive(index));

    declare
      slot : Job_Slot renames self.slots(index);
      available : constant Boolean :=
        Clair.Process.Execution.is_available(outcome);
    begin
      failed := status /= Clair.Status.OK or else
        Clair.Process.Execution.has_infrastructure_failure(outcome) or else
        (available and then
         Clair.Process.Execution.cleanup_status_of(outcome) /= Clair.Status.OK);

      if available and then not copy_terminal_streams(slot, outcome) then
        clear_stream
          (slot.stdout_data, slot.stdout_length, slot.stdout_truncated);
        clear_stream
          (slot.stderr_data, slot.stderr_length, slot.stderr_truncated);
        failed := True;
      end if;

      if failed or else not available or else
         not Clair.Process.Execution.has_completion(outcome)
      then
        mark_execution_failed (slot, outcome);
      elsif cause = Clair.Process.Execution.Event_Loop.Caller_Cancellation then
        slot.terminal := Job_Cancelled;
      else
        case Clair.Process.Execution.completion_of(outcome) is
          when Clair.Process.Execution.Exited =>
            slot.terminal := Job_Exited;
            slot.has_exit_code := True;
            slot.exit_code := Interfaces.Unsigned_32
              (Clair.Process.Execution.exit_code_of(outcome));
          when Clair.Process.Execution.Signaled =>
            slot.terminal := Job_Signaled;
          when Clair.Process.Execution.Timed_Out =>
            slot.terminal := Job_Timed_Out;
          when Clair.Process.Execution.Launch_Failed =>
            slot.terminal := Job_Launch_Failed;
            slot.has_launch_stage := True;
            slot.launch_stage :=
              Clair.Process.Execution.launch_stage_of(outcome);
        end case;
      end if;

      record_trace
        (self.all,
         Trace_Terminal_Observed,
         slot.trace_correlation,
         trace_outcome_of (slot.terminal));
      if cause = Clair.Process.Execution.Event_Loop.Caller_Cancellation then
        record_trace
          (self.all,
           Trace_Cancellation_Settled,
           slot.trace_correlation,
           trace_outcome_of (slot.terminal));
      end if;
      slot.state := Slot_Terminal;
      record_trace
        (self.all,
         Trace_Terminal_Published,
         slot.trace_correlation,
         trace_outcome_of (slot.terminal));
    end;

    if Sonbal.Process_Execution.has_runtime_resources(operation.all) then
      self.shutting_down := True;
      return Clair.Status.INTERNAL_ERROR;
    end if;
    return Clair.Status.OK;
  exception
    when others =>
      if self = null or else self.slots = null or else
         index not in 1 .. self.capacity
      then
        return Clair.Status.INTERNAL_ERROR;
      end if;

      self.shutting_down := True;
      reserve_terminal_slot (self.all, Positive(index));
      clear_stream
        (self.slots(index).stdout_data,
         self.slots(index).stdout_length,
         self.slots(index).stdout_truncated);
      clear_stream
        (self.slots(index).stderr_data,
         self.slots(index).stderr_length,
         self.slots(index).stderr_truncated);
      self.slots(index).terminal := Job_Execution_Failed;
      self.slots(index).has_exit_code := False;
      self.slots(index).has_launch_stage := False;
      self.slots(index).has_infrastructure_stage := False;
      self.slots(index).has_ownership_stage := False;
      record_trace
        (self.all,
         Trace_Terminal_Observed,
         self.slots(index).trace_correlation,
         Trace_Execution_Failed);
      if cause = Clair.Process.Execution.Event_Loop.Caller_Cancellation then
        record_trace
          (self.all,
           Trace_Cancellation_Settled,
           self.slots(index).trace_correlation,
           Trace_Execution_Failed);
      end if;
      self.slots(index).state := Slot_Terminal;
      record_trace
        (self.all,
         Trace_Terminal_Published,
         self.slots(index).trace_correlation,
         Trace_Execution_Failed);
      return Clair.Status.INTERNAL_ERROR;
  end on_complete;

  function cleanup_partial
    (self : aliased in out Context) return Clair.Status.Code
  is
    ok     : Boolean := True;
    status : Clair.Status.Code;
  begin
    if self.slots /= null then
      for index in 1 .. self.initialized_count loop
        if Sonbal.Process_Execution.is_initialized
          (self.slots(index).process)
        then
          status := Sonbal.Process_Execution.finalize
            (self.slots(index).process);
          ok := status = Clair.Status.OK and then ok;
        end if;
      end loop;
    end if;

    if not ok then
      return Clair.Status.INTERNAL_ERROR;
    end if;

    if self.slots /= null then
      for index in self.slots'range loop
        clear_slot (self.slots(index));
      end loop;
      free_slots (self.slots);
    end if;
    self.capacity := 0;
    self.terminal_limit := 0;
    self.initialized_count := 0;
    self.loop_context := null;
    self.workspace_tokens := null;
    self.admission := null;
    self.handler.owner := null;
    self.initialized := False;
    self.shutting_down := False;
    self.instance_id := (others => <>);
    self.next_sequence := 1;
    clear_trace (self);
    return Clair.Status.OK;
  end cleanup_partial;

  function initialize
    (self       : aliased in out Context;
     event_loop : aliased in out Clair.Event_Loop.Context;
     workspace_tokens : aliased in out Sonbal.Workspace_Tokens.Context;
     admission  : aliased in out Sonbal.Process_Admission.Context;
     max_jobs   : Sonbal.Configuration.Work_Slot_Count)
  return Clair.Status.Code
  is
    status : Clair.Status.Code;
    cleanup_status : Clair.Status.Code;
    next_instance : Job_Instance_Identifier;
    trace_requested : constant Boolean :=
      Sonbal.Configuration.diagnostic_trace_enabled;
  begin
    if self.initialized or else self.slots /= null or else
       not Sonbal.Workspace_Tokens.is_initialized(workspace_tokens) or else
       not Sonbal.Process_Admission.is_initialized(admission)
    then
      return Clair.Status.INVALID_STATE;
    end if;

    status := make_instance_id(next_instance);
    if status /= Clair.Status.OK then
      return status;
    end if;

    begin
      self.slots :=
        new Job_Slot_Array (1 .. 2 * Positive(max_jobs));
    exception
      when Storage_Error =>
        return Clair.Status.OUT_OF_MEMORY;
    end;

    self.capacity := 2 * Natural(max_jobs);
    self.terminal_limit := Natural(max_jobs);
    self.instance_id := next_instance;
    configure_trace (self, trace_requested, trace_requested);
    self.loop_context := event_loop'unchecked_access;
    self.workspace_tokens := workspace_tokens'unchecked_access;
    self.admission := admission'unchecked_access;

    for index in 1 .. self.capacity loop
      status := Sonbal.Process_Execution.initialize
        (self.slots(index).process, event_loop);
      if status /= Clair.Status.OK then
        cleanup_status := cleanup_partial(self);
        return
          (if cleanup_status = Clair.Status.OK then status else cleanup_status);
      end if;
      self.initialized_count := index;
    end loop;

    self.handler.owner := self'unchecked_access;
    self.initialized := True;
    return Clair.Status.OK;
  exception
    when others =>
      cleanup_status := cleanup_partial(self);
      return
        (if cleanup_status = Clair.Status.OK
         then Clair.Status.INTERNAL_ERROR
         else cleanup_status);
  end initialize;

  procedure start
    (self       : aliased in out Context;
     workspace_token : String;
     argv       : Sonbal.Process_Arguments.Arguments;
     resolution : Clair.Process.Execution.Executable_Resolution;
     cwd        : String;
     timeout_ms : Natural;
     result     : out Start_Result)
  is
    index          : Natural := 0;
    status         : Clair.Status.Code;
    retry_status   : Clair.Status.Code;
    settle_status  : Clair.Status.Code;
    start_state    : Sonbal.Process_Execution.Workspace_Start_State;
    next_job_id    : Job_Identifier;
    initial_cursor : Job_Cursor;
    trace_correlation : Interfaces.Unsigned_64 := 0;

    procedure trace_response is
    begin
      result.diagnostic_correlation := trace_correlation;
      record_trace
        (self,
         Trace_Start_Response,
         trace_correlation,
         trace_outcome_of (result.state));
    end trace_response;
  begin
    result := (others => <>);
    trace_correlation := allocate_trace_correlation (self);
    record_trace (self, Trace_Start_Request, trace_correlation);
    if not self.initialized or else self.shutting_down or else
       self.slots = null or else self.workspace_tokens = null or else
       self.admission = null or else
       self.next_sequence = Interfaces.Unsigned_64'Last
    then
      result.state := Start_Execution_Failed;
      trace_response;
      return;
    end if;

    index := select_start_slot(self);
    if index = 0 or else
       self.slots(index).state not in Slot_Empty | Slot_Terminal
    then
      self.shutting_down := True;
      result.state := Start_Execution_Failed;
      trace_response;
      return;
    end if;

    status := make_job_id(self, self.next_sequence, next_job_id);
    if status /= Clair.Status.OK or else
       not make_cursor(next_job_id, 0, 0, initial_cursor)
    then
      result.state := Start_Execution_Failed;
      trace_response;
      return;
    end if;

    status := Sonbal.Process_Execution.start_workspace
      (self       => self.slots(index).process,
       workspace_tokens       => self.workspace_tokens.all,
       admission  => self.admission.all,
       workspace_token => workspace_token,
       argv       => argv,
       resolution => resolution,
       cwd        => cwd,
       timeout_ms => timeout_ms,
       handler    => self.handler'unchecked_access,
       state      => start_state);

    if Sonbal.Process_Execution.is_active(self.slots(index).process) then
      record_trace
        (self, Trace_Launch_Accepted, trace_correlation, Trace_Running);
      if self.slots(index).state = Slot_Terminal then
        evict_terminal_slot (self, Positive (index));
      end if;
      self.slots(index).job_id := next_job_id;
      self.slots(index).sequence := self.next_sequence;
      self.slots(index).trace_correlation := trace_correlation;
      self.next_sequence := self.next_sequence + 1;
      self.slots(index).state := Slot_Running;

      if status /= Clair.Status.OK then
        for attempt in 1 .. MAXIMUM_CLEANUP_RETRIES loop
          retry_status :=
            Sonbal.Process_Execution.retry(self.slots(index).process);
          status := retry_status;
          exit when retry_status = Clair.Status.OK;
        end loop;
      end if;

      if status = Clair.Status.OK then
        result.state := Start_Running;
        result.job_id := self.slots(index).job_id;
        result.cursor := initial_cursor;
        trace_response;
        return;
      end if;

      self.slots(index).state := Slot_Cancelling;
      self.shutting_down := True;
      for attempt in 1 .. MAXIMUM_CLEANUP_RETRIES loop
        status := Sonbal.Process_Execution.cancel(self.slots(index).process);
        exit when status = Clair.Status.OK;
        retry_status := Sonbal.Process_Execution.retry
          (self.slots(index).process);
        exit when retry_status /= Clair.Status.OK and then
          retry_status /= Clair.Status.INVALID_STATE;
      end loop;
      result.state := Start_Execution_Failed;
      trace_response;
      return;
    end if;

    if Sonbal.Process_Execution.has_runtime_resources
      (self.slots(index).process)
    then
      self.shutting_down := True;
      for attempt in 1 .. MAXIMUM_CLEANUP_RETRIES loop
        settle_status := Sonbal.Process_Execution.settle_idle_resources
          (self.slots(index).process);
        exit when settle_status = Clair.Status.OK;
      end loop;
      result.state := Start_Execution_Failed;
      trace_response;
      return;
    end if;

    if status /= Clair.Status.OK then
      result.state := Start_Execution_Failed;
      trace_response;
      return;
    end if;

    case start_state is
      when Sonbal.Process_Execution.Workspace_Start_Execution_Busy =>
        result.state := Start_Execution_Busy;
      when Sonbal.Process_Execution.Workspace_Start_Stale_Token =>
        result.state := Start_Stale_Workspace_Token;
      when Sonbal.Process_Execution.Workspace_Start_Outside_Workspace =>
        result.state := Start_Outside_Workspace;
      when Sonbal.Process_Execution.Workspace_Start_Running |
           Sonbal.Process_Execution.Workspace_Start_Failed =>
        result.state := Start_Execution_Failed;
    end case;
    trace_response;
  exception
    when others =>
      self.shutting_down := True;
      if self.slots /= null and then index in 1 .. self.capacity then
        if Sonbal.Process_Execution.is_active(self.slots(index).process) then
          self.slots(index).state := Slot_Cancelling;
          for attempt in 1 .. MAXIMUM_CLEANUP_RETRIES loop
            status := Sonbal.Process_Execution.cancel
              (self.slots(index).process);
            exit when status = Clair.Status.OK;
            retry_status := Sonbal.Process_Execution.retry
              (self.slots(index).process);
            exit when retry_status /= Clair.Status.OK and then
              retry_status /= Clair.Status.INVALID_STATE;
          end loop;
        elsif Sonbal.Process_Execution.has_runtime_resources
          (self.slots(index).process)
        then
          for attempt in 1 .. MAXIMUM_CLEANUP_RETRIES loop
            settle_status := Sonbal.Process_Execution.settle_idle_resources
              (self.slots(index).process);
            exit when settle_status = Clair.Status.OK;
          end loop;
        end if;
      end if;
      result := (others => <>);
      result.state := Start_Execution_Failed;
      trace_response;
  end start;

  procedure copy_poll_stream
    (source    : Retained_Buffer_Access;
     retained  : Natural;
     offset    : Natural;
     truncated : Boolean;
     result    : out Poll_Stream;
     next      : out Natural)
  is
    amount : constant Natural :=
      Natural'Min(POLL_STREAM_BYTES, retained - offset);
  begin
    result := (others => <>);
    result.truncated := truncated;
    if amount > 0 then
      if source = null then
        raise Program_Error with "missing retained process stream";
      end if;
      result.data
        (result.data'first ..
         result.data'first +
           System.Storage_Elements.Storage_Offset(amount - 1)) :=
        source.all
          (source.all'first + System.Storage_Elements.Storage_Offset(offset) ..
           source.all'first +
             System.Storage_Elements.Storage_Offset(offset + amount - 1));
      result.length := amount;
    end if;
    next := offset + amount;
  end copy_poll_stream;

  function observe_poll_stream
    (process         : Sonbal.Process_Execution.Operation;
     standard_output : Boolean;
     offset          : Natural;
     result          : out Poll_Stream;
     next            : out Natural)
  return Clair.Status.Code
  is
    retained  : Natural := 0;
    copied    : Natural := 0;
    truncated : Boolean := False;
    status    : Clair.Status.Code;
  begin
    result := (others => <>);
    next := offset;

    if standard_output then
      status := Sonbal.Process_Execution.observe_standard_output
        (self      => process,
         offset    => offset,
         buffer    => result.data,
         length    => retained,
         copied    => copied,
         truncated => truncated);
    else
      status := Sonbal.Process_Execution.observe_standard_error
        (self      => process,
         offset    => offset,
         buffer    => result.data,
         length    => retained,
         copied    => copied,
         truncated => truncated);
    end if;

    if status /= Clair.Status.OK then
      return status;
    elsif retained > RETAINED_STREAM_BYTES or else
          offset > retained or else
          copied > POLL_STREAM_BYTES or else
          copied > retained - offset
    then
      return Clair.Status.CONTRACT_VIOLATION;
    end if;

    result.length := copied;
    result.truncated := truncated;
    next := offset + copied;
    return Clair.Status.OK;
  end observe_poll_stream;

  procedure poll
    (self   : in out Context;
     job_id : String;
     cursor : String;
     result : out Poll_Result)
  is
    index         : Natural;
    stdout_offset : Natural;
    stderr_offset : Natural;
    next_stdout   : Natural;
    next_stderr   : Natural;
    status        : Clair.Status.Code;
    trace_correlation : Interfaces.Unsigned_64 := 0;

    procedure trace_response is
    begin
      result.diagnostic_correlation := trace_correlation;
      record_trace
        (self,
         Trace_Poll_Response,
         trace_correlation,
         trace_outcome_of (result.state));
    end trace_response;
  begin
    result := (others => <>);
    if not self.initialized or else self.slots = null then
      return;
    end if;

    index := find_job(self, job_id);
    if index /= 0 then
      trace_correlation := self.slots(index).trace_correlation;
    end if;
    record_trace (self, Trace_Poll_Request, trace_correlation);
    if index = 0 then
      case classify_missing_job(self, job_id) is
        when Missing_Expired =>
          result.state := Poll_Expired;
        when Missing_Stale_Instance =>
          result.state := Poll_Stale_Instance;
        when Missing_Not_Found =>
          result.state := Poll_Not_Found;
      end case;
      trace_response;
      return;
    end if;

    result.job_id := self.slots(index).job_id;
    if not parse_cursor
      (self.slots(index).job_id,
       cursor,
       stdout_offset,
       stderr_offset)
    then
      result.state := Poll_Invalid_Cursor;
      trace_response;
      return;
    end if;

    if self.slots(index).state in Slot_Running | Slot_Cancelling then
      if not Sonbal.Process_Execution.is_active(self.slots(index).process) then
        self.shutting_down := True;
        result.state := Poll_Execution_Failed;
        trace_response;
        return;
      end if;

      status := observe_poll_stream
        (process         => self.slots(index).process,
         standard_output => True,
         offset          => stdout_offset,
         result          => result.stdout,
         next            => next_stdout);
      if status = Clair.Status.INVALID_ARGUMENT then
        result.stdout := (others => <>);
        result.state := Poll_Invalid_Cursor;
        trace_response;
        return;
      elsif status /= Clair.Status.OK then
        self.shutting_down := True;
        result := (others => <>);
        result.state := Poll_Execution_Failed;
        trace_response;
        return;
      end if;

      status := observe_poll_stream
        (process         => self.slots(index).process,
         standard_output => False,
         offset          => stderr_offset,
         result          => result.stderr,
         next            => next_stderr);
      if status = Clair.Status.INVALID_ARGUMENT then
        result.stdout := (others => <>);
        result.stderr := (others => <>);
        result.state := Poll_Invalid_Cursor;
        trace_response;
        return;
      elsif status /= Clair.Status.OK then
        self.shutting_down := True;
        result := (others => <>);
        result.state := Poll_Execution_Failed;
        trace_response;
        return;
      end if;

      result.state := Poll_Running;
      if not make_cursor
        (self.slots(index).job_id,
         next_stdout,
         next_stderr,
         result.next_cursor)
      then
        self.shutting_down := True;
        result := (others => <>);
        result.state := Poll_Execution_Failed;
      end if;
      trace_response;
      return;
    elsif self.slots(index).state /= Slot_Terminal or else
          stdout_offset > self.slots(index).stdout_length or else
          stderr_offset > self.slots(index).stderr_length
    then
      result.state := Poll_Invalid_Cursor;
      trace_response;
      return;
    end if;

    result.state := Poll_Terminal;
    result.terminal := self.slots(index).terminal;
    result.has_exit_code := self.slots(index).has_exit_code;
    result.exit_code := self.slots(index).exit_code;
    result.has_launch_stage := self.slots(index).has_launch_stage;
    result.launch_stage := self.slots(index).launch_stage;
    result.has_infrastructure_stage :=
      self.slots(index).has_infrastructure_stage;
    result.infrastructure_stage := self.slots(index).infrastructure_stage;
    result.has_ownership_stage := self.slots(index).has_ownership_stage;
    result.ownership_stage := self.slots(index).ownership_stage;

    copy_poll_stream
      (self.slots(index).stdout_data,
       self.slots(index).stdout_length,
       stdout_offset,
       self.slots(index).stdout_truncated,
       result.stdout,
       next_stdout);
    copy_poll_stream
      (self.slots(index).stderr_data,
       self.slots(index).stderr_length,
       stderr_offset,
       self.slots(index).stderr_truncated,
       result.stderr,
       next_stderr);

    if not make_cursor
      (self.slots(index).job_id,
       next_stdout,
       next_stderr,
       result.next_cursor)
    then
      self.shutting_down := True;
      result := (others => <>);
      result.state := Poll_Execution_Failed;
    end if;
    trace_response;
  exception
    when others =>
      self.shutting_down := True;
      result := (others => <>);
      result.state := Poll_Execution_Failed;
      trace_response;
  end poll;

  function request_cancellation
    (slot : in out Job_Slot) return Boolean
  is
    status       : Clair.Status.Code;
    retry_status : Clair.Status.Code;
  begin
    if slot.state = Slot_Cancelling then
      if not Sonbal.Process_Execution.is_active(slot.process) then
        return False;
      end if;
      for attempt in 1 .. MAXIMUM_CLEANUP_RETRIES loop
        retry_status := Sonbal.Process_Execution.retry(slot.process);
        if retry_status in Clair.Status.OK | Clair.Status.INVALID_STATE then
          return True;
        end if;
      end loop;
      return False;
    elsif slot.state /= Slot_Running or else
          not Sonbal.Process_Execution.is_active(slot.process)
    then
      return False;
    end if;

    for attempt in 1 .. MAXIMUM_CLEANUP_RETRIES loop
      status := Sonbal.Process_Execution.cancel(slot.process);
      if status = Clair.Status.OK then
        slot.state := Slot_Cancelling;
        return True;
      end if;

      retry_status := Sonbal.Process_Execution.retry(slot.process);
      if retry_status /= Clair.Status.OK and then
         retry_status /= Clair.Status.INVALID_STATE
      then
        return False;
      end if;
    end loop;
    return False;
  end request_cancellation;

  procedure cancel
    (self   : aliased in out Context;
     job_id : String;
     result : out Cancel_Result)
  is
    index : Natural;
    trace_correlation : Interfaces.Unsigned_64 := 0;

    procedure trace_response is
    begin
      result.diagnostic_correlation := trace_correlation;
      record_trace
        (self,
         Trace_Cancel_Response,
         trace_correlation,
         trace_outcome_of (result.state));
    end trace_response;
  begin
    result := (others => <>);
    if not self.initialized or else self.slots = null then
      result.state := Cancel_Not_Found;
      return;
    end if;

    index := find_job(self, job_id);
    if index /= 0 then
      trace_correlation := self.slots(index).trace_correlation;
    end if;
    record_trace (self, Trace_Cancel_Request, trace_correlation);
    if index = 0 then
      case classify_missing_job(self, job_id) is
        when Missing_Expired =>
          result.state := Cancel_Expired;
        when Missing_Stale_Instance =>
          result.state := Cancel_Stale_Instance;
        when Missing_Not_Found =>
          result.state := Cancel_Not_Found;
      end case;
      trace_response;
      return;
    end if;

    result.job_id := self.slots(index).job_id;
    case self.slots(index).state is
      when Slot_Running =>
        if request_cancellation(self.slots(index)) then
          result.state := Cancel_Cancelling;
        else
          result.state := Cancel_Execution_Failed;
        end if;
      when Slot_Cancelling =>
        result.state := Cancel_Cancelling;
      when Slot_Terminal =>
        result.state := Cancel_Already_Terminal;
      when Slot_Empty =>
        result.state := Cancel_Not_Found;
    end case;
    trace_response;
  exception
    when others =>
      result := (others => <>);
      result.state := Cancel_Execution_Failed;
      trace_response;
  end cancel;

  procedure mark_start_response_ready
    (self   : in out Context;
     result : Start_Result)
  is
  begin
    record_trace
      (self,
       Trace_Start_Response_Ready,
       result.diagnostic_correlation,
       trace_outcome_of (result.state));
  end mark_start_response_ready;

  procedure mark_poll_response_ready
    (self   : in out Context;
     result : Poll_Result)
  is
  begin
    record_trace
      (self,
       Trace_Poll_Response_Ready,
       result.diagnostic_correlation,
       trace_outcome_of (result.state));
  end mark_poll_response_ready;

  procedure mark_cancel_response_ready
    (self   : in out Context;
     result : Cancel_Result)
  is
  begin
    record_trace
      (self,
       Trace_Cancel_Response_Ready,
       result.diagnostic_correlation,
       trace_outcome_of (result.state));
  end mark_cancel_response_ready;

  function begin_shutdown
    (self : aliased in out Context) return Clair.Status.Code
  is
    ok : Boolean := True;
  begin
    if not self.initialized or else self.slots = null then
      return Clair.Status.INVALID_STATE;
    end if;

    self.shutting_down := True;
    for index in 1 .. self.capacity loop
      if self.slots(index).state in Slot_Running | Slot_Cancelling then
        if Sonbal.Process_Execution.is_active(self.slots(index).process) then
          ok := request_cancellation(self.slots(index)) and then ok;
        else
          ok := False;
        end if;
      elsif not Sonbal.Process_Execution.is_active
        (self.slots(index).process) and then
        Sonbal.Process_Execution.has_runtime_resources
          (self.slots(index).process)
      then
        ok := Sonbal.Process_Execution.settle_idle_resources
          (self.slots(index).process) = Clair.Status.OK and then ok;
      end if;
    end loop;
    return (if ok then Clair.Status.OK else Clair.Status.INTERNAL_ERROR);
  exception
    when others =>
      return Clair.Status.INTERNAL_ERROR;
  end begin_shutdown;

  function is_idle (self : Context) return Boolean is
  begin
    if not self.initialized or else self.slots = null then
      return False;
    end if;

    for index in 1 .. self.capacity loop
      if Sonbal.Process_Execution.is_active(self.slots(index).process) or else
         Sonbal.Process_Execution.has_runtime_resources
           (self.slots(index).process) or else
         self.slots(index).state in Slot_Running | Slot_Cancelling
      then
        return False;
      end if;
    end loop;
    return True;
  end is_idle;

  function is_initialized (self : Context) return Boolean is
    (self.initialized);

  function finalize
    (self : aliased in out Context) return Clair.Status.Code
  is
    status : Clair.Status.Code;
    ok     : Boolean := True;
  begin
    if not self.initialized or else self.slots = null or else
       not is_idle(self)
    then
      return Clair.Status.INVALID_STATE;
    end if;

    for index in 1 .. self.capacity loop
      if Sonbal.Process_Execution.is_initialized(self.slots(index).process) then
        status := Sonbal.Process_Execution.finalize(self.slots(index).process);
        ok := status = Clair.Status.OK and then ok;
      end if;
    end loop;

    if not ok then
      return Clair.Status.INTERNAL_ERROR;
    end if;

    for index in 1 .. self.capacity loop
      clear_slot (self.slots(index));
    end loop;
    free_slots (self.slots);
    self.capacity := 0;
    self.terminal_limit := 0;
    self.initialized_count := 0;
    self.loop_context := null;
    self.workspace_tokens := null;
    self.admission := null;
    self.handler.owner := null;
    self.initialized := False;
    self.shutting_down := False;
    self.instance_id := (others => <>);
    self.next_sequence := 1;
    clear_trace (self);
    return Clair.Status.OK;
  exception
    when others =>
      return Clair.Status.INTERNAL_ERROR;
  end finalize;

end Sonbal.Process_Jobs;
