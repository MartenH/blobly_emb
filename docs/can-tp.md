# CAN-TP — ISO-TP on CAN (ISO 15765-2)

The segmented transport UDS runs over on CAN: a message longer than one frame is sent as a first
frame and consecutive frames, paced by the receiver's flow control. This page says which parts of
ISO 15765-2 blobly implements, and how it behaves where the standard leaves the choice to the
implementation. The requirements are [`requirements/can-tp.toml`](../requirements/can-tp.toml)
(`REQ-CAN-TP-*`); the code is [`comm/isotp/isotp.v`](../comm/isotp/isotp.v) (the protocol, one
`Link` per connection) and [`comm/diag/step.v`](../comm/diag/step.v) (how a diagnostic server feeds
it frames and sends what it produces).

`Link` works on bare 8-byte PDUs and knows nothing about CAN ids or the driver: its owner filters
received frames by id and stamps the transmit id. It is no-alloc, with one reassembly buffer and
one transmit buffer of `max_payload` bytes each, and poll-based: `on_frame` takes a received PDU,
`poll` gives the next PDU to send, `tick` runs the timers, `send` starts a message and `take` hands
over a completed one.

## 1. What is supported

| Feature | Supported | Not supported |
|---|---|---|
| Frame types | single (SF), first (FF), consecutive (CF), flow control (FC). An FC received may be CTS, WAIT or OVFLW | — |
| Flow control we send | CTS, and OVFLW for a first frame too long to hold | WAIT: we never send one |
| Addressing | **normal addressing, 11-bit identifiers**: one request id and one response id per connection | 29-bit normal addressing, normal fixed (`0x18DA…`), extended (target address in byte 0) and mixed addressing. `[isotp]` refuses an id above `0x7FF`, and a frame with a 29-bit id is never this connection's |
| Functional addressing | single-frame requests on `functional_id` (§3.6) | multi-frame functional requests (ISO allows only single frames anyway) |
| Frame size (TX_DL) | **8**. On a CAN-FD bus the same 8-byte PDUs go out as CAN-FD frames (FDF set; BRS set unless the image is built with `BLOB_FDCAN_NOBRS`) | TX_DL above 8: the FD single-frame escape (`SF_DL` in byte 1) and 64-byte consecutive frames |
| Message length | 1 to **520 bytes** (`isotp.max_payload`) | 521 to 4095 bytes, and the escape first frame (`FF_DL` above 4095). Both are refused with OVFLW (§3.4) |
| Padding | every frame we send has DLC 8, unused bytes `0x00` | a configurable fill byte. We accept received frames shorter than 8 (§3.5) |
| Timers | N_Bs and N_Cr, both 1000 ms; WFTmax 16 (§3.1). N_Bs also bounds a send whose frames stop leaving, which is N_As's job | N_As as a timer of its own; **N_Ar**: nothing bounds our own flow control waiting for room in the transmit FIFO (§3.1); the N_Br and N_Cs performance targets |
| Connections | one per node: the diagnostic server's (`[isotp]`). Its bootloader serves the same one | a second diagnostic connection (refused at generation, [diagnostics.md](diagnostics.md) §7) |

The same `Link` also carries a few non-diagnostic streams (§4); those use other ids but the same
protocol code.

## 2. Configuration: `[isotp]`

```toml
[isotp]
bus           = "can0"   # the CAN bus the connection runs on
rx_id         = 0x7E0    # physical requests arrive on this id (11-bit)
tx_id         = 0x7E8    # responses are sent on this id (11-bit)
functional_id = 0x7DF    # optional: functional requests, single frames only
bs            = 0        # block size we grant in our flow control (0 = the whole message)
stmin_ms      = 0        # STmin we ask the sender to keep, in milliseconds
```

| Key | Range | Default | Notes |
|---|---|---|---|
| `rx_id`, `tx_id` | `0x000`–`0x7FF` | — | 11-bit only |
| `functional_id` | `0x001`–`0x7FF` | absent = none | 11-bit only; 0 also means none |
| `bs` | 0–255 | 0 | one byte on the wire |
| `stmin_ms` | 0–127 | 0 | milliseconds only: the microsecond codes `0xF1`–`0xF9` cannot be asked for |

A value outside its range is refused when the node is generated, never narrowed
(REQ-CAN-TP-020). N_Bs, N_Cr and WFTmax are not configurable: every owner of a `Link` calls
`init_defaults()`. The full key list is in [config-reference.md](config-reference.md).

## 3. Where the standard leaves the choice: what we do

![The transmit and receive state machines of a Link](can-tp-states.drawio.svg)

### 3.1 Timers

![A 27-byte transfer with BS = 2: where N_Bs, N_Cr and STmin run](can-tp-sequence.drawio.svg)

