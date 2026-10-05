-- ============================================================================
-- sonbal_test_support.ads
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Clair.Test.Reporter;
with Sonbal.Process_Arguments;

package Sonbal_Test_Support is
   procedure Check
     (Reporter  : in out Clair.Test.Reporter.Context;
      Condition : Boolean;
      Name      : String);

   function Process_Arguments
     (Executable : String)
   return Sonbal.Process_Arguments.Arguments;

   function Process_Arguments
     (Executable : String;
      Argument_1 : String)
   return Sonbal.Process_Arguments.Arguments;

   function Process_Arguments
     (Executable : String;
      Argument_1 : String;
      Argument_2 : String)
   return Sonbal.Process_Arguments.Arguments;
end Sonbal_Test_Support;
