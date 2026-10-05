-- ============================================================================
-- sonbal_test_support.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

package body Sonbal_Test_Support is
   use type Sonbal.Process_Arguments.Append_State;
   procedure Check
     (Reporter  : in out Clair.Test.Reporter.Context;
      Condition : Boolean;
      Name      : String)
   is
   begin
      if Condition then
         Clair.Test.Reporter.Record_Assertion_Pass (Reporter, Name);
         Clair.Test.Reporter.Pass (Reporter, Name);
      else
         Clair.Test.Reporter.Record_Assertion_Failure (Reporter, Name);
      end if;
   end Check;

   function Process_Arguments
     (Executable : String)
   return Sonbal.Process_Arguments.Arguments
   is
      Result : Sonbal.Process_Arguments.Arguments;
      State  : Sonbal.Process_Arguments.Append_State;
   begin
      Sonbal.Process_Arguments.Clear (Result);
      State := Sonbal.Process_Arguments.Append (Result, Executable);
      if State /= Sonbal.Process_Arguments.Append_Accepted then
         raise Program_Error with "failed to build test process arguments";
      end if;
      return Result;
   end Process_Arguments;

   function Process_Arguments
     (Executable : String;
      Argument_1 : String)
   return Sonbal.Process_Arguments.Arguments
   is
      Result : Sonbal.Process_Arguments.Arguments :=
        Process_Arguments (Executable);
      State : Sonbal.Process_Arguments.Append_State;
   begin
      State := Sonbal.Process_Arguments.Append (Result, Argument_1);
      if State /= Sonbal.Process_Arguments.Append_Accepted then
         raise Program_Error with "failed to build test process arguments";
      end if;
      return Result;
   end Process_Arguments;

   function Process_Arguments
     (Executable : String;
      Argument_1 : String;
      Argument_2 : String)
   return Sonbal.Process_Arguments.Arguments
   is
      Result : Sonbal.Process_Arguments.Arguments :=
        Process_Arguments (Executable, Argument_1);
      State : Sonbal.Process_Arguments.Append_State;
   begin
      State := Sonbal.Process_Arguments.Append (Result, Argument_2);
      if State /= Sonbal.Process_Arguments.Append_Accepted then
         raise Program_Error with "failed to build test process arguments";
      end if;
      return Result;
   end Process_Arguments;

end Sonbal_Test_Support;
