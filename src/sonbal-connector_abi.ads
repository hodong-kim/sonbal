-- ============================================================================
-- sonbal-connector_abi.ads
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Interfaces;
with Interfaces.C;
with System;

package Sonbal.Connector_ABI is

  use type Interfaces.C.int;

  ABI_MAGIC : constant Interfaces.Unsigned_64 := 16#534F_4E42_414C_4331#;
  ABI_VERSION : constant Interfaces.Unsigned_32 := 1;

  DESCRIPTOR_SYMBOL : constant String := "sonbal_connector_descriptor_v1";

  MAXIMUM_DIAGNOSTIC_CORRELATION_BYTES : constant Positive := 256;

  type Status_Code is new Interfaces.C.int
    with Convention => C;

  STATUS_OK                 : constant Status_Code := 0;
  STATUS_WOULD_BLOCK        : constant Status_Code := 1;
  STATUS_INVALID_ARGUMENT   : constant Status_Code := 2;
  STATUS_INVALID_STATE      : constant Status_Code := 3;
  STATUS_STARTUP_FAILED     : constant Status_Code := 4;
  STATUS_RESOURCE_EXHAUSTED : constant Status_Code := 5;
  STATUS_INTERNAL_ERROR     : constant Status_Code := 6;

  type Connector_Kind is new Interfaces.Unsigned_32
    with Convention => C;

  CONNECTOR_UNKNOWN : constant Connector_Kind := 0;
  CONNECTOR_OPENAI  : constant Connector_Kind := 1;

  type Event_Kind is new Interfaces.Unsigned_32
    with Convention => C;

  EVENT_NONE              : constant Event_Kind := 0;
  EVENT_REQUEST           : constant Event_Kind := 1;
  EVENT_REQUEST_ABANDONED : constant Event_Kind := 2;
  EVENT_FATAL             : constant Event_Kind := 3;
  EVENT_SHUTDOWN_COMPLETE : constant Event_Kind := 4;

  type Request_Token is new Interfaces.Unsigned_64
    with Convention => C;

  NO_REQUEST_TOKEN : constant Request_Token := 0;

  NULL_INSTANCE : constant System.Address := System.NULL_ADDRESS;

  --! summary Startup parameters borrowed by one connector initialization.
  --! contract
  --!   abi_version and struct_size must identify this exact v1 layout.
  --!   maximum_active_requests bounds request tokens concurrently handed to
  --!   the host through EVENT_REQUEST and not yet completed or abandoned.
  --!   A connector may keep a separate provider-side prefetch queue, but that
  --!   queue must be independently bounded and must not become host execution
  --!   admission.
  --!   configuration_fd and credential_fd are read-only startup descriptors
  --!   borrowed only for the duration of initialize. INVALID_STARTUP_FD means
  --!   that the corresponding input is absent. The connector may copy bounded
  --!   configuration or credential bytes into connector-owned state but must
  --!   not retain or close either descriptor itself. Provider-specific
  --!   configuration syntax remains connector-owned and opaque to the host.
  type Initialize_Parameters is record
    abi_version             : Interfaces.Unsigned_32;
    struct_size             : Interfaces.Unsigned_32;
    maximum_active_requests : Interfaces.Unsigned_32;
    maximum_request_bytes   : Interfaces.Unsigned_32;
    maximum_response_bytes  : Interfaces.Unsigned_32;
    configuration_fd        : Interfaces.C.int;
    credential_fd           : Interfaces.C.int;
  end record
    with Convention => C;

  INVALID_STARTUP_FD : constant Interfaces.C.int := -1;

  INITIALIZE_PARAMETERS_BYTES : constant Interfaces.Unsigned_32 :=
    Interfaces.Unsigned_32
      (Initialize_Parameters'Size / System.Storage_Unit);

  --! summary One connector-to-host lifecycle event.
  --! contract
  --!   EVENT_REQUEST carries one nonzero token and lengths for bytes copied
  --!   by next_event.
  --!   EVENT_REQUEST_ABANDONED carries the nonzero token of one request whose
  --!   provider-side response path no longer exists.
  --!   EVENT_FATAL and EVENT_SHUTDOWN_COMPLETE carry no request token.
  --!   EVENT_SHUTDOWN_COMPLETE is valid only after every live request token has
  --!   been retired by successful completion or explicit abandonment.
  --!   A request token is unique among all live requests in one connector
  --!   instance and is retired only by successful completion or abandonment.
  type Event is record
    token                 : Request_Token;
    kind                  : Event_Kind;
    request_length        : Interfaces.Unsigned_32;
    correlation_length    : Interfaces.Unsigned_32;
    correlation_truncated : Interfaces.Unsigned_32;
  end record
    with Convention => C;

  EVENT_BYTES : constant Interfaces.Unsigned_32 :=
    Interfaces.Unsigned_32(Event'Size / System.Storage_Unit);

  --! summary Construct one initialized connector instance without starting I/O.
  --! ownership
  --!   On STATUS_OK, instance becomes connector-owned state and wakeup_fd is a
  --!   connector-owned nonblocking descriptor borrowed by the host until
  --!   finalization.
  --!   On every non-OK return, instance is null, no descriptor ownership is
  --!   published, and initialization has rolled back its private resources.
  type Initialize_Access is access function
    (parameters : access constant Initialize_Parameters;
     instance   : access System.Address;
     wakeup_fd  : access Interfaces.C.int)
  return Status_Code
    with Convention => C;

  --! summary Start provider I/O after the host has registered the wakeup FD.
  --! contract
  --!   instance must be initialized and not previously started.
  --!   No provider request may be published before this call succeeds.
  --!   On every non-OK return, the connector must synchronously roll back any
  --!   partial provider activity and return to the initialized-not-started
  --!   state so the host may call finalize directly.
  type Start_Access is access function
    (instance : System.Address)
  return Status_Code
    with Convention => C;

  --! summary Copy the next connector lifecycle event into host-owned storage.
  --! contract
  --!   Request and diagnostic-correlation buffers are caller-owned and are
  --!   borrowed only for this call. Null is valid only when the matching
  --!   capacity is zero.
  --!   Every non-OK return leaves the next queued event unconsumed.
  --!   STATUS_WOULD_BLOCK performs no request-lifecycle state transition and
  --!   means no event is currently available. Before returning WOULD_BLOCK,
  --!   the connector must consume or clear the wakeup readiness associated
  --!   with all events observed by this drain. A later transition from no
  --!   event to available work must make the wakeup descriptor readable again.
  --!   This rule must be race-safe with concurrent provider workers so the
  --!   Event Loop cannot lose an event between the final dequeue and readiness
  --!   clearing.
  --!   On EVENT_REQUEST, the complete MCP JSON payload is copied into the
  --!   request buffer and optional non-authority diagnostic correlation bytes
  --!   are copied into the correlation buffer.
  type Next_Event_Access is access function
    (instance             : System.Address;
     request_buffer       : System.Address;
     request_capacity     : Interfaces.Unsigned_32;
     correlation_buffer   : System.Address;
     correlation_capacity : Interfaces.Unsigned_32;
     result_event         : access Event)
  return Status_Code
    with Convention => C;

  --! summary Complete one live connector request.
  --! contract
  --!   token must identify a live request.
  --!   A zero response length means the MCP request was a notification and has
  --!   no MCP response body; the connector still performs any provider-owned
  --!   terminal acknowledgement required for that command.
  --!   A nonzero response is one complete MCP JSON response.
  --!   STATUS_WOULD_BLOCK consumes neither the token nor response bytes; the
  --!   host retains the identical response and retries only after connector
  --!   progress is signalled.
  --!   STATUS_OK consumes the request token. Every other non-OK return also
  --!   leaves token ownership with the host unless an explicit
  --!   EVENT_REQUEST_ABANDONED has already retired it.
  type Complete_Request_Access is access function
    (instance        : System.Address;
     token           : Request_Token;
     response        : System.Address;
     response_length : Interfaces.Unsigned_32)
  return Status_Code
    with Convention => C;

  --! summary Stop new provider ingress and begin finite connector settlement.
  --! contract
  --!   This is a nonblocking transition from running to stopping.
  --!   The connector eventually publishes EVENT_SHUTDOWN_COMPLETE.
  --!   A non-OK return leaves the connector in the running state with no
  --!   partial shutdown transition, so the host retains ordinary ownership.
  type Begin_Shutdown_Access is access function
    (instance : System.Address)
  return Status_Code
    with Convention => C;

  --! summary Release one initialized or completely stopped connector instance.
  --! contract
  --!   Finalization is valid for an initialized instance that was never
  --!   started or for a started instance after EVENT_SHUTDOWN_COMPLETE.
  --! ownership
  --!   On success, connector state and its wakeup descriptor are released and
  --!   instance is set to null.
  --!   On non-OK, instance remains unchanged, its wakeup descriptor remains
  --!   open, and cleanup ownership remains with the host. The connector must
  --!   leave finalization retryable; the host must not unload the library
  --!   while that ownership remains.
  type Finalize_Access is access function
    (instance : access System.Address)
  return Status_Code
    with Convention => C;

  --! summary Exact v1 dynamic connector descriptor.
  --! contract
  --!   The descriptor is exported as the data symbol
  --!   sonbal_connector_descriptor_v1.
  --!   The host requires exact magic, ABI version, descriptor size, known
  --!   connector kind, and nonnull entry points before initialization.
  type Descriptor is record
    magic            : Interfaces.Unsigned_64;
    abi_version      : Interfaces.Unsigned_32;
    descriptor_size  : Interfaces.Unsigned_32;
    kind             : Connector_Kind;
    initialize       : Initialize_Access;
    start            : Start_Access;
    next_event       : Next_Event_Access;
    complete_request : Complete_Request_Access;
    begin_shutdown   : Begin_Shutdown_Access;
    finalize         : Finalize_Access;
  end record
    with Convention => C;

  DESCRIPTOR_BYTES : constant Interfaces.Unsigned_32 :=
    Interfaces.Unsigned_32(Descriptor'Size / System.Storage_Unit);

end Sonbal.Connector_ABI;
