-- ============================================================================
-- sonbal_mcp_json_tests.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Ada.Strings;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Interfaces;
with Sonbal.MCP.JSON;
with Sonbal_Test_Support;

package body Sonbal_MCP_JSON_Tests is
   use type Sonbal.MCP.JSON.Id_Kind;
   use type Sonbal.MCP.JSON.Parse_Status;
   use type Interfaces.Unsigned_64;
   use type Sonbal.MCP.JSON.Value_Kind;

   function Repeated
     (Item  : Character;
      Count : Natural) return String
   is
      Result : String (1 .. Count);
   begin
      for Index in Result'Range loop
         Result (Index) := Item;
      end loop;
      return Result;
   end Repeated;

   function Nested_Array (Depth : Positive) return String is
      Result : String (1 .. Depth * 2 + 1);
   begin
      for Index in 1 .. Depth loop
         Result (Index) := '[';
         Result (Result'Last - Index + 1) := ']';
      end loop;
      Result (Depth + 1) := '0';
      return Result;
   end Nested_Array;

   function Array_With_Items (Count : Positive) return String is
      Result : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.To_Unbounded_String ("[");
   begin
      for Index in 1 .. Count loop
         if Index > 1 then
            Ada.Strings.Unbounded.Append (Result, ",");
         end if;
         Ada.Strings.Unbounded.Append (Result, "0");
      end loop;
      Ada.Strings.Unbounded.Append (Result, "]");
      return Ada.Strings.Unbounded.To_String (Result);
   end Array_With_Items;

   function String_Array_With_Items
     (Count : Positive;
      Item  : String)
   return String
   is
      Result : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.To_Unbounded_String ("[");
   begin
      for Index in 1 .. Count loop
         if Index > 1 then
            Ada.Strings.Unbounded.Append (Result, ",");
         end if;
         Ada.Strings.Unbounded.Append (Result, """" & Item & """");
      end loop;
      Ada.Strings.Unbounded.Append (Result, "]");
      return Ada.Strings.Unbounded.To_String (Result);
   end String_Array_With_Items;

   function Object_With_Members (Count : Positive) return String is
      Result : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.To_Unbounded_String ("{");
   begin
      for Index in 1 .. Count loop
         if Index > 1 then
            Ada.Strings.Unbounded.Append (Result, ",");
         end if;
         Ada.Strings.Unbounded.Append
           (Result,
            """member_" &
              Ada.Strings.Fixed.Trim
                (Positive'Image (Index), Ada.Strings.Both) &
              """:0");
      end loop;
      Ada.Strings.Unbounded.Append (Result, "}");
      return Ada.Strings.Unbounded.To_String (Result);
   end Object_With_Members;

   function Parse_Status_For
     (Input : String) return Sonbal.MCP.JSON.Parse_Status
   is
      Message : Sonbal.MCP.JSON.Message;
      Status  : Sonbal.MCP.JSON.Parse_Status;
   begin
      Sonbal.MCP.JSON.Parse (Input, Message, Status);
      if Status = Sonbal.MCP.JSON.Parse_OK
        and then Message.Root_Kind = Sonbal.MCP.JSON.Absent
      then
         return Sonbal.MCP.JSON.Invalid_Syntax;
      end if;
      return Status;
   end Parse_Status_For;

   procedure Valid_Discover
     (Reporter : in out Clair.Test.Reporter.Context)
   is
      Input : constant String :=
        "{""jsonrpc"":""2.0"",""id"":""abc""," &
        """method"":""server/discover"",""params"":{" &
        """_meta"":{" &
        """io.modelcontextprotocol/protocolVersion"":""2026-07-28""," &
        """io.modelcontextprotocol/clientCapabilities"":{}," &
        """io.modelcontextprotocol/clientInfo"":{" &
        """name"":""client"",""version"":""1""}}}}";
      Message : Sonbal.MCP.JSON.Message;
      Status  : Sonbal.MCP.JSON.Parse_Status;
   begin
      Sonbal.MCP.JSON.Parse (Input, Message, Status);
      Sonbal_Test_Support.Check
        (Reporter, Status = Sonbal.MCP.JSON.Parse_OK, "valid JSON is parsed");
      Sonbal_Test_Support.Check
        (Reporter,
         Message.Root_Kind = Sonbal.MCP.JSON.Object_Value,
         "top-level object is retained");
      Sonbal_Test_Support.Check
        (Reporter,
         Message.Request_Id_Kind = Sonbal.MCP.JSON.String_Id,
         "string request ID is classified");
      Sonbal_Test_Support.Check
        (Reporter,
         Sonbal.MCP.JSON.Image (Message.Request_Id_Raw) = """abc""",
         "string request ID preserves its JSON spelling");
      Sonbal_Test_Support.Check
        (Reporter,
         Sonbal.MCP.JSON.Equals (Message.Method, "server/discover"),
         "discovery method is decoded");
      Sonbal_Test_Support.Check
        (Reporter,
         Message.Meta_Kind = Sonbal.MCP.JSON.Object_Value,
         "request metadata object is retained");
      Sonbal_Test_Support.Check
        (Reporter,
         Sonbal.MCP.JSON.Equals
           (Message.Meta_Protocol_Version, "2026-07-28"),
         "protocol version is decoded from request metadata");
      Sonbal_Test_Support.Check
        (Reporter,
         Sonbal.MCP.JSON.Image (Message.Meta_Protocol_Version_Raw) =
           """2026-07-28""",
         "protocol version preserves safe JSON spelling");
      Sonbal_Test_Support.Check
        (Reporter,
         Message.Meta_Client_Capabilities_Kind =
           Sonbal.MCP.JSON.Object_Value,
         "per-request client capabilities are retained");
      Sonbal_Test_Support.Check
        (Reporter,
         Sonbal.MCP.JSON.Equals (Message.Meta_Client_Name, "client"),
         "nested client name is retained");
      Sonbal_Test_Support.Check
        (Reporter,
         Sonbal.MCP.JSON.Equals (Message.Meta_Client_Version, "1"),
         "nested client version is retained");
   end Valid_Discover;

   procedure Number_Id
     (Reporter : in out Clair.Test.Reporter.Context)
   is
      Message : Sonbal.MCP.JSON.Message;
      Status  : Sonbal.MCP.JSON.Parse_Status;
   begin
      Sonbal.MCP.JSON.Parse
        ("{""jsonrpc"":""2.0"",""id"":-1.25e2," &
           """method"":""unknown""}",
         Message,
         Status);
      Sonbal_Test_Support.Check
        (Reporter, Status = Sonbal.MCP.JSON.Parse_OK, "number ID JSON parses");
      Sonbal_Test_Support.Check
        (Reporter,
         Message.Request_Id_Kind = Sonbal.MCP.JSON.Number_Id,
         "number request ID is classified");
      Sonbal_Test_Support.Check
        (Reporter,
         Sonbal.MCP.JSON.Image (Message.Request_Id_Raw) = "-1.25e2",
         "number request ID preserves its JSON spelling");
   end Number_Id;

   procedure Escaped_Duplicate
     (Reporter : in out Clair.Test.Reporter.Context)
   is
      Status : constant Sonbal.MCP.JSON.Parse_Status :=
        Parse_Status_For ("{""name"":0,""\u006eame"":1}");
   begin
      Sonbal_Test_Support.Check
        (Reporter,
         Status = Sonbal.MCP.JSON.Duplicate_Member,
         "escaped duplicate member names are rejected");
   end Escaped_Duplicate;

   procedure Invalid_UTF8
     (Reporter : in out Clair.Test.Reporter.Context)
   is
      Input : constant String :=
        String'
          (1 => Character'Val (16#C0#),
           2 => Character'Val (16#AF#));
      Status : constant Sonbal.MCP.JSON.Parse_Status :=
        Parse_Status_For (Input);
   begin
      Sonbal_Test_Support.Check
        (Reporter,
         Status = Sonbal.MCP.JSON.Invalid_UTF8,
         "overlong UTF-8 is rejected before JSON parsing");
   end Invalid_UTF8;

   procedure Input_Boundary
     (Reporter : in out Clair.Test.Reporter.Context)
   is
      Status : Sonbal.MCP.JSON.Parse_Status;
   begin
      Status :=
        Parse_Status_For
          (Repeated (' ', Sonbal.MCP.JSON.Max_Input_Bytes - 1) & "0");
      Sonbal_Test_Support.Check
        (Reporter,
         Status = Sonbal.MCP.JSON.Parse_OK,
         "maximum parser input length is accepted");

      Status :=
        Parse_Status_For
          (Repeated (' ', Sonbal.MCP.JSON.Max_Input_Bytes) & "0");
      Sonbal_Test_Support.Check
        (Reporter,
         Status = Sonbal.MCP.JSON.Input_Too_Long,
         "one byte beyond the parser input limit is rejected");
   end Input_Boundary;

   procedure Malformed_Number
     (Reporter : in out Clair.Test.Reporter.Context)
   is
      Status : constant Sonbal.MCP.JSON.Parse_Status :=
        Parse_Status_For ("01");
   begin
      Sonbal_Test_Support.Check
        (Reporter,
         Status = Sonbal.MCP.JSON.Invalid_Syntax,
         "JSON number with a leading zero is rejected");
   end Malformed_Number;

   procedure Depth_Boundary
     (Reporter : in out Clair.Test.Reporter.Context)
   is
      Status  : Sonbal.MCP.JSON.Parse_Status;
   begin
      Status :=
        Parse_Status_For
          (Nested_Array (Sonbal.MCP.JSON.Max_Depth - 1));
      Sonbal_Test_Support.Check
        (Reporter,
         Status = Sonbal.MCP.JSON.Parse_OK,
         "maximum supported value depth is accepted");

      Status :=
        Parse_Status_For (Nested_Array (Sonbal.MCP.JSON.Max_Depth));
      Sonbal_Test_Support.Check
        (Reporter,
         Status = Sonbal.MCP.JSON.Too_Deep,
         "one value beyond the depth limit is rejected");
   end Depth_Boundary;

   procedure String_Boundary
     (Reporter : in out Clair.Test.Reporter.Context)
   is
      Status  : Sonbal.MCP.JSON.Parse_Status;
   begin
      Status :=
        Parse_Status_For
          ("""" &
             Repeated ('a', Sonbal.MCP.JSON.Max_Decoded_String_Bytes) &
             """");
      Sonbal_Test_Support.Check
        (Reporter,
         Status = Sonbal.MCP.JSON.Parse_OK,
         "maximum decoded string length is accepted");

      Status :=
        Parse_Status_For
          ("""" &
             Repeated ('a', Sonbal.MCP.JSON.Max_Decoded_String_Bytes + 1) &
             """");
      Sonbal_Test_Support.Check
        (Reporter,
         Status = Sonbal.MCP.JSON.String_Too_Long,
         "one byte beyond the string limit is rejected");
   end String_Boundary;

   procedure Member_Name_Boundary
     (Reporter : in out Clair.Test.Reporter.Context)
   is
      Status : Sonbal.MCP.JSON.Parse_Status;
   begin
      Status :=
        Parse_Status_For
          ("{""" &
             Repeated ('a', Sonbal.MCP.JSON.Max_Member_Name_Bytes) &
             """:0}");
      Sonbal_Test_Support.Check
        (Reporter,
         Status = Sonbal.MCP.JSON.Parse_OK,
         "maximum decoded member name length is accepted");

      Status :=
        Parse_Status_For
          ("{""" &
             Repeated ('a', Sonbal.MCP.JSON.Max_Member_Name_Bytes + 1) &
             """:0}");
      Sonbal_Test_Support.Check
        (Reporter,
         Status = Sonbal.MCP.JSON.String_Too_Long,
         "one byte beyond the member name limit is rejected");
   end Member_Name_Boundary;

   procedure Request_Id_Boundary
     (Reporter : in out Clair.Test.Reporter.Context)
   is
      Message : Sonbal.MCP.JSON.Message;
      Status  : Sonbal.MCP.JSON.Parse_Status;
   begin
      Sonbal.MCP.JSON.Parse
        ("{""id"":""" &
           Repeated ('a', Sonbal.MCP.JSON.Max_Request_Id_Bytes - 2) &
           """}",
         Message,
         Status);
      Sonbal_Test_Support.Check
        (Reporter,
         Status = Sonbal.MCP.JSON.Parse_OK
           and then Message.Request_Id_Kind = Sonbal.MCP.JSON.String_Id,
         "maximum request ID spelling length is accepted");

      Sonbal.MCP.JSON.Parse
        ("{""id"":""" &
           Repeated ('a', Sonbal.MCP.JSON.Max_Request_Id_Bytes - 1) &
           """}",
         Message,
         Status);
      Sonbal_Test_Support.Check
        (Reporter,
         Status = Sonbal.MCP.JSON.Parse_OK
           and then Message.Request_Id_Kind = Sonbal.MCP.JSON.Invalid_Id,
         "one byte beyond the request ID spelling limit is classified invalid");
   end Request_Id_Boundary;

   procedure Number_Boundary
     (Reporter : in out Clair.Test.Reporter.Context)
   is
      Status  : Sonbal.MCP.JSON.Parse_Status;
   begin
      Status :=
        Parse_Status_For
          (Repeated ('1', Sonbal.MCP.JSON.Max_Number_Bytes));
      Sonbal_Test_Support.Check
        (Reporter,
         Status = Sonbal.MCP.JSON.Parse_OK,
         "maximum JSON number length is accepted");

      Status :=
        Parse_Status_For
          (Repeated ('1', Sonbal.MCP.JSON.Max_Number_Bytes + 1));
      Sonbal_Test_Support.Check
        (Reporter,
         Status = Sonbal.MCP.JSON.Number_Too_Long,
         "one byte beyond the number limit is rejected");
   end Number_Boundary;

   procedure Member_Boundary
     (Reporter : in out Clair.Test.Reporter.Context)
   is
      Status  : Sonbal.MCP.JSON.Parse_Status;
   begin
      Status :=
        Parse_Status_For
          (Object_With_Members (Sonbal.MCP.JSON.Max_Members_Per_Object));
      Sonbal_Test_Support.Check
        (Reporter,
         Status = Sonbal.MCP.JSON.Parse_OK,
         "maximum members per object are accepted");

      Status :=
        Parse_Status_For
          (Object_With_Members
             (Sonbal.MCP.JSON.Max_Members_Per_Object + 1));
      Sonbal_Test_Support.Check
        (Reporter,
         Status = Sonbal.MCP.JSON.Too_Many_Members,
         "one object member beyond the limit is rejected");
   end Member_Boundary;

   procedure Token_Boundary
     (Reporter : in out Clair.Test.Reporter.Context)
   is
      Status  : Sonbal.MCP.JSON.Parse_Status;
   begin
      Status :=
        Parse_Status_For
          (Array_With_Items (Sonbal.MCP.JSON.Max_Tokens - 1));
      Sonbal_Test_Support.Check
        (Reporter,
         Status = Sonbal.MCP.JSON.Parse_OK,
         "maximum token budget is accepted");

      Status :=
        Parse_Status_For (Array_With_Items (Sonbal.MCP.JSON.Max_Tokens));
      Sonbal_Test_Support.Check
        (Reporter,
         Status = Sonbal.MCP.JSON.Too_Many_Tokens,
         "one token beyond the budget is rejected");
   end Token_Boundary;

   procedure Top_Level_Array
     (Reporter : in out Clair.Test.Reporter.Context)
   is
      Message : Sonbal.MCP.JSON.Message;
      Status  : Sonbal.MCP.JSON.Parse_Status;
   begin
      Sonbal.MCP.JSON.Parse ("[]", Message, Status);
      Sonbal_Test_Support.Check
        (Reporter,
         Status = Sonbal.MCP.JSON.Parse_OK,
         "valid top-level array remains a JSON value");
      Sonbal_Test_Support.Check
        (Reporter,
         Message.Root_Kind = Sonbal.MCP.JSON.Array_Value,
         "top-level array is classified for JSON-RPC rejection");
   end Top_Level_Array;

  procedure bounded_natural_numbers
    (reporter : in out Clair.Test.Reporter.Context)
  is
    procedure check_value
      (input    : String;
       minimum  : Natural;
       maximum  : Natural;
       expected : Natural;
       label    : String)
    is
      value : Natural := Natural'last;
    begin
      Sonbal_Test_Support.check
        (reporter,
         Sonbal.MCP.JSON.parse_bounded_natural
           (input, minimum, maximum, value),
         label & " is accepted");
      Sonbal_Test_Support.check
        (reporter,
         value = expected,
         label & " preserves its exact mathematical value");
    end check_value;

    procedure check_rejected
      (input   : String;
       minimum : Natural;
       maximum : Natural;
       label   : String)
    is
      value : Natural := Natural'last;
    begin
      Sonbal_Test_Support.check
        (reporter,
         not Sonbal.MCP.JSON.parse_bounded_natural
           (input, minimum, maximum, value),
         label & " is rejected");
      Sonbal_Test_Support.check
        (reporter,
         value = 0,
         label & " resets the result");
    end check_rejected;
  begin
    check_value ("0", 0, 1_000, 0, "zero");
    check_value
      ("-0.0e999999999999999999",
       0,
       1_000,
       0,
       "negative zero with a large exponent");
    check_value ("1", 1, 32_767, 1, "integer spelling");
    check_value ("1.0", 1, 32_767, 1, "decimal integer spelling");
    check_value
      ("1e3", 0, 1_000, 1_000, "positive exponent spelling");
    check_value
      ("3.2767e4", 1, 32_767, 32_767, "maximum geometry spelling");
    check_value
      ("1.6384e4", 1, 16_384, 16_384, "maximum read-size spelling");
    check_value
      ("1.2e1", 1, 32_767, 12, "fraction shifted to an integer");
    check_value
      ("100e-2",
       1,
       32_767,
       1,
       "negative exponent with exact trailing zeros");

    check_rejected ("1.5", 0, 32_767, "fractional value");
    check_rejected ("-1", 0, 32_767, "negative value");
    check_rejected
      ("32768", 1, 32_767, "one-unit geometry overflow");
    check_rejected ("0", 1, 32_767, "minimum-range underflow");
    check_rejected
      ("1e999999999999999999",
       0,
       32_767,
       "huge positive exponent");
    check_rejected
      ("1e-999999999999999999",
       0,
       32_767,
       "huge negative exponent");
    check_rejected ("01", 0, 32_767, "invalid leading zero");
    check_rejected ("1.", 0, 32_767, "missing fraction digit");
    check_rejected ("1", 2, 1, "inverted range");
    check_rejected
      (Repeated ('1', Sonbal.MCP.JSON.Max_Number_Bytes + 1),
       0,
       32_767,
       "overlong number spelling");
  end bounded_natural_numbers;

  procedure run_process_arguments_projected
    (reporter : in out Clair.Test.Reporter.Context)
  is
    input : constant String :=
      "{""params"":{""arguments"":{" &
      """argv"":[""/bin/echo"",""h\u0069"",""""]," &
      """resolution"":""exact_path""," &
      """cwd"":""/tmp"",""timeout_ms"":1.2e3}}}";
    message : Sonbal.MCP.JSON.Message;
    status  : Sonbal.MCP.JSON.Parse_Status;
  begin
    Sonbal.MCP.JSON.parse (input, message, status);
    Sonbal_Test_Support.check
      (reporter,
       status = Sonbal.MCP.JSON.Parse_OK and then
         message.Arguments_Kind = Sonbal.MCP.JSON.Object_Value and then
         message.Arguments_Member_Count = 4 and then
         not message.arguments_has_unknown,
       "run_process argument object is projected without unknown fields");
    Sonbal_Test_Support.check
      (reporter,
       message.argument_argv_kind = Sonbal.MCP.JSON.Array_Value and then
         message.argument_argv.count = 3 and then
         message.argument_argv.total_bytes = 11 and then
         message.argument_argv.all_strings,
       "run_process argv shape and decoded byte total are retained");
    Sonbal_Test_Support.check
      (reporter,
       Sonbal.MCP.JSON.run_process_argument_at
         (message.argument_argv, 1) = "/bin/echo" and then
         Sonbal.MCP.JSON.run_process_argument_at
           (message.argument_argv, 2) = "hi" and then
         Sonbal.MCP.JSON.run_process_argument_at
           (message.argument_argv, 3) = "",
       "run_process argv strings are retained byte-exactly after JSON decode");
    Sonbal_Test_Support.check
      (reporter,
       message.argument_resolution_kind = Sonbal.MCP.JSON.String_Value and then
         Sonbal.MCP.JSON.equals
           (message.argument_resolution, "exact_path") and then
         message.argument_cwd_kind = Sonbal.MCP.JSON.String_Value and then
         Sonbal.MCP.JSON.image (message.argument_cwd) = "/tmp" and then
         message.argument_timeout_ms_kind =
           Sonbal.MCP.JSON.Number_Value and then
         Sonbal.MCP.JSON.image (message.argument_timeout_ms_raw) = "1.2e3",
       "run_process scalar arguments retain their decoded or raw forms");
  end run_process_arguments_projected;

  procedure run_process_projection_boundaries
    (reporter : in out Clair.Test.Reporter.Context)
  is
    message : Sonbal.MCP.JSON.Message;
    status  : Sonbal.MCP.JSON.Parse_Status;
  begin
    Sonbal.MCP.JSON.parse
      ("{""params"":{""arguments"":{" &
        """argv"":[""" &
       Repeated ('a', Sonbal.MCP.JSON.MAX_RUN_PROCESS_ARGUMENT_BYTES + 1) &
       """],""resolution"":""exact_path"",""cwd"":""/tmp""," &
       """timeout_ms"":1}}}",
       message,
       status);
    Sonbal_Test_Support.check
      (reporter,
       status = Sonbal.MCP.JSON.Parse_OK and then
         message.argument_argv.count = 1 and then
         message.argument_argv.slices(1).length =
           Sonbal.MCP.JSON.MAX_RUN_PROCESS_ARGUMENT_BYTES + 1,
       "one-byte argv overflow remains projectable for invalid-param mapping");

    Sonbal.MCP.JSON.parse
      ("{""params"":{""arguments"":{" &
        """argv"":" & String_Array_With_Items
         (Sonbal.MCP.JSON.MAX_RUN_PROCESS_ARGUMENT_COUNT + 1, "") &
       ",""resolution"":""exact_path"",""cwd"":""" &
       Repeated ('c', Sonbal.MCP.JSON.MAX_RUN_PROCESS_CWD_BYTES + 1) &
       """,""timeout_ms"":1}}}",
       message,
       status);
    Sonbal_Test_Support.check
      (reporter,
       status = Sonbal.MCP.JSON.Parse_OK and then
         message.argument_argv.count =
           Sonbal.MCP.JSON.MAX_RUN_PROCESS_ARGUMENT_COUNT + 1 and then
         message.argument_cwd.length =
           Sonbal.MCP.JSON.MAX_RUN_PROCESS_CWD_BYTES + 1,
       "one-unit count and cwd overflows remain bounded projections");
  end run_process_projection_boundaries;

  procedure large_unknown_param_is_not_projected
    (reporter : in out Clair.Test.Reporter.Context)
  is
    message : Sonbal.MCP.JSON.Message;
    status  : Sonbal.MCP.JSON.Parse_Status;
  begin
    Sonbal.MCP.JSON.parse
      ("{""params"":{""unexpected"":""" &
       Repeated ('x', Sonbal.MCP.JSON.Max_Decoded_String_Bytes + 1) &
       """}}",
       message,
       status);
    Sonbal_Test_Support.check
      (reporter,
       status = Sonbal.MCP.JSON.Parse_OK and then
         message.Params_Kind = Sonbal.MCP.JSON.Object_Value and then
         message.Params_Member_Count = 1 and then
         message.Params_Has_Unknown,
       "large unknown params are syntax-checked without projected text storage");
  end large_unknown_param_is_not_projected;

  procedure unknown_argument_is_marked
    (reporter : in out Clair.Test.Reporter.Context)
  is
    message : Sonbal.MCP.JSON.Message;
    status  : Sonbal.MCP.JSON.Parse_Status;
  begin
    Sonbal.MCP.JSON.parse
      ("{""params"":{""arguments"":{""unexpected"":1}}}",
       message,
       status);
    Sonbal_Test_Support.check
      (reporter,
       status = Sonbal.MCP.JSON.Parse_OK and then
         message.Arguments_Kind = Sonbal.MCP.JSON.Object_Value and then
         message.Arguments_Member_Count = 1 and then
         message.arguments_has_unknown,
       "unknown tool arguments are retained only as an unknown-member signal");
  end unknown_argument_is_marked;

  procedure bounded_unsigned_64_numbers
    (reporter : in out Clair.Test.Reporter.Context)
  is
    value   : Interfaces.Unsigned_64 := 0;
    success : Boolean;
  begin
    success := Sonbal.MCP.JSON.parse_bounded_unsigned_64
      ("9007199254740991",
       0,
       9_007_199_254_740_991,
       value);
    Sonbal_Test_Support.check
      (reporter,
       success and then value = 9_007_199_254_740_991,
       "unsigned-64 parser accepts the exact JSON-safe file offset maximum");

    success := Sonbal.MCP.JSON.parse_bounded_unsigned_64
      ("9007199254740992",
       0,
       9_007_199_254_740_991,
       value);
    Sonbal_Test_Support.check
      (reporter,
       not success and then value = 0,
       "unsigned-64 parser rejects one byte-offset unit above policy");

    success := Sonbal.MCP.JSON.parse_bounded_unsigned_64
      ("900719925474099100e-2",
       0,
       9_007_199_254_740_991,
       value);
    Sonbal_Test_Support.check
      (reporter,
       success and then value = 9_007_199_254_740_991,
       "unsigned-64 parser preserves exact integral JSON exponent spelling");

    success := Sonbal.MCP.JSON.parse_bounded_unsigned_64
      ("1.5",
       0,
       Interfaces.Unsigned_64'Last,
       value);
    Sonbal_Test_Support.check
      (reporter,
       not success and then value = 0,
       "unsigned-64 parser rejects non-integral JSON numbers");
  end bounded_unsigned_64_numbers;

   procedure Run (Reporter : in out Clair.Test.Reporter.Context) is
   begin
      Clair.Test.Reporter.Run_Scenario
        (Reporter, "valid discovery", Valid_Discover'Access);
      Clair.Test.Reporter.Run_Scenario
        (Reporter, "number request ID", Number_Id'Access);
      Clair.Test.Reporter.Run_Scenario
        (Reporter, "escaped duplicate", Escaped_Duplicate'Access);
      Clair.Test.Reporter.Run_Scenario
        (Reporter, "invalid UTF-8", Invalid_UTF8'Access);
      Clair.Test.Reporter.Run_Scenario
        (Reporter, "input boundary", Input_Boundary'Access);
      Clair.Test.Reporter.Run_Scenario
        (Reporter, "malformed number", Malformed_Number'Access);
      Clair.Test.Reporter.Run_Scenario
        (Reporter, "depth boundary", Depth_Boundary'Access);
      Clair.Test.Reporter.Run_Scenario
        (Reporter, "string boundary", String_Boundary'Access);
      Clair.Test.Reporter.Run_Scenario
        (Reporter, "member name boundary", Member_Name_Boundary'Access);
      Clair.Test.Reporter.Run_Scenario
        (Reporter, "request ID boundary", Request_Id_Boundary'Access);
      Clair.Test.Reporter.Run_Scenario
        (Reporter, "number boundary", Number_Boundary'Access);
      Clair.Test.Reporter.Run_Scenario
        (Reporter, "member boundary", Member_Boundary'Access);
      Clair.Test.Reporter.Run_Scenario
        (Reporter, "token boundary", Token_Boundary'Access);
      Clair.Test.Reporter.Run_Scenario
        (Reporter, "top-level array", Top_Level_Array'Access);
      Clair.Test.Reporter.Run_Scenario
        (Reporter, "bounded natural numbers", bounded_natural_numbers'access);
      Clair.Test.Reporter.Run_Scenario
        (Reporter,
         "bounded unsigned-64 numbers",
         bounded_unsigned_64_numbers'access);
      Clair.Test.Reporter.Run_Scenario
        (Reporter,
         "run_process arguments projected",
         run_process_arguments_projected'access);
      Clair.Test.Reporter.Run_Scenario
        (Reporter,
         "run_process projection boundaries",
         run_process_projection_boundaries'access);
      Clair.Test.Reporter.Run_Scenario
        (Reporter,
         "large unknown param is not projected",
         large_unknown_param_is_not_projected'access);
      Clair.Test.Reporter.Run_Scenario
        (Reporter, "unknown argument is marked", unknown_argument_is_marked'access);
   end Run;
end Sonbal_MCP_JSON_Tests;
