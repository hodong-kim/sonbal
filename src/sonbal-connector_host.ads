-- ============================================================================
-- sonbal-connector_host.ads
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================

with Clair.Dynamic_Library;
with Clair.Event_Loop;
with Clair.IO;
with Clair.Status;
with Sonbal.Configuration;
with Sonbal.Connector_ABI;
with System;

package Sonbal.Connector_Host is

  type Context is limited private;

  type Progress_Handler is limited interface;
  type Progress_Handler_Access is access all Progress_Handler'Class;

  --! summary Runs bounded connector progress on the Event Loop owner thread.
  function on_connector_progress
    (handler : in out Progress_Handler)
  return Clair.Status.Code is abstract;

  type Event_Poll_State is
    (Event_Ready, Event_Would_Block, Event_Poll_Failed);

  type Completion_State is
    (Completion_Accepted, Completion_Would_Block, Completion_Failed);

  --! summary Load and initialize exactly one trusted connector plugin.
  --! contract
  --!   plugin_path must be an absolute trusted native-library path.
  --!   When both startup descriptors are valid they must be distinct.
  --!   event_loop must remain alive until finalize succeeds.
  --!   The call consumes cleanup responsibility for every valid startup
  --!   descriptor. They are borrowed by the plugin only during its initialize
  --!   call, then the host closes them and sets each successfully closed caller
  --!   value to INVALID_DESCRIPTOR on success and rollback paths alike.
  --!   Current-process inspection protection is enabled after descriptor
  --!   validation and before the plugin initialize call.
  function initialize
    (self             : aliased in out Context;
     event_loop       : aliased in out Clair.Event_Loop.Context;
     plugin_path      : String;
     configuration_fd : in out Clair.IO.Descriptor;
     credential_fd    : in out Clair.IO.Descriptor;
     max_work_slots   : Sonbal.Configuration.Work_Slot_Count;
     progress_handler : Progress_Handler_Access := null)
  return Clair.Status.Code;

  --! summary Start provider activity after wakeup registration is complete.
  --! notes A failed connector start is required by ABI v1 to roll back to the
  --!   initialized-not-started state, so finalize remains valid.
  function start (self : in out Context) return Clair.Status.Code;

  --! summary Pull one validated connector event into caller-owned buffers.
  --! contract
  --!   This operation runs only on the Event Loop owner thread while the
  --!   connector is started or stopping. Every successful EVENT_REQUEST is
  --!   complete and bounded by the supplied request/correlation capacities.
  function next_event
    (self                 : in out Context;
     request_buffer       : System.Address;
     request_capacity     : Natural;
     correlation_buffer   : System.Address;
     correlation_capacity : Natural;
     item                 : aliased out Sonbal.Connector_ABI.Event;
     state                : out Event_Poll_State)
  return Clair.Status.Code;

  --! summary Offer one bounded terminal MCP response to the connector.
  --! contract
  --!   response_length zero represents a notification with no MCP response.
  --!   Completion_Would_Block consumes neither token nor response bytes.
  function complete_request
    (self            : in out Context;
     token           : Sonbal.Connector_ABI.Request_Token;
     response        : System.Address;
     response_length : Natural;
     state           : out Completion_State)
  return Clair.Status.Code;

  --! summary Begin nonblocking connector shutdown.
  function begin_shutdown (self : in out Context) return Clair.Status.Code;

  function is_initialized (self : Context) return Boolean;
  function is_started (self : Context) return Boolean;
  function shutdown_complete (self : Context) return Boolean;
  function has_failed (self : Context) return Boolean;

  --! summary Release wakeup registration, connector state, and library.
  --! contract
  --!   A started connector must first publish EVENT_SHUTDOWN_COMPLETE.
  --!   Wakeup removal succeeds before plugin finalization can close its
  --!   descriptor. The dynamic library closes only after plugin finalization.
  function finalize (self : in out Context) return Clair.Status.Code;

private

  type Lifecycle_State is
    (Host_Empty,
     Host_Initialized,
     Host_Started,
     Host_Stopping,
     Host_Stopped,
     Host_Quarantined,
     Host_Library_Close_Failed,
     Host_Finalized);

  type Context_Access is access all Context;

  type Callback_Bridge is limited record
    owner : Context_Access := null;
  end record;

  type Context is limited record
    state          : Lifecycle_State := Host_Empty;
    library        : Clair.Dynamic_Library.Handle :=
      Clair.Dynamic_Library.NULL_HANDLE;
    descriptor     : Sonbal.Connector_ABI.Descriptor :=
      (magic            => 0,
       abi_version      => 0,
       descriptor_size  => 0,
       kind             => Sonbal.Connector_ABI.CONNECTOR_UNKNOWN,
       initialize       => null,
       start            => null,
       next_event       => null,
       complete_request => null,
       begin_shutdown   => null,
       finalize         => null);
    instance       : System.Address := System.NULL_ADDRESS;
    wakeup_fd      : Clair.IO.Descriptor := Clair.IO.INVALID_DESCRIPTOR;
    event_loop     : Clair.Event_Loop.Context_Access := null;
    wakeup_source : Clair.Event_Loop.Source_Handle
                  := Clair.Event_Loop.NULL_SOURCE;
    bridge         : aliased Callback_Bridge;
    progress_handler : Progress_Handler_Access := null;
    failed         : Boolean := False;
  end record;

end Sonbal.Connector_Host;
