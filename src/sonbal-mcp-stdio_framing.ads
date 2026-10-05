-- ============================================================================
-- sonbal-mcp-stdio_framing.ads
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

package Sonbal.MCP.Stdio_Framing is
   Default_Max_Message_Bytes : constant Positive := 1_048_576;

   type Feed_Status is
     (Need_More,
      Discarding_Too_Large,
      Frame_Ready,
      Frame_Rejected_Too_Large);

   type Finish_Status is
     (Clean_End,
      Truncated_Frame,
      Oversize_Frame_At_End);

   type Decoder (Capacity : Positive) is limited private;

   function Is_Complete (State : Decoder) return Boolean;

   function Has_Frame (State : Decoder) return Boolean;

   procedure Feed
     (State    : in out Decoder;
      Data     : String;
      Consumed : out Natural;
      Status   : out Feed_Status)
     with Pre => not Is_Complete (State);

   procedure Finish
     (State  : in out Decoder;
      Status : out Finish_Status)
     with Pre => not Is_Complete (State);

   procedure Reset (State : in out Decoder);

   function Frame_Length (State : Decoder) return Natural
     with Pre => Has_Frame (State);

   function Frame (State : Decoder) return String
     with Pre => Has_Frame (State);

private
   type Completion_State is (Collecting, Ready, Rejected, Ended);

   type Decoder (Capacity : Positive) is limited record
      Buffer     : String (1 .. Capacity);
      Length     : Natural := 0;
      Completion : Completion_State := Collecting;
      Overflowed : Boolean := False;
      Pending_CR : Boolean := False;
   end record;
end Sonbal.MCP.Stdio_Framing;
