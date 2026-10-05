-- ============================================================================
-- sonbal_connector_abi_tests.adb
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Interfaces;
with Interfaces.C;
with Sonbal.Connector_ABI;
with Sonbal_Test_Support;
with System;

package body Sonbal_Connector_ABI_Tests is

  use type Interfaces.C.int;
  use type Interfaces.Unsigned_32;
  use type Interfaces.Unsigned_64;
  use type Sonbal.Connector_ABI.Connector_Kind;
  use type Sonbal.Connector_ABI.Event_Kind;
  use type Sonbal.Connector_ABI.Request_Token;
  use type Sonbal.Connector_ABI.Status_Code;
  use type System.Address;

  procedure frozen_identity
    (reporter : in out Clair.Test.Reporter.Context)
  is
    magic      : Interfaces.Unsigned_64;
    version    : Interfaces.Unsigned_32;
    kind       : Sonbal.Connector_ABI.Connector_Kind;
    event_kind : Sonbal.Connector_ABI.Event_Kind;
    pragma Volatile (magic);
    pragma Volatile (version);
    pragma Volatile (kind);
    pragma Volatile (event_kind);
  begin
    magic := Sonbal.Connector_ABI.ABI_MAGIC;
    version := Sonbal.Connector_ABI.ABI_VERSION;
    kind := Sonbal.Connector_ABI.CONNECTOR_OPENAI;
    event_kind := Sonbal.Connector_ABI.EVENT_REQUEST;

    Sonbal_Test_Support.check
      (reporter,
       magic = 16#534F_4E42_414C_4331#,
       "connector ABI magic is frozen");
    Sonbal_Test_Support.check
      (reporter, version = 1, "connector ABI version is one");
    Sonbal_Test_Support.check
      (reporter,
       kind /= Sonbal.Connector_ABI.CONNECTOR_UNKNOWN,
       "OpenAI connector kind is nonzero");
    Sonbal_Test_Support.check
      (reporter,
       event_kind /= Sonbal.Connector_ABI.EVENT_NONE,
       "request event kind is nonzero");
  end frozen_identity;

  procedure bounded_shapes
    (reporter : in out Clair.Test.Reporter.Context)
  is
    parameters : Sonbal.Connector_ABI.Initialize_Parameters;
    event      : Sonbal.Connector_ABI.Event;
  begin
    parameters :=
      (abi_version             => Sonbal.Connector_ABI.ABI_VERSION,
       struct_size             =>
         Sonbal.Connector_ABI.INITIALIZE_PARAMETERS_BYTES,
       maximum_active_requests => 65,
       maximum_request_bytes   => 1_048_576,
       maximum_response_bytes  => 88_129,
       configuration_fd        => 3,
       credential_fd           => 4);
    event :=
      (token                 => 1,
       kind                  => Sonbal.Connector_ABI.EVENT_REQUEST,
       request_length        => 1_048_576,
       correlation_length    =>
         Interfaces.Unsigned_32
           (Sonbal.Connector_ABI.MAXIMUM_DIAGNOSTIC_CORRELATION_BYTES),
       correlation_truncated => 1);

    Sonbal_Test_Support.check
      (reporter,
       Sonbal.Connector_ABI.INITIALIZE_PARAMETERS_BYTES = 28,
       "initialize structure v1 byte size remains frozen");
    Sonbal_Test_Support.check
      (reporter,
       parameters.struct_size =
         Sonbal.Connector_ABI.INITIALIZE_PARAMETERS_BYTES,
       "initialize structure publishes its exact byte size");
    Sonbal_Test_Support.check
      (reporter,
       parameters.maximum_active_requests = 65,
       "initialize structure carries the host active-request bound");
    Sonbal_Test_Support.check
      (reporter,
       parameters.configuration_fd = 3 and then
         parameters.credential_fd = 4,
       "initialize structure carries separate startup descriptors");
    Sonbal_Test_Support.check
      (reporter,
       event.token /= Sonbal.Connector_ABI.NO_REQUEST_TOKEN,
       "request event uses a nonzero token");
    Sonbal_Test_Support.check
      (reporter,
       event.correlation_length = 256,
       "diagnostic correlation is bounded to 256 bytes");
  end bounded_shapes;

  procedure lifecycle_vocabulary
    (reporter : in out Clair.Test.Reporter.Context)
  is
    descriptor : Sonbal.Connector_ABI.Descriptor;
    status     : Sonbal.Connector_ABI.Status_Code;
    event_kind : Sonbal.Connector_ABI.Event_Kind;
    instance   : System.Address;
    pragma Volatile (status);
    pragma Volatile (event_kind);
    pragma Volatile (instance);
  begin
    descriptor :=
      (magic            => Sonbal.Connector_ABI.ABI_MAGIC,
       abi_version      => Sonbal.Connector_ABI.ABI_VERSION,
       descriptor_size  => Sonbal.Connector_ABI.DESCRIPTOR_BYTES,
       kind             => Sonbal.Connector_ABI.CONNECTOR_OPENAI,
       initialize       => null,
       start            => null,
       next_event       => null,
       complete_request => null,
       begin_shutdown   => null,
       finalize         => null);
    status := Sonbal.Connector_ABI.STATUS_WOULD_BLOCK;
    event_kind := Sonbal.Connector_ABI.EVENT_SHUTDOWN_COMPLETE;
    instance := Sonbal.Connector_ABI.NULL_INSTANCE;

    Sonbal_Test_Support.check
      (reporter,
       descriptor.descriptor_size = Sonbal.Connector_ABI.DESCRIPTOR_BYTES,
       "descriptor publishes its exact byte size");
    Sonbal_Test_Support.check
      (reporter,
       descriptor.kind = Sonbal.Connector_ABI.CONNECTOR_OPENAI,
       "descriptor carries connector identity");
    Sonbal_Test_Support.check
      (reporter,
       status /= Sonbal.Connector_ABI.STATUS_OK,
       "would-block is distinct from success");
    Sonbal_Test_Support.check
      (reporter,
       event_kind = Sonbal.Connector_ABI.EVENT_SHUTDOWN_COMPLETE,
       "shutdown completion is an explicit event");
    Sonbal_Test_Support.check
      (reporter,
       instance = System.NULL_ADDRESS,
       "null connector instance uses the native null address");
  end lifecycle_vocabulary;

  procedure run (reporter : in out Clair.Test.Reporter.Context) is
  begin
    Clair.Test.Reporter.run_scenario
      (reporter, "frozen identity", frozen_identity'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "bounded shapes", bounded_shapes'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "lifecycle vocabulary", lifecycle_vocabulary'access);
  end run;

end Sonbal_Connector_ABI_Tests;