| Timer | Value | Started | On expiry |
|---|---|---|---|
| **N_Bs** (sender waits for FC) | 1000 ms | when our first frame, or the last consecutive frame of a block, is handed to the CAN controller; restarted by each FC.WAIT | the transmission is abandoned and counted in `tx_aborts` |
| N_Bs as a **stall bound while sending CFs** | 1000 ms | on each CTS, refreshed by each CF handed over | the transmission is abandoned and counted. This covers a transmit FIFO that stays full (bus-off, nobody acknowledging), which ISO catches with N_As |
| **N_Cr** (receiver waits for CF) | 1000 ms | when our CTS is handed to the controller, at the first frame and at each block boundary; restarted by each CF in sequence | the partial message is discarded and no flow control is owed. Nothing is reported: the sender finds out from its own N_Bs or N_As |
| **WFTmax** | 16 | counts FC.WAIT frames in a row within one block | the next WAIT after 16 abandons the transmission (counted) |

1000 ms is the timeout value the standard gives for N_Bs and N_Cr. The timers start when a frame
is handed to the controller, not on its transmit confirmation: the `Link` never sees a
confirmation. An FC arriving after N_Bs has expired does not revive the transmission
(REQ-CAN-TP-007), and neither does a CF arriving after N_Cr (REQ-CAN-TP-008). N_Cr is not armed
while our CTS is still waiting for room in the transmit FIFO, because the sender is then correctly
waiting for it. **Nothing bounds that wait** (ISO's N_Ar): with a transmit FIFO that never drains
(bus-off, nobody acknowledging) the reception stays in progress, the link never goes idle, S3 is
held and functional requests are dropped until the FIFO moves. The DoIP gateway bounds it with its
own stall timer (§4); the diagnostic server and the bootloader do not yet.

### 3.2 The flow control we send

- **BS and STmin** are `bs` and `stmin_ms` from `[isotp]`, both 0 by default: the whole message
  in one block, frames as fast as the sender likes. With `bs` > 0 a new CTS goes out after every
  `bs` consecutive frames.
- **Never WAIT.** We always have a buffer ready, so we answer a first frame with CTS or OVFLW at
  once.
- **We don't police the sender.** We don't check that a sender keeps our STmin or stops at our
  block size. ISO 15765-2 leaves that to the sender (and the scope comment in `can-tp.toml` says
  so).

### 3.3 The flow control we receive, as a sender

- **BS**: we send at most that many consecutive frames, then wait for the next FC. 0 sends the
  rest without waiting (REQ-CAN-TP-004).
- **STmin**: at least that long between consecutive frames. `0x00`–`0x7F` are 0–127 ms and
  `0xF1`–`0xF9` are 100–900 µs (REQ-CAN-TP-005). A **reserved value** (`0x80`–`0xF0`,
  `0xFA`–`0xFF`) is read as `0x7F`, 127 ms, the slowest legal value (REQ-CAN-TP-006).
  The owner sends at most one frame per pass while it is pacing, so the real gap is STmin rounded
  up to its pass period (the comm thread's tick on a target, at least 1 ms). A microsecond STmin
  therefore comes out as one pass.
- **WAIT** restarts N_Bs, up to WFTmax in a row (§3.1).
- **OVFLW**, or a flow status the standard does not define (3–15), abandons the transmission at
  once and counts it, without waiting for N_Bs (REQ-CAN-TP-010).
- **An FC we are not waiting for** (no transmission in flight, or one in the middle of sending
  CFs) is ignored.

### 3.4 Receiving: what is accepted, ignored or abandoned

| Received | What we do |
|---|---|
| SF with `SF_DL` 1–7 | delivered as a complete message (REQ-CAN-TP-003) |
| SF with `SF_DL` 0 (the FD escape included) or above 7 | ignored |
| FF with `FF_DL` 8–520 | reception starts, CTS sent |
| FF with `FF_DL` 1–7 | ignored (a message that fits a single frame must be sent as one) |
| FF with `FF_DL` 521–4095, or the escape FF (`FF_DL` = 0, 32-bit length) | answered with FC **OVFLW** so the sender fails at once instead of waiting out its N_Bs (REQ-CAN-TP-015). Like any first frame, it ends a reception in progress |
| CF with the expected sequence number | appended. Numbers run 1…15, 0, 1… (REQ-CAN-TP-001) |
| CF with the wrong sequence number | the reception is abandoned and nothing of it is delivered. The next FF starts a new one (REQ-CAN-TP-011) |
| CF with no reception in progress | ignored |
| A valid SF (`SF_DL` 1–7) or FF (`FF_DL` 8 or more) **while a reception is in progress** | the partial message is discarded and the new frame handled as a new reception (REQ-CAN-TP-012). A pending OVFLW is dropped too. An SF or FF that is ignored (rows above) leaves the reception running |
| A reserved PCI type (`0x4_`–`0xF_`) | ignored |
| A frame with a 29-bit id, or an id other than `rx_id` / `functional_id` | not this connection's |

None of these outcomes is reported as an error code. ISO's `N_USData.indication` results
(`N_WRONG_SN`, `N_UNEXP_PDU`, `N_TIMEOUT_Cr`, …) have no counterpart: a reception that fails
simply delivers nothing. The tester sees it as a missing response.

### 3.5 Frame length (CAN_DL) on reception

We send every frame with DLC 8, but we accept a frame shorter than 8 bytes as long as it carries
everything its PCI announces. A frame too short for its PCI is dropped before the protocol sees it,
as if it never arrived, so bytes that did not arrive are never read (`Link.truncated`,
REQ-CAN-TP-013):

| Frame | Shortest accepted |
|---|---|
| SF | `SF_DL` + 1 bytes |
| FF | 8 bytes |
| CF | 8 bytes, unless it carries the last bytes of the message (then PCI + what is left) |
| FC | 3 bytes (PCI, BS, STmin) |

A frame **longer** than 8 bytes (a CAN-FD frame) is read as its first 8 bytes. That is right for a
tester using TX_DL = 8 on CAN FD, which is what blobly_net does. A tester using TX_DL = 64 is not
supported: a single frame it sends in a frame longer than 8 bytes (the escape format) is ignored, as
`SF_DL` reads as 0, and its multi-frame messages time out (N_Cr), since we read 7 bytes of each
63-byte consecutive frame. A short single frame it sends in an 8-byte frame is accepted.

### 3.6 Functional requests

A request on `functional_id` must be a single frame: PCI `0x0N` with N from 1 to 7, and the frame
long enough to hold it. Anything else on that id is discarded and does not disturb the physical
connection (REQ-CAN-TP-019). A valid one is served the moment it is read, in bus order, so a
functional 0x28 gates the very next frame. Its answer, if any, goes out on `tx_id` like a physical
answer. It is **dropped, not queued**, while the physical connection is busy in either direction or
a reset is pending: a functional TesterPresent is periodic and simply comes again. The bootloader
serves no functional requests.

### 3.7 Transmitting, and half duplex at the server

- **One message at a time per connection.** `send` refuses a message while another is in flight,
  or one of 0 or more than 520 bytes. Nothing is queued; the owner asks `busy()` (REQ-CAN-TP-014,
  REQ-CAN-TP-016).
- **1–7 bytes go as a single frame**, longer messages as a first frame and consecutive frames.
- **A frame the CAN driver refuses** (the channel would not take it) abandons the transmission
  rather than retrying it, because the receiver could never reassemble the rest
  (REQ-CAN-TP-018). The owner asked for that abort, so it is not counted in `tx_aborts`.
- **Abandoned transmissions are counted** (`tx_aborts`: N_Bs, WFTmax, OVFLW, an undefined flow
  status), so an owner can tell a message that was given up from one that was sent. Both leave
  the link free (REQ-CAN-TP-017). `progress` counts the frames that moved a transfer forward, for
  an owner that bounds a stalled exchange.
- **The server is half duplex.** A `Link` keeps receive and transmit state apart, but the
  diagnostic server takes a request only once the previous answer has left. A request that
  completes while an answer is still being sent is **dropped**: the tester has broken the
  half-duplex rule and will retry. A request that completes while a reset is pending is dropped
  as well ([`comm/diag/step.v`](../comm/diag/step.v) `take_request`).

## 4. Who runs a `Link`

| Owner | Ids | Flow control it grants | Notes |
|---|---|---|---|
| Diagnostic server ([`comm/diag`](../comm/diag/diag.v)): the host bridge, and the ThreadX comm thread on a target | `[isotp]` `rx_id` / `tx_id` / `functional_id` | `bs`, `stmin_ms` | the connection this page describes |
| Bootloader ([`boot/target`](../boot/target/main.v), `diag.serve_step`) | the node's `[isotp]`, from `gen/boot_gen.h` | the node's `bs`, `stmin_ms` | same bus, ids, frame format; no functional requests ([bootloader.md](bootloader.md)) |
| DoIP gateway router ([`comm/diagroute`](../comm/diagroute/diagroute.v)) | each routed node's request / response ids | BS 8, STmin 0 | the gateway acting as a **tester** on CAN. Besides the ISO timers: an exchange whose frames stop moving for 5 s is ended (`stall_us`), and an answer is awaited 6 s after the request left (`answer_wait_us`: P2*max plus 1 s) ([net.md](net.md)) |
| Shell response ([`comm/shell`](../comm/shell/shell.v)) and trace dump ([`comm/trace`](../comm/trace/module.v)) | a stream id plus a separate flow-control id (`out` / `fc`, `record` / `dump_fc`) | — (they send messages, never receive one) | one ISO-TP message per response or dump block; the request is a plain frame, not ISO-TP ([onboard_trace.md](onboard_trace.md)). Every frame on the flow-control id reaches the link today, so a first frame there would start a reception and put a CTS into the stream |

## 5. Verification

Every requirement in `requirements/can-tp.toml` is verified by a unit test:
[`comm/isotp/isotp_test.v`](../comm/isotp/isotp_test.v) for the protocol,
[`comm/diag/diag_test.v`](../comm/diag/diag_test.v) and
[`comm/diag/step_test.v`](../comm/diag/step_test.v) for the frame intake and the driver-refusal
abort, and [`tools/loom2v/diag_target_test.v`](../tools/loom2v/diag_target_test.v) for the
configuration ranges. The status table is [traceability.md](traceability.md). On the bus, blobly_net's
ISO-TP and UDS client exchanges single- and multi-frame messages with every example's server, on
classic CAN and on zone_a's CAN-FD bus.
