-- ============================================================================
-- sonbal-mcp-json.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

package body Sonbal.MCP.JSON is

  use type Interfaces.Unsigned_64;
  use type Sonbal.Process_Arguments.Append_State;
   function Image (Value : Text) return String is
   begin
      if Value.Length = 0 then
         return "";
      end if;

      return Value.Data (1 .. Value.Length);
   end Image;

   function Is_Empty (Value : Text) return Boolean is
     (Value.Length = 0);

   function Equals
     (Left  : Text;
      Right : String) return Boolean
   is
   begin
      return Left.Length = Right'Length
        and then
          (Left.Length = 0
           or else Left.Data (1 .. Left.Length) = Right);
   end Equals;

  function image (value : Run_Process_Text) return String is
  begin
    if value.length = 0 then
      return "";
    end if;

    return value.data (1 .. value.length);
  end image;

  function run_process_argument_at
    (value : Run_Process_Arguments;
     index : Positive)
  return String
  is
    item : constant Run_Process_Argument_Slice := value.slices(index);
  begin
    if item.length = 0 then
      return "";
    end if;

    return value.data (item.first .. item.first + item.length - 1);
  end run_process_argument_at;

  function project_run_process_arguments
    (value  : Run_Process_Arguments;
     result : out Sonbal.Process_Arguments.Arguments)
  return Boolean
  is
    projected      : Sonbal.Process_Arguments.Arguments;
    expected_first : Natural := value.data'First;
    total          : Natural := 0;
    appended       : Sonbal.Process_Arguments.Append_State;
  begin
    Sonbal.Process_Arguments.clear (result);
    Sonbal.Process_Arguments.clear (projected);

    if value.count not in 1 .. MAX_RUN_PROCESS_ARGUMENT_COUNT or else
       not value.all_strings or else
       value.total_bytes > MAX_RUN_PROCESS_ARGV_BYTES or else
       value.stored_bytes > MAX_RUN_PROCESS_ARGV_BYTES or else
       value.total_bytes /= value.stored_bytes
    then
      return False;
    end if;

    for index in 1 .. value.count loop
      declare
        item : constant Run_Process_Argument_Slice := value.slices (index);
      begin
        if item.length > MAX_RUN_PROCESS_ARGUMENT_BYTES then
          return False;
        elsif item.length = 0 then
          if index = 1 or else item.first /= 0 then
            return False;
          end if;
        elsif item.first /= expected_first or else
              item.first > value.stored_bytes or else
              item.length > value.stored_bytes - item.first + 1
        then
          return False;
        end if;

        appended := Sonbal.Process_Arguments.append
          (projected, run_process_argument_at (value, index));
        if appended /= Sonbal.Process_Arguments.Append_Accepted then
          return False;
        end if;

        if item.length > 0 then
          total := total + item.length;
          expected_first := expected_first + item.length;
        end if;
      end;
    end loop;

    if total /= value.total_bytes or else
       not Sonbal.Process_Arguments.is_valid (projected)
    then
      return False;
    end if;

    result := projected;
    return True;
  end project_run_process_arguments;

  function parse_bounded_unsigned_64
    (input   : String;
     minimum : Interfaces.Unsigned_64;
     maximum : Interfaces.Unsigned_64;
     value   : out Interfaces.Unsigned_64)
  return Boolean
  is
    exponent_cap : constant Natural := MAX_NUMBER_BYTES + 1;

    number_digits : String (1 .. MAX_NUMBER_BYTES)
                  := [others => Character'val (0)];

    position           : Integer := input'first;
    digit_count        : Natural := 0;
    fraction_digits    : Natural := 0;
    exponent           : Natural := 0;
    exponent_negative  : Boolean := False;
    negative           : Boolean := False;
    first_nonzero      : Natural := 0;
    integer_last       : Natural := 0;
    decimal_scale      : Integer := 0;

    function at_end return Boolean is
      (position > input'last);

    function current return Character is
      (input(position));

    function decimal_digit (item : Character) return Natural is
      (Character'pos (item) - Character'pos ('0'));

    function append_digit (item : Character) return Boolean is
    begin
      if digit_count = number_digits'length then
        return False;
      end if;

      digit_count := digit_count + 1;
      number_digits(digit_count) := item;
      return True;
    end append_digit;

    procedure consume_exponent_digit (item : Character) is
      digit : constant Natural := decimal_digit (item);
    begin
      if exponent >= exponent_cap then
        exponent := exponent_cap;
      elsif exponent > (exponent_cap - digit) / 10 then
        exponent := exponent_cap;
      else
        exponent := exponent * 10 + digit;
      end if;
    end consume_exponent_digit;

    function append_result_digit (item : Character) return Boolean is
      digit : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64(decimal_digit (item));
    begin
      if digit > maximum then
        return False;
      end if;

      if value > (maximum - digit) / 10 then
        return False;
      end if;

      value := value * 10 + digit;
      return True;
    end append_result_digit;

  begin
    value := 0;

    if input'length = 0 or else
       input'length > MAX_NUMBER_BYTES or else
       minimum > maximum
    then
      return False;
    end if;

    if current = '-' then
      negative := True;
      position := position + 1;
      if at_end then
        return False;
      end if;
    end if;

    if current = '0' then
      if not append_digit (current) then
        return False;
      end if;
      position := position + 1;

      if not at_end and then current in '0' .. '9' then
        return False;
      end if;
    elsif current in '1' .. '9' then
      while not at_end and then current in '0' .. '9' loop
        if not append_digit (current) then
          return False;
        end if;
        position := position + 1;
      end loop;
    else
      return False;
    end if;

    if not at_end and then current = '.' then
      position := position + 1;

      if at_end or else current not in '0' .. '9' then
        return False;
      end if;

      while not at_end and then current in '0' .. '9' loop
        if not append_digit (current) then
          return False;
        end if;
        fraction_digits := fraction_digits + 1;
        position := position + 1;
      end loop;
    end if;

    if not at_end and then (current = 'e' or else current = 'E') then
      position := position + 1;

      if at_end then
        return False;
      end if;

      if current = '+' or else current = '-' then
        exponent_negative := current = '-';
        position := position + 1;

        if at_end then
          return False;
        end if;
      end if;

      if current not in '0' .. '9' then
        return False;
      end if;

      while not at_end and then current in '0' .. '9' loop
        consume_exponent_digit (current);
        position := position + 1;
      end loop;
    end if;

    if not at_end then
      return False;
    end if;

    for index in 1 .. digit_count loop
      if number_digits(index) /= '0' then
        first_nonzero := index;
        exit;
      end if;
    end loop;

    if first_nonzero = 0 then
      return minimum = 0;
    end if;

    if negative then
      return False;
    end if;

    if exponent_negative then
      decimal_scale := -Integer(exponent) - Integer(fraction_digits);
    else
      decimal_scale := Integer(exponent) - Integer(fraction_digits);
    end if;

    if decimal_scale < 0 then
      declare
        removed_digits : constant Natural := Natural(-decimal_scale);
      begin
        if removed_digits >= digit_count then
          return False;
        end if;

        for index in digit_count - removed_digits + 1 .. digit_count loop
          if number_digits(index) /= '0' then
            return False;
          end if;
        end loop;

        integer_last := digit_count - removed_digits;
      end;
    else
      integer_last := digit_count;
    end if;

    for index in first_nonzero .. integer_last loop
      if not append_result_digit (number_digits(index)) then
        value := 0;
        return False;
      end if;
    end loop;

    while decimal_scale > 0 loop
      if value > maximum / 10 then
        value := 0;
        return False;
      end if;

      value := value * 10;
      decimal_scale := decimal_scale - 1;
    end loop;

    if value < minimum then
      value := 0;
      return False;
    end if;

    return True;
  end parse_bounded_unsigned_64;


  function parse_bounded_natural
    (input   : String;
     minimum : Natural;
     maximum : Natural;
     value   : out Natural)
  return Boolean
  is
    parsed : Interfaces.Unsigned_64 := 0;
  begin
    value := 0;
    if minimum > maximum or else
       not parse_bounded_unsigned_64
         (input,
          Interfaces.Unsigned_64(minimum),
          Interfaces.Unsigned_64(maximum),
          parsed)
    then
      return False;
    end if;

    value := Natural(parsed);
    return True;
  end parse_bounded_natural;

   procedure Parse
     (Input  : String;
      Result : out Message;
      Status : out Parse_Status)
   is
      type Object_Context is
        (Generic_Context,
         Ignored_Context,
         Root_Context,
         Params_Context,
         Meta_Context,
         Meta_Client_Info_Context,
         Arguments_Context,
         Run_Process_Text_Context,
         Run_Process_Argument_Context,
         Run_Process_Argv_Context);

      type Name_Text is record
         Data   : String (1 .. Max_Member_Name_Bytes) :=
           [others => Character'val (0)];
         Length : Natural range 0 .. Max_Member_Name_Bytes := 0;
      end record;

      type Name_Array is
        array (Positive range 1 .. Max_Members_Per_Object) of Name_Text;

      Last_Position               : constant Natural := Input'Length;
      Position                    : Natural := 1;
      Token_Count                 : Natural := 0;
      Run_Process_Argument_Buffer : Run_Process_Argument_Text;
      Failed                      : Boolean := False;
      Failure                     : Parse_Status := Parse_OK;

      procedure Fail (Kind : Parse_Status) is
      begin
         if not Failed then
            Failed := True;
            Failure := Kind;
         end if;
      end Fail;

      function At_End return Boolean is
        (Position > Last_Position);

      function Source_Index (Offset : Positive) return Integer is
        (Input'First + Integer (Offset - 1));

      function Item_At (Offset : Positive) return Character is
        (Input (Source_Index (Offset)));

      function Input_Slice
        (First : Positive;
         Last  : Positive) return String
      is
      begin
         return Input (Source_Index (First) .. Source_Index (Last));
      end Input_Slice;

      function Byte_At (Index : Natural) return Natural is
        (Character'Pos (Item_At (Index)));

      procedure Count_Token is
      begin
         if Token_Count = Max_Tokens then
            Fail (Too_Many_Tokens);
         else
            Token_Count := Token_Count + 1;
         end if;
      end Count_Token;

      procedure Skip_Whitespace is
      begin
         while not At_End loop
            case Item_At (Position) is
               when ' ' | Character'Val (9) | Character'Val (10) |
                 Character'Val (13) =>
                  Position := Position + 1;
               when others =>
                  return;
            end case;
         end loop;
      end Skip_Whitespace;

      function UTF8_Is_Valid return Boolean is
         Index : Natural := 1;
         Byte  : Natural;

         function Continuation (Index_Value : Natural) return Boolean is
           (Index_Value <= Last_Position
            and then Byte_At (Index_Value) in 16#80# .. 16#BF#);
      begin
         while Index <= Last_Position loop
            Byte := Byte_At (Index);

            if Byte <= 16#7F# then
               Index := Index + 1;
            elsif Byte in 16#C2# .. 16#DF# then
               if not Continuation (Index + 1) then
                  return False;
               end if;
               Index := Index + 2;
            elsif Byte = 16#E0# then
               if Index + 2 > Last_Position
                 or else Byte_At (Index + 1) not in 16#A0# .. 16#BF#
                 or else not Continuation (Index + 2)
               then
                  return False;
               end if;
               Index := Index + 3;
            elsif Byte in 16#E1# .. 16#EC#
              or else Byte in 16#EE# .. 16#EF#
            then
               if not Continuation (Index + 1)
                 or else not Continuation (Index + 2)
               then
                  return False;
               end if;
               Index := Index + 3;
            elsif Byte = 16#ED# then
               if Index + 2 > Last_Position
                 or else Byte_At (Index + 1) not in 16#80# .. 16#9F#
                 or else not Continuation (Index + 2)
               then
                  return False;
               end if;
               Index := Index + 3;
            elsif Byte = 16#F0# then
               if Index + 3 > Last_Position
                 or else Byte_At (Index + 1) not in 16#90# .. 16#BF#
                 or else not Continuation (Index + 2)
                 or else not Continuation (Index + 3)
               then
                  return False;
               end if;
               Index := Index + 4;
            elsif Byte in 16#F1# .. 16#F3# then
               if not Continuation (Index + 1)
                 or else not Continuation (Index + 2)
                 or else not Continuation (Index + 3)
               then
                  return False;
               end if;
               Index := Index + 4;
            elsif Byte = 16#F4# then
               if Index + 3 > Last_Position
                 or else Byte_At (Index + 1) not in 16#80# .. 16#8F#
                 or else not Continuation (Index + 2)
                 or else not Continuation (Index + 3)
               then
                  return False;
               end if;
               Index := Index + 4;
            else
               return False;
            end if;
         end loop;

         return True;
      end UTF8_Is_Valid;

      procedure Append
        (Data   : in out String;
         Length : in out Natural;
         Item   : Character)
      is
      begin
         if Length = Data'length then
            Fail (String_Too_Long);
         else
            Length := Length + 1;
            Data (Data'first + Length - 1) := Item;
         end if;
      end Append;

      procedure Append_Code_Point
        (Data   : in out String;
         Length : in out Natural;
         Code   : Natural)
      is
      begin
         if Code <= 16#7F# then
            Append (Data, Length, Character'val (Code));
         elsif Code <= 16#7FF# then
            Append
              (Data,
               Length,
               Character'val (16#C0# + Code / 16#40#));
            Append
              (Data,
               Length,
               Character'val (16#80# + Code mod 16#40#));
         elsif Code <= 16#FFFF# then
            Append
              (Data,
               Length,
               Character'val (16#E0# + Code / 16#1000#));
            Append
              (Data,
               Length,
               Character'val
                 (16#80# + (Code / 16#40#) mod 16#40#));
            Append
              (Data,
               Length,
               Character'val (16#80# + Code mod 16#40#));
         else
            Append
              (Data,
               Length,
               Character'val (16#F0# + Code / 16#40000#));
            Append
              (Data,
               Length,
               Character'val
                 (16#80# + (Code / 16#1000#) mod 16#40#));
            Append
              (Data,
               Length,
               Character'val
                 (16#80# + (Code / 16#40#) mod 16#40#));
            Append
              (Data,
               Length,
               Character'val (16#80# + Code mod 16#40#));
         end if;
      end Append_Code_Point;

      function Hex_Value (Item : Character) return Integer is
      begin
         case Item is
            when '0' .. '9' =>
               return Character'Pos (Item) - Character'Pos ('0');
            when 'a' .. 'f' =>
               return 10 + Character'Pos (Item) - Character'Pos ('a');
            when 'A' .. 'F' =>
               return 10 + Character'Pos (Item) - Character'Pos ('A');
            when others =>
               return -1;
         end case;
      end Hex_Value;

      function Read_Hex_Quad return Natural is
         Value : Natural := 0;
         Digit : Integer;
      begin
         if Position + 3 > Last_Position then
            Fail (Invalid_Syntax);
            return 0;
         end if;

         for Offset in 0 .. 3 loop
            Digit := Hex_Value (Item_At (Position + Offset));
            if Digit < 0 then
               Fail (Invalid_Syntax);
               return 0;
            end if;

            Value := Value * 16 + Natural (Digit);
         end loop;

         Position := Position + 4;
         return Value;
      end Read_Hex_Quad;

      procedure Parse_String_Data
        (Data      : in out String;
         Length    : in out Natural;
         Raw_First : out Natural;
         Raw_Last  : out Natural;
         Store     : Boolean := True)
      is
         Code      : Natural;
         Low       : Natural;
         Raw_Start : constant Natural := Position;
      begin
         Length := 0;
         Raw_First := 0;
         Raw_Last := 0;

         if At_End or else Item_At (Position) /= '"' then
            Fail (Invalid_Syntax);
            return;
         end if;

         Position := Position + 1;

         while not At_End loop
            if Item_At (Position) = '"' then
               Position := Position + 1;
               Raw_First := Raw_Start;
               Raw_Last := Position - 1;
               return;
            elsif Character'Pos (Item_At (Position)) < 16#20# then
               Fail (Invalid_Syntax);
               return;
            elsif Item_At (Position) /= '\' then
               if Store then
                  Append (Data, Length, Item_At (Position));
               end if;
               Position := Position + 1;
            else
               Position := Position + 1;
               if At_End then
                  Fail (Invalid_Syntax);
                  return;
               end if;

               case Item_At (Position) is
                  when '"' | '\' | '/' =>
                     if Store then
                        Append (Data, Length, Item_At (Position));
                     end if;
                     Position := Position + 1;
                  when 'b' =>
                     if Store then
                        Append (Data, Length, Character'val (8));
                     end if;
                     Position := Position + 1;
                  when 'f' =>
                     if Store then
                        Append (Data, Length, Character'val (12));
                     end if;
                     Position := Position + 1;
                  when 'n' =>
                     if Store then
                        Append (Data, Length, Character'val (10));
                     end if;
                     Position := Position + 1;
                  when 'r' =>
                     if Store then
                        Append (Data, Length, Character'val (13));
                     end if;
                     Position := Position + 1;
                  when 't' =>
                     if Store then
                        Append (Data, Length, Character'val (9));
                     end if;
                     Position := Position + 1;
                  when 'u' =>
                     Position := Position + 1;
                     Code := Read_Hex_Quad;
                     exit when Failed;

                     if Code in 16#D800# .. 16#DBFF# then
                        if Position + 5 > Last_Position
                          or else Item_At (Position) /= '\'
                          or else Item_At (Position + 1) /= 'u'
                        then
                           Fail (Invalid_Syntax);
                           return;
                        end if;

                        Position := Position + 2;
                        Low := Read_Hex_Quad;
                        if Failed then
                           return;
                        end if;
                        if Low not in 16#DC00# .. 16#DFFF# then
                           Fail (Invalid_Syntax);
                           return;
                        end if;

                        Code :=
                          16#10000#
                          + (Code - 16#D800#) * 16#400#
                          + (Low - 16#DC00#);
                     elsif Code in 16#DC00# .. 16#DFFF# then
                        Fail (Invalid_Syntax);
                        return;
                     end if;

                     if Store then
                        Append_Code_Point (Data, Length, Code);
                     end if;
                  when others =>
                     Fail (Invalid_Syntax);
                     return;
               end case;
            end if;

            exit when Failed;
         end loop;

         if not Failed then
            Fail (Invalid_Syntax);
         end if;
      end Parse_String_Data;

      procedure Parse_String
        (Value     : out Text;
         Raw_First : out Natural;
         Raw_Last  : out Natural)
      is
      begin
         Value := (others => <>);
         Parse_String_Data
           (Value.Data, Value.Length, Raw_First, Raw_Last);
      end Parse_String;

      procedure Parse_String
        (Value     : out Run_Process_Text;
         Raw_First : out Natural;
         Raw_Last  : out Natural)
      is
      begin
         Value := (others => <>);
         Parse_String_Data
           (Value.data, Value.length, Raw_First, Raw_Last);
      end Parse_String;

      procedure Parse_String
        (Value     : out Run_Process_Argument_Text;
         Raw_First : out Natural;
         Raw_Last  : out Natural)
      is
      begin
         Value := (others => <>);
         Parse_String_Data
           (Value.data, Value.length, Raw_First, Raw_Last);
      end Parse_String;

      procedure Skip_String
        (Raw_First : out Natural;
         Raw_Last  : out Natural)
      is
         Data   : String (1 .. 1) := [others => Character'val (0)];
         Length : Natural := 0;
      begin
         Parse_String_Data
           (Data, Length, Raw_First, Raw_Last, Store => False);
      end Skip_String;

      procedure Parse_Number
        (Raw_First : out Natural;
         Raw_Last  : out Natural)
      is
         Start : constant Natural := Position;
      begin
         Raw_First := 0;
         Raw_Last := 0;

         if not At_End and then Item_At (Position) = '-' then
            Position := Position + 1;
         end if;

         if At_End then
            Fail (Invalid_Syntax);
            return;
         elsif Item_At (Position) = '0' then
            Position := Position + 1;
            if not At_End and then Item_At (Position) in '0' .. '9' then
               Fail (Invalid_Syntax);
               return;
            end if;
         elsif Item_At (Position) in '1' .. '9' then
            while not At_End and then Item_At (Position) in '0' .. '9' loop
               Position := Position + 1;
            end loop;
         else
            Fail (Invalid_Syntax);
            return;
         end if;

         if not At_End and then Item_At (Position) = '.' then
            Position := Position + 1;
            if At_End or else Item_At (Position) not in '0' .. '9' then
               Fail (Invalid_Syntax);
               return;
            end if;
            while not At_End and then Item_At (Position) in '0' .. '9' loop
               Position := Position + 1;
            end loop;
         end if;

         if not At_End
           and then (Item_At (Position) = 'e' or else Item_At (Position) = 'E')
         then
            Position := Position + 1;
            if not At_End
              and then
                (Item_At (Position) = '+'
                 or else Item_At (Position) = '-')
            then
               Position := Position + 1;
            end if;
            if At_End or else Item_At (Position) not in '0' .. '9' then
               Fail (Invalid_Syntax);
               return;
            end if;
            while not At_End and then Item_At (Position) in '0' .. '9' loop
               Position := Position + 1;
            end loop;
         end if;

         if Position - Start > Max_Number_Bytes then
            Fail (Number_Too_Long);
            return;
         end if;

         Raw_First := Start;
         Raw_Last := Position - 1;
      end Parse_Number;

      function Name_Equals
        (Left  : Name_Text;
         Right : String) return Boolean
      is
      begin
         return Left.Length = Right'Length
           and then
             (Left.Length = 0
              or else Left.Data (1 .. Left.Length) = Right);
      end Name_Equals;

      function Same_Name
        (Left  : Name_Text;
         Right : Name_Text) return Boolean
      is
      begin
         return Left.Length = Right.Length
           and then
             (Left.Length = 0
              or else Left.Data (1 .. Left.Length) =
                Right.Data (1 .. Right.Length));
      end Same_Name;

      procedure Copy_Text
        (Source : Text;
         Target : out Text)
      is
      begin
         Target := Source;
      end Copy_Text;

      procedure Copy_Slice
        (First  : Natural;
         Last   : Natural;
         Target : out Text)
      is
         Slice_Length : Natural;
      begin
         Target := (others => <>);
         if First = 0 or else Last < First then
            return;
         end if;

         Slice_Length := Last - First + 1;
         if Slice_Length > Max_Decoded_String_Bytes then
            Fail (String_Too_Long);
            return;
         end if;

         Target.Length := Slice_Length;
         Target.Data (1 .. Slice_Length) :=
           Input_Slice (First, Last);
      end Copy_Slice;

      type Parsed_Value is record
         Kind              : Value_Kind := Absent;
         Value             : Text;
         Run_Process_Value : Run_Process_Text;
         Raw_First         : Natural := 0;
         Raw_Last          : Natural := 0;
         Member_Count      : Natural := 0;
      end record;

      procedure Parse_Value
        (Depth   : Positive;
         Context : Object_Context;
         Parsed  : out Parsed_Value);

      procedure Parse_Object
        (Depth        : Positive;
         Context      : Object_Context;
         Member_Count : out Natural)
      is
         Names       : Name_Array;
         Name_Count  : Natural := 0;
         Decoded     : Text;
         Current     : Name_Text;
         Name_First    : Natural;
         Name_Last     : Natural;
         Parsed        : Parsed_Value;
         Child_Context : Object_Context;
      begin
         Member_Count := 0;
         if Depth > Max_Depth then
            Fail (Too_Deep);
            return;
         end if;

         Position := Position + 1;
         Skip_Whitespace;
         if not At_End and then Item_At (Position) = '}' then
            Position := Position + 1;
            return;
         end if;

         loop
            if At_End or else Item_At (Position) /= '"' then
               Fail (Invalid_Syntax);
               return;
            end if;

            Count_Token;
            exit when Failed;
            Parse_String (Decoded, Name_First, Name_Last);
            exit when Failed;
            if Name_First = 0 or else Name_Last < Name_First then
               Fail (Invalid_Syntax);
               exit;
            end if;
            if Decoded.Length > Max_Member_Name_Bytes then
               Fail (String_Too_Long);
               exit;
            end if;
            if Name_Count = Max_Members_Per_Object then
               Fail (Too_Many_Members);
               exit;
            end if;

            Current := (others => <>);
            Current.Length := Decoded.Length;
            if Current.Length > 0 then
               Current.Data (1 .. Current.Length) :=
                 Decoded.Data (1 .. Decoded.Length);
            end if;

            for Existing in 1 .. Name_Count loop
               if Same_Name (Names (Existing), Current) then
                  Fail (Duplicate_Member);
                  exit;
               end if;
            end loop;
            exit when Failed;

            Name_Count := Name_Count + 1;
            Names (Name_Count) := Current;
            Member_Count := Name_Count;

            Skip_Whitespace;
            if At_End or else Item_At (Position) /= ':' then
               Fail (Invalid_Syntax);
               exit;
            end if;
            Position := Position + 1;
            Skip_Whitespace;

            Child_Context := Ignored_Context;
            if Context = Root_Context and then
               (Name_Equals (Current, "jsonrpc") or else
                Name_Equals (Current, "method") or else
                Name_Equals (Current, "id"))
            then
               Child_Context := Generic_Context;
            elsif Context = Root_Context
              and then Name_Equals (Current, "params")
            then
               Child_Context := Params_Context;
            elsif Context = Params_Context
              and then Name_Equals (Current, "_meta")
            then
               Child_Context := Meta_Context;
            elsif Context = Params_Context and then
              (Name_Equals (Current, "cursor") or else
               Name_Equals (Current, "name"))
            then
               Child_Context := Generic_Context;
            elsif Context = Params_Context
              and then Name_Equals (Current, "arguments")
            then
               Child_Context := Arguments_Context;
            elsif Context = Arguments_Context and then
              (Name_Equals (Current, "resolution") or else
               Name_Equals (Current, "timeout_ms") or else
               Name_Equals (Current, "offset") or else
               Name_Equals (Current, "maximum_bytes") or else
               Name_Equals (Current, "expected_revision"))
            then
               Child_Context := Generic_Context;
            elsif Context = Arguments_Context
              and then Name_Equals (Current, "argv")
            then
               Child_Context := Run_Process_Argv_Context;
            elsif Context = Arguments_Context and then
              (Name_Equals (Current, "cwd") or else
               Name_Equals (Current, "root") or else
               Name_Equals (Current, "path"))
            then
               Child_Context := Run_Process_Text_Context;
            elsif Context = Arguments_Context and then
              (Name_Equals (Current, "workspace_token") or else
               Name_Equals (Current, "operation_id") or else
               Name_Equals (Current, "job_id") or else
               Name_Equals (Current, "cursor"))
            then
               Child_Context := Generic_Context;
            elsif Context = Meta_Context
              and then Name_Equals
                (Current, "io.modelcontextprotocol/protocolVersion")
            then
               Child_Context := Generic_Context;
            elsif Context = Meta_Context
              and then Name_Equals
                (Current, "io.modelcontextprotocol/clientInfo")
            then
               Child_Context := Meta_Client_Info_Context;
            elsif Context = Meta_Client_Info_Context and then
              (Name_Equals (Current, "name") or else
               Name_Equals (Current, "version"))
            then
               Child_Context := Generic_Context;
            end if;

            Parse_Value
              (Depth + 1,
               Child_Context,
               Parsed);
            exit when Failed;

            if Context = Root_Context then
               if Name_Equals (Current, "jsonrpc") then
                  Result.JSONRPC_Kind := Parsed.Kind;
                  if Parsed.Kind = String_Value then
                     Copy_Text (Parsed.Value, Result.JSONRPC);
                  end if;
               elsif Name_Equals (Current, "method") then
                  Result.Method_Kind := Parsed.Kind;
                  if Parsed.Kind = String_Value then
                     Copy_Text (Parsed.Value, Result.Method);
                  end if;
               elsif Name_Equals (Current, "id") then
                  case Parsed.Kind is
                     when String_Value =>
                        if Parsed.Raw_Last - Parsed.Raw_First + 1 <=
                          Max_Request_Id_Bytes
                        then
                           Result.Request_Id_Kind := String_Id;
                           Copy_Slice
                             (Parsed.Raw_First,
                              Parsed.Raw_Last,
                              Result.Request_Id_Raw);
                        else
                           Result.Request_Id_Kind := Invalid_Id;
                        end if;
                     when Number_Value =>
                        if Parsed.Raw_Last - Parsed.Raw_First + 1 <=
                          Max_Request_Id_Bytes
                        then
                           Result.Request_Id_Kind := Number_Id;
                           Copy_Slice
                             (Parsed.Raw_First,
                              Parsed.Raw_Last,
                              Result.Request_Id_Raw);
                        else
                           Result.Request_Id_Kind := Invalid_Id;
                        end if;
                     when others =>
                        Result.Request_Id_Kind := Invalid_Id;
                  end case;
               elsif Name_Equals (Current, "params") then
                  Result.Params_Kind := Parsed.Kind;
                  Result.Params_Member_Count := Parsed.Member_Count;
               end if;
            elsif Context = Params_Context then
               if Name_Equals (Current, "_meta") then
                  Result.Meta_Kind := Parsed.Kind;
               elsif Name_Equals (Current, "cursor") then
                  Result.Cursor_Kind := Parsed.Kind;
                  if Parsed.Kind = String_Value then
                     Copy_Text (Parsed.Value, Result.Cursor);
                  end if;
               elsif Name_Equals (Current, "name") then
                  Result.Tool_Name_Kind := Parsed.Kind;
                  if Parsed.Kind = String_Value then
                     Copy_Text (Parsed.Value, Result.Tool_Name);
                  end if;
               elsif Name_Equals (Current, "arguments") then
                  Result.Arguments_Kind := Parsed.Kind;
                  Result.Arguments_Member_Count := Parsed.Member_Count;
               elsif Name_Equals (Current, "inputResponses") then
                  Result.Input_Responses_Kind := Parsed.Kind;
               elsif Name_Equals (Current, "requestState") then
                  Result.Request_State_Kind := Parsed.Kind;
               else
                  Result.Params_Has_Unknown := True;
               end if;
            elsif Context = Meta_Context then
               if Name_Equals
                 (Current, "io.modelcontextprotocol/protocolVersion")
               then
                  Result.Meta_Protocol_Version_Kind := Parsed.Kind;
                  if Parsed.Kind = String_Value then
                     Copy_Text
                       (Parsed.Value, Result.Meta_Protocol_Version);
                     Copy_Slice
                       (Parsed.Raw_First,
                        Parsed.Raw_Last,
                        Result.Meta_Protocol_Version_Raw);
                  end if;
               elsif Name_Equals
                 (Current, "io.modelcontextprotocol/clientCapabilities")
               then
                  Result.Meta_Client_Capabilities_Kind := Parsed.Kind;
               elsif Name_Equals
                 (Current, "io.modelcontextprotocol/clientInfo")
               then
                  Result.Meta_Client_Info_Kind := Parsed.Kind;
               end if;
            elsif Context = Meta_Client_Info_Context then
               if Name_Equals (Current, "name") then
                  Result.Meta_Client_Name_Kind := Parsed.Kind;
                  if Parsed.Kind = String_Value then
                     Copy_Text (Parsed.Value, Result.Meta_Client_Name);
                  end if;
               elsif Name_Equals (Current, "version") then
                  Result.Meta_Client_Version_Kind := Parsed.Kind;
                  if Parsed.Kind = String_Value then
                     Copy_Text (Parsed.Value, Result.Meta_Client_Version);
                  end if;
               end if;
            elsif Context = Arguments_Context then
               if Name_Equals (Current, "argv") then
                  Result.argument_argv_kind := Parsed.Kind;
               elsif Name_Equals (Current, "resolution") then
                  Result.argument_resolution_kind := Parsed.Kind;
                  if Parsed.Kind = String_Value then
                     Copy_Text (Parsed.Value, Result.argument_resolution);
                  end if;
               elsif Name_Equals (Current, "cwd") then
                  Result.argument_cwd_kind := Parsed.Kind;
                  if Parsed.Kind = String_Value then
                     Result.argument_cwd := Parsed.Run_Process_Value;
                  end if;
               elsif Name_Equals (Current, "timeout_ms") then
                  Result.argument_timeout_ms_kind := Parsed.Kind;
                  if Parsed.Kind = Number_Value then
                     Copy_Slice
                       (Parsed.Raw_First,
                        Parsed.Raw_Last,
                        Result.argument_timeout_ms_raw);
                  end if;
               elsif Name_Equals (Current, "root") then
                  Result.argument_workspace_root_kind := Parsed.Kind;
                  if Parsed.Kind = String_Value then
                     Result.argument_workspace_root := Parsed.Run_Process_Value;
                  end if;
               elsif Name_Equals (Current, "workspace_token") then
                  Result.argument_workspace_token_kind := Parsed.Kind;
                  if Parsed.Kind = String_Value then
                     Copy_Text
                       (Parsed.Value, Result.argument_workspace_token);
                  end if;
               elsif Name_Equals (Current, "path") then
                  Result.argument_path_kind := Parsed.Kind;
                  if Parsed.Kind = String_Value then
                     Result.argument_path := Parsed.Run_Process_Value;
                  end if;
               elsif Name_Equals (Current, "offset") then
                  Result.argument_offset_kind := Parsed.Kind;
                  if Parsed.Kind = Number_Value then
                     Copy_Slice
                       (Parsed.Raw_First,
                        Parsed.Raw_Last,
                        Result.argument_offset_raw);
                  end if;
               elsif Name_Equals (Current, "maximum_bytes") then
                  Result.argument_maximum_bytes_kind := Parsed.Kind;
                  if Parsed.Kind = Number_Value then
                     Copy_Slice
                       (Parsed.Raw_First,
                        Parsed.Raw_Last,
                        Result.argument_maximum_bytes_raw);
                  end if;
               elsif Name_Equals (Current, "expected_revision") then
                  Result.argument_expected_revision_kind := Parsed.Kind;
                  if Parsed.Kind = String_Value then
                     Copy_Text
                       (Parsed.Value, Result.argument_expected_revision);
                  end if;
               elsif Name_Equals (Current, "operation_id") then
                  Result.argument_operation_id_kind := Parsed.Kind;
                  if Parsed.Kind = String_Value then
                     Copy_Text (Parsed.Value, Result.argument_operation_id);
                  end if;
               elsif Name_Equals (Current, "job_id") then
                  Result.argument_job_id_kind := Parsed.Kind;
                  if Parsed.Kind = String_Value then
                     Copy_Text (Parsed.Value, Result.argument_job_id);
                  end if;
               elsif Name_Equals (Current, "cursor") then
                  Result.argument_poll_cursor_kind := Parsed.Kind;
                  if Parsed.Kind = String_Value then
                     Copy_Text (Parsed.Value, Result.argument_poll_cursor);
                  end if;
               else
                  Result.arguments_has_unknown := True;
               end if;
            end if;

            Skip_Whitespace;
            if At_End then
               Fail (Invalid_Syntax);
               exit;
            elsif Item_At (Position) = '}' then
               Position := Position + 1;
               exit;
            elsif Item_At (Position) = ',' then
               Position := Position + 1;
               Skip_Whitespace;
            else
               Fail (Invalid_Syntax);
               exit;
            end if;
         end loop;
      end Parse_Object;

      procedure Parse_Array
        (Depth        : Positive;
         Context      : Object_Context;
         Member_Count : out Natural)
      is
         Item         : Parsed_Value;
         Item_Context : Object_Context;
         Item_First   : Natural;
      begin
         Member_Count := 0;
         if Depth > Max_Depth then
            Fail (Too_Deep);
            return;
         end if;

         Position := Position + 1;
         Skip_Whitespace;
         if not At_End and then Item_At (Position) = ']' then
            Position := Position + 1;
            return;
         end if;

         loop
            Item_Context :=
              (if Context = Ignored_Context
               then Ignored_Context
               else Generic_Context);
            if Context = Run_Process_Argv_Context then
               Item_Context := Run_Process_Argument_Context;
            end if;

            Parse_Value (Depth + 1, Item_Context, Item);
            exit when Failed;
            if Item.Kind = Absent then
               Fail (Invalid_Syntax);
               exit;
            end if;
            Member_Count := Member_Count + 1;

            if Context = Run_Process_Argv_Context then
               Result.argument_argv.count := Member_Count;

               if Item.Kind /= String_Value then
                  Result.argument_argv.all_strings := False;
               else
                  Result.argument_argv.total_bytes :=
                    Result.argument_argv.total_bytes +
                    Run_Process_Argument_Buffer.length;

                  if Member_Count <= Result.argument_argv.slices'last then
                     Result.argument_argv.slices(Member_Count).length :=
                       Run_Process_Argument_Buffer.length;

                     if Run_Process_Argument_Buffer.length > 0 and then
                        Result.argument_argv.stored_bytes +
                          Run_Process_Argument_Buffer.length <=
                            Result.argument_argv.data'length
                     then
                        Item_First := Result.argument_argv.stored_bytes + 1;
                        Result.argument_argv.slices(Member_Count).first :=
                          Item_First;
                        Result.argument_argv.data
                          (Item_First ..
                           Item_First +
                             Run_Process_Argument_Buffer.length - 1) :=
                               Run_Process_Argument_Buffer.data
                                 (1 .. Run_Process_Argument_Buffer.length);
                        Result.argument_argv.stored_bytes :=
                          Result.argument_argv.stored_bytes +
                          Run_Process_Argument_Buffer.length;
                     end if;
                  end if;
               end if;
            end if;

            Skip_Whitespace;
            if At_End then
               Fail (Invalid_Syntax);
               exit;
            elsif Item_At (Position) = ']' then
               Position := Position + 1;
               exit;
            elsif Item_At (Position) = ',' then
               Position := Position + 1;
               Skip_Whitespace;
            else
               Fail (Invalid_Syntax);
               exit;
            end if;
         end loop;
      end Parse_Array;

      procedure Parse_Value
        (Depth   : Positive;
         Context : Object_Context;
         Parsed  : out Parsed_Value)
      is
         Last_Required : Natural;
      begin
         Parsed := (others => <>);

         if Depth > Max_Depth then
            Fail (Too_Deep);
            return;
         end if;

         Count_Token;
         if Failed then
            return;
         end if;
         if At_End then
            Fail (Invalid_Syntax);
            return;
         end if;

         case Item_At (Position) is
            when '{' =>
               Parsed.Kind := Object_Value;
               Parse_Object (Depth, Context, Parsed.Member_Count);
            when '[' =>
               Parsed.Kind := Array_Value;
               Parse_Array (Depth, Context, Parsed.Member_Count);
            when '"' =>
               Parsed.Kind := String_Value;
               if Context = Run_Process_Argument_Context or else
                  Context = Run_Process_Argv_Context
               then
                  Parse_String
                    (Run_Process_Argument_Buffer,
                     Parsed.Raw_First,
                     Parsed.Raw_Last);
               elsif Context = Run_Process_Text_Context then
                  Parse_String
                    (Parsed.Run_Process_Value,
                     Parsed.Raw_First,
                     Parsed.Raw_Last);
               elsif Context = Ignored_Context then
                  Skip_String (Parsed.Raw_First, Parsed.Raw_Last);
               else
                  Parse_String
                    (Parsed.Value, Parsed.Raw_First, Parsed.Raw_Last);
               end if;
            when '-' | '0' .. '9' =>
               Parsed.Kind := Number_Value;
               Parse_Number (Parsed.Raw_First, Parsed.Raw_Last);
            when 't' =>
               Last_Required := Position + 3;
               if Last_Required <= Last_Position
                 and then Input_Slice (Position, Last_Required) = "true"
               then
                  Parsed.Kind := Boolean_Value;
                  Position := Last_Required + 1;
               else
                  Fail (Invalid_Syntax);
               end if;
            when 'f' =>
               Last_Required := Position + 4;
               if Last_Required <= Last_Position
                 and then Input_Slice (Position, Last_Required) = "false"
               then
                  Parsed.Kind := Boolean_Value;
                  Position := Last_Required + 1;
               else
                  Fail (Invalid_Syntax);
               end if;
            when 'n' =>
               Last_Required := Position + 3;
               if Last_Required <= Last_Position
                 and then Input_Slice (Position, Last_Required) = "null"
               then
                  Parsed.Kind := Null_Value;
                  Position := Last_Required + 1;
               else
                  Fail (Invalid_Syntax);
               end if;
            when others =>
               Fail (Invalid_Syntax);
         end case;
      end Parse_Value;

      Root : Parsed_Value;
   begin
      Result := (others => <>);
      Status := Parse_OK;

      if Input'Length > Max_Input_Bytes then
         Status := Input_Too_Long;
         return;
      end if;

      if not UTF8_Is_Valid then
         Status := Invalid_UTF8;
         return;
      end if;

      Skip_Whitespace;
      Parse_Value (1, Root_Context, Root);
      Result.Root_Kind := Root.Kind;

      if not Failed then
         Skip_Whitespace;
         if not At_End then
            Fail (Invalid_Syntax);
         end if;
      end if;

      if Failed then
         Status := Failure;
      else
         Status := Parse_OK;
      end if;
   end Parse;
end Sonbal.MCP.JSON;
