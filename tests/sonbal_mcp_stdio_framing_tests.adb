-- ============================================================================
-- sonbal_mcp_stdio_framing_tests.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Ada.Characters.Latin_1;
with Sonbal.MCP.Stdio_Framing;
with Sonbal_Test_Support;

package body Sonbal_MCP_Stdio_Framing_Tests is
   use type Sonbal.MCP.Stdio_Framing.Feed_Status;
   use type Sonbal.MCP.Stdio_Framing.Finish_Status;

   procedure Split_Frame
     (Reporter : in out Clair.Test.Reporter.Context)
   is
      State    : Sonbal.MCP.Stdio_Framing.Decoder (32);
      Consumed : Natural;
      Status   : Sonbal.MCP.Stdio_Framing.Feed_Status;
   begin
      Sonbal.MCP.Stdio_Framing.Feed (State, "{", Consumed, Status);
      Sonbal_Test_Support.Check
        (Reporter,
         Status = Sonbal.MCP.Stdio_Framing.Need_More,
         "split frame waits for the delimiter");
      Sonbal_Test_Support.Check
        (Reporter, Consumed = 1, "split frame reports consumed bytes");

      Sonbal.MCP.Stdio_Framing.Feed
        (State,
         "}" & Ada.Characters.Latin_1.LF,
         Consumed,
         Status);
      Sonbal_Test_Support.Check
        (Reporter,
         Status = Sonbal.MCP.Stdio_Framing.Frame_Ready,
         "split frame completes after newline");
      Sonbal_Test_Support.Check
        (Reporter, Consumed = 2, "split frame consumes its closing bytes");
      Sonbal_Test_Support.Check
        (Reporter,
         Sonbal.MCP.Stdio_Framing.Frame (State) = "{}",
         "split frame preserves payload");
   end Split_Frame;

   procedure Following_Bytes
     (Reporter : in out Clair.Test.Reporter.Context)
   is
      State    : Sonbal.MCP.Stdio_Framing.Decoder (32);
      Consumed : Natural;
      Status   : Sonbal.MCP.Stdio_Framing.Feed_Status;
      Data     : constant String :=
        "{}" & Ada.Characters.Latin_1.LF & "next";
   begin
      Sonbal.MCP.Stdio_Framing.Feed (State, Data, Consumed, Status);
      Sonbal_Test_Support.Check
        (Reporter,
         Status = Sonbal.MCP.Stdio_Framing.Frame_Ready,
         "decoder stops at the first complete frame");
      Sonbal_Test_Support.Check
        (Reporter, Consumed = 3, "decoder leaves following bytes unconsumed");
      Sonbal_Test_Support.Check
        (Reporter,
         Sonbal.MCP.Stdio_Framing.Frame (State) = "{}",
         "first frame excludes following bytes");
   end Following_Bytes;

   procedure Exact_Capacity
     (Reporter : in out Clair.Test.Reporter.Context)
   is
      State    : Sonbal.MCP.Stdio_Framing.Decoder (4);
      Consumed : Natural;
      Status   : Sonbal.MCP.Stdio_Framing.Feed_Status;
   begin
      Sonbal.MCP.Stdio_Framing.Feed
        (State,
         "1234" & Ada.Characters.Latin_1.LF,
         Consumed,
         Status);
      Sonbal_Test_Support.Check
        (Reporter,
         Status = Sonbal.MCP.Stdio_Framing.Frame_Ready,
         "capacity-sized frame is accepted");
      Sonbal_Test_Support.Check
        (Reporter, Consumed = 5, "capacity-sized frame consumes its delimiter");
      Sonbal_Test_Support.Check
        (Reporter,
         Sonbal.MCP.Stdio_Framing.Frame_Length (State) = 4,
         "capacity-sized frame reports its full length");
   end Exact_Capacity;

   procedure Exact_Capacity_CRLF
     (Reporter : in out Clair.Test.Reporter.Context)
   is
      State    : Sonbal.MCP.Stdio_Framing.Decoder (4);
      Consumed : Natural;
      Status   : Sonbal.MCP.Stdio_Framing.Feed_Status;
   begin
      Sonbal.MCP.Stdio_Framing.Feed
        (State,
         "1234" & Ada.Characters.Latin_1.CR &
           Ada.Characters.Latin_1.LF,
         Consumed,
         Status);
      Sonbal_Test_Support.Check
        (Reporter,
         Status = Sonbal.MCP.Stdio_Framing.Frame_Ready,
         "capacity-sized CRLF frame is accepted");
      Sonbal_Test_Support.Check
        (Reporter,
         Consumed = 6,
         "capacity-sized CRLF frame consumes its delimiter");
      Sonbal_Test_Support.Check
        (Reporter,
         Sonbal.MCP.Stdio_Framing.Frame (State) = "1234",
         "CRLF lookahead does not consume payload capacity");
   end Exact_Capacity_CRLF;

   procedure Oversize_And_Reset
     (Reporter : in out Clair.Test.Reporter.Context)
   is
      State    : Sonbal.MCP.Stdio_Framing.Decoder (4);
      Consumed : Natural;
      Status   : Sonbal.MCP.Stdio_Framing.Feed_Status;
   begin
      Sonbal.MCP.Stdio_Framing.Feed (State, "12345", Consumed, Status);
      Sonbal_Test_Support.Check
        (Reporter,
         Status = Sonbal.MCP.Stdio_Framing.Discarding_Too_Large,
         "oversize frame enters bounded discard mode");
      Sonbal_Test_Support.Check
        (Reporter, Consumed = 5, "oversize frame consumes the supplied chunk");
      Sonbal_Test_Support.Check
        (Reporter,
         not Sonbal.MCP.Stdio_Framing.Is_Complete (State),
         "oversize frame waits for its delimiter");

      Sonbal.MCP.Stdio_Framing.Feed
        (State,
         Ada.Characters.Latin_1.LF & "{}",
         Consumed,
         Status);
      Sonbal_Test_Support.Check
        (Reporter,
         Status = Sonbal.MCP.Stdio_Framing.Frame_Rejected_Too_Large,
         "oversize frame is rejected at its delimiter");
      Sonbal_Test_Support.Check
        (Reporter, Consumed = 1, "oversize rejection preserves following bytes");
      Sonbal_Test_Support.Check
        (Reporter,
         not Sonbal.MCP.Stdio_Framing.Has_Frame (State),
         "oversize rejection exposes no partial payload");

      Sonbal.MCP.Stdio_Framing.Reset (State);
      Sonbal.MCP.Stdio_Framing.Feed
        (State,
         "{}" & Ada.Characters.Latin_1.LF,
         Consumed,
         Status);
      Sonbal_Test_Support.Check
        (Reporter,
         Status = Sonbal.MCP.Stdio_Framing.Frame_Ready,
         "reset accepts the next frame after rejection");
      Sonbal_Test_Support.Check
        (Reporter, Consumed = 3, "reset frame consumes its delimiter");
      Sonbal_Test_Support.Check
        (Reporter,
         Sonbal.MCP.Stdio_Framing.Frame (State) = "{}",
         "reset removes rejected frame state");
   end Oversize_And_Reset;

   procedure CRLF_Terminator
     (Reporter : in out Clair.Test.Reporter.Context)
   is
      State    : Sonbal.MCP.Stdio_Framing.Decoder (8);
      Consumed : Natural;
      Status   : Sonbal.MCP.Stdio_Framing.Feed_Status;
   begin
      Sonbal.MCP.Stdio_Framing.Feed
        (State,
         "{}" & Ada.Characters.Latin_1.CR & Ada.Characters.Latin_1.LF,
         Consumed,
         Status);
      Sonbal_Test_Support.Check
        (Reporter,
         Status = Sonbal.MCP.Stdio_Framing.Frame_Ready,
         "CRLF completes one frame");
      Sonbal_Test_Support.Check
        (Reporter, Consumed = 4, "CRLF consumes both terminator bytes");
      Sonbal_Test_Support.Check
        (Reporter,
         Sonbal.MCP.Stdio_Framing.Frame (State) = "{}",
         "CRLF terminator is removed from the payload");
   end CRLF_Terminator;

   procedure Embedded_Carriage_Return
     (Reporter : in out Clair.Test.Reporter.Context)
   is
      State    : Sonbal.MCP.Stdio_Framing.Decoder (8);
      Consumed : Natural;
      Status   : Sonbal.MCP.Stdio_Framing.Feed_Status;
      Data     : constant String :=
        "a" & Ada.Characters.Latin_1.CR & "b" & Ada.Characters.Latin_1.LF;
      Expected : constant String := "a" & Ada.Characters.Latin_1.CR & "b";
   begin
      Sonbal.MCP.Stdio_Framing.Feed (State, Data, Consumed, Status);
      Sonbal_Test_Support.Check
        (Reporter,
         Status = Sonbal.MCP.Stdio_Framing.Frame_Ready,
         "embedded carriage return remains payload");
      Sonbal_Test_Support.Check
        (Reporter,
         Sonbal.MCP.Stdio_Framing.Frame (State) = Expected,
         "only a carriage return before newline is removed");
   end Embedded_Carriage_Return;

   procedure Clean_End
     (Reporter : in out Clair.Test.Reporter.Context)
   is
      State  : Sonbal.MCP.Stdio_Framing.Decoder (8);
      Status : Sonbal.MCP.Stdio_Framing.Finish_Status;
   begin
      Sonbal.MCP.Stdio_Framing.Finish (State, Status);
      Sonbal_Test_Support.Check
        (Reporter,
         Status = Sonbal.MCP.Stdio_Framing.Clean_End,
         "empty input ends cleanly");
      Sonbal_Test_Support.Check
        (Reporter,
         Sonbal.MCP.Stdio_Framing.Is_Complete (State),
         "clean EOF completes the decoder");
   end Clean_End;

   procedure Truncated_End
     (Reporter : in out Clair.Test.Reporter.Context)
   is
      State       : Sonbal.MCP.Stdio_Framing.Decoder (8);
      Consumed    : Natural;
      Feed_Status : Sonbal.MCP.Stdio_Framing.Feed_Status;
      End_Status  : Sonbal.MCP.Stdio_Framing.Finish_Status;
   begin
      Sonbal.MCP.Stdio_Framing.Feed
        (State, "{", Consumed, Feed_Status);
      Sonbal_Test_Support.Check
        (Reporter,
         Feed_Status = Sonbal.MCP.Stdio_Framing.Need_More,
         "unterminated frame remains pending");
      Sonbal_Test_Support.Check
        (Reporter,
         Consumed = 1,
         "unterminated frame consumes the supplied byte");
      Sonbal.MCP.Stdio_Framing.Finish (State, End_Status);
      Sonbal_Test_Support.Check
        (Reporter,
         End_Status = Sonbal.MCP.Stdio_Framing.Truncated_Frame,
         "EOF rejects an unterminated frame");
      Sonbal_Test_Support.Check
        (Reporter,
         Sonbal.MCP.Stdio_Framing.Is_Complete (State),
         "truncated EOF completes the decoder");
   end Truncated_End;

   procedure Oversize_End
     (Reporter : in out Clair.Test.Reporter.Context)
   is
      State       : Sonbal.MCP.Stdio_Framing.Decoder (2);
      Consumed    : Natural;
      Feed_Status : Sonbal.MCP.Stdio_Framing.Feed_Status;
      End_Status  : Sonbal.MCP.Stdio_Framing.Finish_Status;
   begin
      Sonbal.MCP.Stdio_Framing.Feed
        (State, "123", Consumed, Feed_Status);
      Sonbal_Test_Support.Check
        (Reporter,
         Feed_Status = Sonbal.MCP.Stdio_Framing.Discarding_Too_Large,
         "unterminated oversize frame enters discard mode");
      Sonbal_Test_Support.Check
        (Reporter,
         Consumed = 3,
         "unterminated oversize frame consumes its chunk");
      Sonbal.MCP.Stdio_Framing.Finish (State, End_Status);
      Sonbal_Test_Support.Check
        (Reporter,
         End_Status = Sonbal.MCP.Stdio_Framing.Oversize_Frame_At_End,
         "EOF distinguishes an unterminated oversize frame");
      Sonbal_Test_Support.Check
        (Reporter,
         Sonbal.MCP.Stdio_Framing.Is_Complete (State),
         "oversize EOF completes the decoder");
   end Oversize_End;

   procedure Unmatched_Carriage_Return
     (Reporter : in out Clair.Test.Reporter.Context)
   is
      State       : Sonbal.MCP.Stdio_Framing.Decoder (2);
      Consumed    : Natural;
      Feed_Status : Sonbal.MCP.Stdio_Framing.Feed_Status;
      End_Status  : Sonbal.MCP.Stdio_Framing.Finish_Status;
   begin
      Sonbal.MCP.Stdio_Framing.Feed
        (State,
         "12" & Ada.Characters.Latin_1.CR,
         Consumed,
         Feed_Status);
      Sonbal_Test_Support.Check
        (Reporter,
         Feed_Status = Sonbal.MCP.Stdio_Framing.Need_More,
         "trailing carriage return waits for newline");
      Sonbal.MCP.Stdio_Framing.Finish (State, End_Status);
      Sonbal_Test_Support.Check
        (Reporter,
         End_Status = Sonbal.MCP.Stdio_Framing.Oversize_Frame_At_End,
         "EOF counts an unmatched carriage return toward the limit");
   end Unmatched_Carriage_Return;

   procedure Empty_Frame
     (Reporter : in out Clair.Test.Reporter.Context)
   is
      State    : Sonbal.MCP.Stdio_Framing.Decoder (8);
      Consumed : Natural;
      Status   : Sonbal.MCP.Stdio_Framing.Feed_Status;
   begin
      Sonbal.MCP.Stdio_Framing.Feed
        (State, "" & Ada.Characters.Latin_1.LF, Consumed, Status);
      Sonbal_Test_Support.Check
        (Reporter,
         Status = Sonbal.MCP.Stdio_Framing.Frame_Ready,
         "empty line is delivered for protocol validation");
      Sonbal_Test_Support.Check
        (Reporter, Consumed = 1, "empty line consumes its delimiter");
      Sonbal_Test_Support.Check
        (Reporter,
         Sonbal.MCP.Stdio_Framing.Frame_Length (State) = 0,
         "empty line has a zero-length payload");
   end Empty_Frame;

   procedure Run (Reporter : in out Clair.Test.Reporter.Context) is
   begin
      Clair.Test.Reporter.Run_Scenario
        (Reporter, "split frame", Split_Frame'Access);
      Clair.Test.Reporter.Run_Scenario
        (Reporter, "following bytes", Following_Bytes'Access);
      Clair.Test.Reporter.Run_Scenario
        (Reporter, "exact capacity", Exact_Capacity'Access);
      Clair.Test.Reporter.Run_Scenario
        (Reporter, "exact capacity CRLF", Exact_Capacity_CRLF'Access);
      Clair.Test.Reporter.Run_Scenario
        (Reporter, "oversize discard and reset", Oversize_And_Reset'Access);
      Clair.Test.Reporter.Run_Scenario
        (Reporter, "CRLF terminator", CRLF_Terminator'Access);
      Clair.Test.Reporter.Run_Scenario
        (Reporter, "embedded carriage return", Embedded_Carriage_Return'Access);
      Clair.Test.Reporter.Run_Scenario
        (Reporter, "clean end of input", Clean_End'Access);
      Clair.Test.Reporter.Run_Scenario
        (Reporter, "truncated end of input", Truncated_End'Access);
      Clair.Test.Reporter.Run_Scenario
        (Reporter, "oversize end of input", Oversize_End'Access);
      Clair.Test.Reporter.Run_Scenario
        (Reporter,
         "unmatched carriage return",
         Unmatched_Carriage_Return'Access);
      Clair.Test.Reporter.Run_Scenario
        (Reporter, "empty frame", Empty_Frame'Access);
   end Run;
end Sonbal_MCP_Stdio_Framing_Tests;
