-- ============================================================================
-- sonbal-mcp-stdio_framing.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Ada.Characters.Latin_1;

package body Sonbal.MCP.Stdio_Framing is
   procedure Append
     (State : in out Decoder;
      Item  : Character)
   is
   begin
      if State.Length = State.Capacity then
         State.Overflowed := True;
      else
         State.Length := State.Length + 1;
         State.Buffer (State.Length) := Item;
      end if;
   end Append;

   procedure Feed
     (State    : in out Decoder;
      Data     : String;
      Consumed : out Natural;
      Status   : out Feed_Status)
   is
   begin
      Consumed := 0;
      Status := Need_More;

      for Index in Data'Range loop
         Consumed := Consumed + 1;

         if Data (Index) = Ada.Characters.Latin_1.LF then
            if State.Overflowed then
               State.Completion := Rejected;
               Status := Frame_Rejected_Too_Large;
            else
               State.Pending_CR := False;
               State.Completion := Ready;
               Status := Frame_Ready;
            end if;

            return;
         elsif State.Overflowed then
            null;
         else
            if State.Pending_CR then
               Append (State, Ada.Characters.Latin_1.CR);
               State.Pending_CR := False;
            end if;

            if not State.Overflowed then
               if Data (Index) = Ada.Characters.Latin_1.CR then
                  State.Pending_CR := True;
               else
                  Append (State, Data (Index));
               end if;
            end if;
         end if;
      end loop;

      if State.Overflowed then
         Status := Discarding_Too_Large;
      end if;
   end Feed;

   procedure Finish
     (State  : in out Decoder;
      Status : out Finish_Status)
   is
   begin
      if State.Overflowed
        or else (State.Pending_CR and then State.Length = State.Capacity)
      then
         State.Completion := Rejected;
         Status := Oversize_Frame_At_End;
      elsif State.Length = 0 and then not State.Pending_CR then
         State.Completion := Ended;
         Status := Clean_End;
      else
         State.Completion := Rejected;
         Status := Truncated_Frame;
      end if;
   end Finish;

   procedure Reset (State : in out Decoder) is
   begin
      State.Length := 0;
      State.Completion := Collecting;
      State.Overflowed := False;
      State.Pending_CR := False;
   end Reset;

   function Is_Complete (State : Decoder) return Boolean is
     (State.Completion /= Collecting);

   function Has_Frame (State : Decoder) return Boolean is
     (State.Completion = Ready);

   function Frame_Length (State : Decoder) return Natural is
     (State.Length);

   function Frame (State : Decoder) return String is
   begin
      if State.Length = 0 then
         return "";
      end if;

      return State.Buffer (1 .. State.Length);
   end Frame;
end Sonbal.MCP.Stdio_Framing;
