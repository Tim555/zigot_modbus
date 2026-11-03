# zigot_modbus

A pure Zig Modbus library with synchronous TCP and RTU clients, a concurrent TCP
server, TCP/RTU frame codecs, and CRC-16/MODBUS. The repository also includes a read-only
polling CLI and a development server for trying the library locally.

**Status: early development (`0.1.0-dev`).** The TCP client and server implement
all eight common read/write functions listed below. The RTU client supports the
same functions over a caller-supplied serial transaction adapter. Native serial
port configuration and bus timing remain caller responsibilities.
The project has no external Zig dependencies or C bindings.

## Contents

- [Capabilities and limits](#capabilities-and-limits)
- [Build and try locally](#build-and-try-locally)
- [Polling CLI](#polling-cli)
- [Include the library in a Zig project](#include-the-library-in-a-zig-project)
- [TCP client](#tcp-client)
- [RTU client](#rtu-client)
- [TCP server](#tcp-server)
- [TCP transport and timeouts](#tcp-transport-and-timeouts)
- [Codecs and RTU CRC](#codecs-and-rtu-crc)
- [Tests and development](#tests-and-development)
- [Repository layout](#repository-layout)

## Capabilities and limits

The supported toolchain is **Zig 0.17.0**, as pinned in CI. Networking uses
`std.Io.net`; callers provide a `std.Io` backend.

| Operation | Function | Client method | Maximum values per request |
| --- | --- | --- | --- |
| Read coils | FC01 | `readCoils` | 2000 bits |
| Read discrete inputs | FC02 | `readDiscreteInputs` | 2000 bits |
| Read holding registers | FC03 | `readHoldingRegister` | 125 registers |
| Read input registers | FC04 | `readInputRegister` | 125 registers |
| Write one coil | FC05 | `writeSingleCoil` | 1 bit |
| Write one holding register | FC06 | `writeSingleRegister` | 1 register |
| Write multiple coils | FC15 | `writeMultipleCoils` | 1968 bits |
| Write multiple holding registers | FC16 | `writeMultipleRegisters` | 123 registers |

All eight functions are supported by the TCP and RTU clients and the TCP server. Every client
operation also has a `Detailed` variant that preserves server exception data.
The CLI exposes the four read functions.

Library addresses are **zero-based wire offsets**, from 0 to 65535. Registers
are raw unsigned 16-bit values; bits are `bool`. Applications handle signed
interpretation, scaling, multi-register values, floating-point formats, and word
order. Input registers and discrete inputs are read-only over Modbus.

Current boundaries:

- TCP hosts and bind addresses must be IPv4 or IPv6 literals; DNS resolution is
  not provided.
- The client performs one synchronous request at a time. Use separate clients
  for concurrent connections.
- Reconnection, retries, polling schedules, and serial I/O belong to the caller.
  The CLI supplies a simple polling loop.
- There is no RTU server or built-in serial port driver. RTU adapters supply
  serial configuration, timeouts, frame boundaries, and bus timing.
- The CLI is a subset of mbpoll-style functionality, with no write commands or
  typed multi-register decoding.

## Build and try locally

From a checkout, with Zig 0.17.0 on your PATH:

```sh
zig build
```

This installs two executables in `zig-out/bin` (with `.exe` on Windows):

| Executable | Purpose |
| --- | --- |
| `zigot_modbus_example` | Configurable Modbus TCP polling CLI |
| `zigot_modbus_server` | Development server on `127.0.0.1:5020`, unit 1 |

Start the server in one terminal:

```sh
zig build run-server
```

In another terminal, read two holding registers three times:

```sh
zig build run -- -p 5020 -r 11 -c 2 -l 0.5 -n 3 127.0.0.1
```

The development server initializes holding-register wire offsets 10 and 11 to
12 and 13. Its input registers start with 14 and 15; discrete inputs start with
`true, false, true, false`; its 2000 coils start as `false`. Other holding
registers in its 125-register table start at zero. Stop the server with Ctrl+C.

If you use [Task](https://taskfile.dev/), `task run-server` starts this server and
`task run` continuously polls its two initialized holding registers.
`task run -- -1` reads them once.

## Polling CLI

```text
zigot_modbus_example [options] HOST
```

Options may appear before or after the host. Supply option values as separate
arguments, such as `-p 5020`.

| Option | Meaning | Default |
| --- | --- | --- |
| `-p`, `--port N` | TCP port, 1–65535 | `502` |
| `-a`, `--unit N` | Unit ID, 0–255 | `1` |
| `-r`, `--start N` | First reference in the selected table | `1` |
| `-c`, `--count N` | Consecutive values to read per poll | `1` |
| `-t`, `--type N` | Table selector; see below | `4` |
| `-0` | Interpret references as zero-based wire offsets | One-based |
| `-l`, `--interval S` | Delay after a successful poll, in seconds | `1` |
| `-n`, `--polls N` | Total polls; `0` means continuous | `0` |
| `-1` | Poll once, equivalent to `-n 1` | — |
| `-h`, `--help` | Print usage and exit | — |

The table selectors follow mbpoll-style numbering and **are not function codes**:

| `-t` value | Table | Modbus function |
| --- | --- | --- |
| `0` | Coils | FC01 |
| `1` | Discrete inputs | FC02 |
| `3` | Input registers | FC04 |
| `4` | Holding registers | FC03 |

### Addresses and timing

CLI references are one-based by default: `-r 11` reads wire offset 10.
With `-0`, `-r 10` reads the same address. References are offsets within the
selected table, **not 40001-style numbers**. For example, a device manual's
holding-register reference 40001 commonly corresponds to `-t 4 -r 1`; check the
device's addressing convention.

The whole requested range must fit within wire offsets 0–65535. Register reads
allow 1–125 values; bit reads allow 1–2000. `-l` accepts fractional seconds from
0.000000001 to 86400. It is a delay between requests, so response time adds to
the actual period. There is no delay after the final poll. Ctrl+C stops
continuous polling.

### Examples

```sh
# Show all options:
zig build run -- --help

# Read two holding registers once, using zero-based offsets:
./zig-out/bin/zigot_modbus_example -p 5020 -0 -r 10 -c 2 -1 127.0.0.1

# Poll eight input registers on unit 2 every two seconds:
zig build run -- -a 2 -t 3 -r 1 -c 8 -l 2 192.168.1.20

# Read four discrete inputs from the development server:
zig build run -- -p 5020 -t 1 -c 4 -1 127.0.0.1

# Read sixteen coils over IPv6:
zig build run -- -t 0 -c 16 -1 ::1
```

### Output and failures

The CLI prints the connection settings, selected table, range, and numbered polls
to stdout. Values appear as unsigned decimal and hexadecimal; bits appear as 0
or 1. For the local holding-register example, each poll looks like:

```text
Poll 1
 Reference       Value       Hex
[       11]         12    0x000c
[       12]         13    0x000d
```

Diagnostics go to stderr. Invalid arguments exit with code 2; connection, read,
and protocol failures exit with code 1. A server exception reports its function,
exception code, and unit. The first failed poll stops the process; the CLI does
not reconnect or retry. Successful completion and `--help` exit with code 0.
The CLI uses the client's default transport timeouts described below.

## Include the library in a Zig project

### Add the dependency

Fetch an immutable commit archive from your application's directory:

```sh
zig fetch --save=zigot_modbus https://github.com/Tim555/zigot_modbus/archive/<commit-sha>.tar.gz
```

Replace `<commit-sha>` with a real full commit SHA. Zig adds the dependency URL
and content hash to your `build.zig.zon`. Pinning a commit makes the dependency
reproducible while the API is evolving.

For local development, you can instead add a path dependency to your
application's `build.zig.zon` dependencies table:

```zig
.dependencies = .{
    .zigot_modbus = .{ .path = "../zigot_modbus" },
},
```

### Import the module

A minimal application `build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dep = b.dependency("zigot_modbus", .{
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "modbus_app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zigot_modbus", .module = dep.module("zigot_modbus") }},
        }),
    });
    b.installArtifact(exe);
}
```

Application code needs only one package import:

```zig
const modbus = @import("zigot_modbus");
```

That import exposes the complete public library:

| Export | Purpose |
| --- | --- |
| `SyncTcpModbusClient` | Synchronous Modbus TCP read/write client |
| `SyncRtuModbusClient`, `RtuTransport` | RTU client and caller-supplied transaction adapter |
| `RtuResult`, `RtuException` | RTU operation counts or exceptions with the original five-byte frame |
| `TcpServer` | Concurrent Modbus TCP server |
| `TcpClient` | Protocol-independent blocking TCP byte transport |
| `Device`, `TcpServerOptions` | Server unit tables and configuration |
| `ReadResult`, `WriteResult` | Detailed operation counts or server exceptions |
| `max_register_count`, `max_bit_count` | Read quantity limits |
| `modbus_codec` | MBAP headers, TCP request encoders, response decoders, exceptions |
| `FunctionCode` | Enum naming the eight supported functions |
| `max_pdu_length` | Maximum PDU size, 253 bytes |

Transport options are available as `TcpClient.Options`. Implementation modules
are private. The former `TcpModbusClient`, `tcp`, and per-function read-result
aliases have been removed; use `SyncTcpModbusClient`, `modbus_codec`, and
`ReadResult` respectively. Former `modbus_tcp.ReadResult`/`WriteResult` and
`tcp_server.Device`/`Options` are now `ReadResult`/`WriteResult` and
`Device`/`TcpServerOptions` at the package root. Read limits are also at the
root; write limits live in `modbus_codec`.
Including the module does not require using the repository's CLI or server
executable in your application.

## TCP client

### Connect and read

A complete `src/main.zig` for the application above:

```zig
const std = @import("std");
const modbus = @import("zigot_modbus");

pub fn main(init: std.process.Init) !void {
    var client = modbus.SyncTcpModbusClient.init(init.io);
    defer client.disconnect();
    try client.connect("127.0.0.1", 5020);

    var registers: [2]u16 = undefined;
    const count = try client.readHoldingRegister(10, 2, 1, &registers);
    std.debug.print("Holding registers: {any}\n", .{registers[0..count]});
}
```

Read signatures use `(address, quantity, unit_id, out)`. `out` is caller-owned
`[]u16` for registers or `[]bool` for bits and must hold at least `quantity`
values. A successful read returns the number of values written. Only that prefix
of the buffer is output. Values follow ascending address order; packed bits are
decoded least significant bit first, and final-byte padding is ignored.
Responses must contain exactly the requested data length.

### Write

On a connected client:

```zig
_ = try client.writeSingleCoil(10, true, 1);
_ = try client.writeSingleRegister(20, 0x1234, 1);
_ = try client.writeMultipleCoils(10, &.{ true, false, true }, 1);
_ = try client.writeMultipleRegisters(20, &.{ 0x1234, 0xabcd }, 1);
```

Single-write signatures are `(address, value, unit_id)`; multiple writes use
`(address, values, unit_id)`. Successful writes return the acknowledged count:
1 for a single write, or `values.len` for a multiple write. The client validates
the response function, address, and echoed value or quantity. Invalid quantities
and ranges extending beyond wire address 65535 fail before transmission.

Writes are never retried automatically. A timeout or broken connection can occur
after the server has applied the write, so an I/O failure does not establish
whether the device changed.

### Exceptions and errors

Simple methods return `error.ModbusException` for a valid server exception.
Use the corresponding `Detailed` method to inspect it:

```zig
var registers: [2]u16 = undefined;
const result = try client.readHoldingRegisterDetailed(10, 2, 1, &registers);
switch (result) {
    .count => |count| std.debug.print("{any}\n", .{registers[0..count]}),
    .exception => |exc| std.debug.print("Function {d}: {s}\n", .{
        exc.function_code,
        @tagName(exc.exception_code),
    }),
}
```

All eight operations have this variant, including
`writeMultipleRegistersDetailed`. `modbus.ReadResult` and `modbus.WriteResult`
contain either `.count` or `.exception`. The exception includes its code/kind,
transaction ID, unit ID, parsed MBAP header, and raw PDU/frame storage. Use
`pdu[0..pdu_len]` and `raw_frame[0..raw_frame_len]` for the valid bytes.
Transport errors and malformed responses remain Zig errors through `try`.

### Ownership

The caller's `std.Io` backend must outlive the client. Do not copy a connected
client or share one concurrently. `disconnect` is idempotent. Connecting an
already connected client returns `AlreadyConnected`. `isConnected` reports local
socket ownership, not remote peer health. Transport I/O errors, timeouts, and
observed EOF close the connection; reconnect/retry decisions are yours.

## RTU client

`SyncRtuModbusClient` offers the same eight operations, argument order, and
`Detailed` variants as the TCP client. Reads use caller-owned output buffers;
writes return acknowledged counts. Unit IDs must be 1–247. Broadcasts (unit 0)
and reserved addresses are rejected before I/O. There are no automatic retries.

The client borrows an `RtuTransport`, which exchanges complete RTU ADUs:

```zig
const modbus = @import("zigot_modbus");

// Call with a serial adapter that is already open and configured.
fn readRtu(transport: modbus.RtuTransport) ![2]u16 {
    var client = modbus.SyncRtuModbusClient.init(transport);
    var registers: [2]u16 = undefined;
    _ = try client.readHoldingRegister(10, 2, 1, &registers);
    return registers;
}
```

`RtuTransport` contains `context: *anyopaque` and an exchange callback with type
`*const fn (*anyopaque, []const u8, []u8) anyerror!usize`. The callback receives a
complete request (address, PDU, CRC), sends it exactly once, fills the response
buffer with exactly one complete ADU including CRC, and returns its length.
It must enforce deadlines and RTU inter-character/inter-frame timing, manage
RS-485 direction if needed, and reject truncated or combined frames. After an
error it must drain/recover to a clean frame boundary before another exchange.
It must not retry writes. The context and port must outlive the client; the
caller closes the port. Serialize all access to the bus, including other clients.

The library encodes requests and validates response CRC, unit, function, exact
length, byte count, and write echoes before returning data. Invalid requests
fail before the callback runs. Protocol and adapter errors propagate through
`try`; a valid exception becomes `error.ModbusException` in simple methods.
`Detailed` methods return `RtuResult`, containing `.count` or `.exception`.
`RtuException` holds `unit_id`, `function_code`, `exception_code`, and the actual
five-byte `raw_frame`; it contains no TCP transaction/header metadata.

A timeout may occur after a write has taken effect. The application decides
whether to retry after recovering the bus. This API implements the RTU protocol
client; it does not open a platform serial port or configure baud/parity/stop bits.

## TCP server

The server maps one or more unit IDs to caller-owned tables. Each table begins
at wire address zero; empty tables reject every address. Different units can use
different backing storage. Unit IDs must be unique, and each table may contain
at most 65536 values.

```zig
const std = @import("std");
const modbus = @import("zigot_modbus");

pub fn main(init: std.process.Init) !void {
    var coils: [2000]bool = @splat(false);
    var registers: [125]u16 = @splat(0);
    const devices = [_]modbus.Device{.{
        .unit_id = 1,
        .coils = &coils,
        .holding_registers = &registers,
        .input_registers = &.{ 12, 13 },
        .discrete_inputs = &.{ true, false },
    }};
    var server = try modbus.TcpServer.init(init.io, "127.0.0.1", 5020, &devices, .{
        .max_clients = 64,
    });
    defer server.deinit();
    try server.serve();
}
```

`serve` blocks while accepting connections. To run the server alongside your
application, replace `try server.serve()` with a concurrent task and cancel/join
it before `deinit`:

```zig
var serving = try init.io.concurrent(modbus.TcpServer.serve, .{&server});
defer _ = serving.cancel(init.io) catch {};
// Run application work here while the server handles clients.
```

The server, device descriptors, tables, and Io backend must outlive `serve`.
Do not copy a running server or invoke `serve` twice concurrently. Cancellation
closes accepted sockets and joins all client tasks. To update or inspect backing
tables while serving, hold `server.data_mutex` using the same Io backend.

Connections run concurrently; requests on each connection execute in wire order,
including pipelined requests. A shared datastore mutex makes each request's
read/write atomic across clients. Network reads and writes do not hold that mutex.

| Server option | Default | Meaning |
| --- | --- | --- |
| `max_clients` | `64` | Active client limit; excess connections wait in the OS backlog |
| `read_timeout` | 30 seconds | Budget per complete header/payload receive |
| `write_timeout` | 5 seconds | Budget for sending a complete response |

Pass these through `TcpServerOptions` to `TcpServer.init`. Timeout fields use
`std.Io.Timeout`; `.none` disables a timeout. Port 0 selects a free port, which
`server.port()` returns. Unknown unit IDs receive exception 0x0b. Invalid
functions, values, and addresses receive protocol exceptions; malformed MBAP
framing closes the affected connection. Peer disconnects and timeouts release
client slots without stopping the listener.

## TCP transport and timeouts

`TcpClient` is independent of Modbus. Use it when supplying your own application
protocol or framing:

| Method | Behavior |
| --- | --- |
| `connect(host, port)` | Connect to an IP literal |
| `send(bytes)` | Send all bytes or fail |
| `receive(buffer)` | Read up to the buffer length; zero on EOF for a nonempty buffer |
| `receiveExact(buffer)` | Fill the buffer or return an error such as `EndOfStream` |
| `disconnect()` | Close the connection; safe to repeat |
| `isConnected()` | Check local socket ownership |

TCP is a byte stream: a send does not define a receive boundary. Buffers are
caller-owned. A failed operation may have sent or received a prefix. Empty
buffer operations are no-ops on a connected client, even with an expired timeout.

Default client budgets are 5 seconds to connect and 2 seconds each to read or
write. Configure the standalone transport with `initWithOptions`:

```zig
var transport = modbus.TcpClient.initWithOptions(init.io, .{
    .connect_timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } },
    .read_timeout = .{ .duration = .{ .raw = .fromMilliseconds(500), .clock = .awake } },
    .write_timeout = .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } },
});
defer transport.disconnect();
```

For a Modbus client, its public transport options can be set before connecting:

```zig
var client = modbus.SyncTcpModbusClient.init(init.io);
defer client.disconnect();
client.transport.options.read_timeout = .{
    .duration = .{ .raw = .fromMilliseconds(500), .clock = .awake },
};
try client.connect("127.0.0.1", 5020);
```

Each timeout accepts `.none`, a relative `.duration`, or an absolute `.deadline`.
`send` and `receiveExact` share one budget across partial I/O; new fragments do
not restart the timer. Timeouts return `error.Timeout` and close the connection.
Timed operations require an Io backend that supports concurrency; pending
operations are cancelled and joined before returning.

These are **transport-operation budgets**, not a single Modbus transaction
deadline. Request send, response header read, and payload read each receive their
own budget when using relative durations. The CLI uses these defaults and has
no timeout option.

## Codecs and RTU CRC

`modbus.modbus_codec` exposes TCP frame operations without opening sockets:

- MBAP header encoding/decoding (`encode_mbap_header`, `decode_mbap_header`).
- Request encoders and response decoders for all eight supported functions.
- Exception decoding (`decode_exception_response`) and diagnostic classification
  (`decode_modbus_error`).
- Header, exception, and error types, plus TCP size and quantity constants.

Encoders write into caller-provided byte buffers and request encoders return the
encoded length. Response decoders validate expected transaction/unit IDs and
write decoded values into caller buffers. Consult
[`src/modbus_codec.zig`](src/modbus_codec.zig) for exact signatures. The maximum
TCP ADU length is 260 bytes, with a 7-byte MBAP header and up to 253 PDU bytes.
The `modbus_codec` module currently handles TCP MBAP framing; it does not provide
serial I/O. It also provides `encode_rtu_frame(unit_id, pdu, out)` and
`decode_rtu_frame(frame)` for address/PDU/CRC framing. RTU frames are at most
`max_rtu_adu_length` (256) bytes. The decoder checks length and CRC and returns a
unit ID and a PDU slice borrowing the input. Encoder input/output must not overlap.

The CRC-16/MODBUS primitive lives in the same codec module:

```zig
const checksum = modbus.modbus_codec.crc16(&.{ 0x01, 0x03, 0x00, 0x00, 0x00, 0x0a });
// checksum == 0xcdc5; an RTU frame transmits 0xc5 followed by 0xcd.
```

The former `modbus.rtu.crc16` path has moved to `modbus.modbus_codec.crc16`;
there is no public `rtu` implementation-module export.

## Tests and development

### Standard checks

```sh
zig build
zig build test
zig build test -Doptimize=ReleaseSafe
zig build check -Dtarget=aarch64-linux
zig build fuzz-smoke
zig fmt --check build.zig build.zig.zon src tests
```

| Build step | Purpose |
| --- | --- |
| `build` (default) | Build and install the CLI and development server |
| `run -- ...` | Build and run the CLI with forwarded arguments |
| `run-server` | Run the fixed local development server |
| `test` | Run library, public API, and CLI parser tests |
| `check` | Compile test suites and CLI without running them; supports cross targets |
| `fuzz-smoke` | Run bounded deterministic decoder mutations |
| `interop-test` | Harness-driven TCP client interop; requires generated vectors |
| `rtu-interop-test` | Harness-driven RTU client interop; use `interop.py --rtu` |

The normal tests require no Python server. They include local loopback networking,
read/write behavior, server concurrency, fragmentation, pipelining, connection
limits, timeouts, and cancellation. CI runs on every push, pull request, and manual dispatch:

- Formatting runs once on Linux.
- Linux, Windows, and macOS each build both executables and run the complete
  regular test suite plus decoder mutation smoke tests in Debug and ReleaseSafe.
- Linux cross-compiles the test suites for aarch64-linux in both modes.
- Separate Linux jobs run TCP client, RTU client, and TCP server interoperability
  against pinned PyModbus in both modes. These jobs retain reports, logs, and
  generated vectors (for client suites) for 14 days, including failed runs.

Matrix failures do not cancel other suites. A newer push cancels an older run
for the same branch or pull request. Interop uses local loopback connections;
RTU physical serial timing remains outside this CI coverage.

`fuzz-smoke` exercises 20,000 deterministic read/write decoder mutations and six
oversized MBAP-length cases with runtime safety checks. It is a bounded regression
check rather than a coverage-guided fuzz campaign.

### Independent interoperability tests

Optional Python harnesses use **PyModbus 3.6.9** as an independent stack. From a
full repository checkout, create an isolated environment:

```sh
python3 -m venv /tmp/modbus-interop-venv
/tmp/modbus-interop-venv/bin/python -m pip install -r test_server/interop-requirements.txt

# Zig client against a PyModbus server:
/tmp/modbus-interop-venv/bin/python test_server/interop.py --artifacts /tmp/interop-debug
/tmp/modbus-interop-venv/bin/python test_server/interop.py --optimize ReleaseSafe --artifacts /tmp/interop-release

# Zig RTU client against the PyModbus RTU framer over loopback TCP:
/tmp/modbus-interop-venv/bin/python test_server/interop.py --rtu --artifacts /tmp/rtu-debug
/tmp/modbus-interop-venv/bin/python test_server/interop.py --rtu --optimize ReleaseSafe --artifacts /tmp/rtu-release

# Zig server against the PyModbus client:
/tmp/modbus-interop-venv/bin/python test_server/server_interop.py
/tmp/modbus-interop-venv/bin/python test_server/server_interop.py --optimize ReleaseSafe
```

An existing `test_server/.venv` with the pinned dependency can also be used.
Harnesses use ephemeral loopback ports and clean up their servers. Both accept
`--zig PATH`, `--zig-cache-dir PATH`, and `--artifacts DIR` to retain logs and a
JSON report. The client harness additionally accepts `--seed N` and
`--random-cases N`, and retains reference vectors in its artifact directory.

Client cases cover all supported functions, two units, quantity/address
boundaries, packed bits, exceptions, transaction rollover, reconnects, and write
readback checked independently through PyModbus. The `--rtu` mode uses PyModbus RTU framing for both the independent reference
client and server, reusing the same seeded read and write cases. The Zig adapter
receives response bytes individually. This tests RTU ADUs and CRC over a local
TCP byte stream, not a serial port, physical RS-485, or RTU silent intervals.
Server tests cover all eight functions, unit routing, boundary quantities, and
16 concurrent clients.
These checks do not establish interoperability with every device or production
readiness. The reusable
[`modbus-interop` skill](skills/modbus-interop/SKILL.md) describes deeper test
workflows. Python harnesses and skills are available in the full checkout and
are not included in the Zig package's distribution paths.

## Repository layout

| Path | Purpose |
| --- | --- |
| `src/root.zig` | Public package exports and function codes |
| `src/main.zig` | Polling CLI and argument tests |
| `src/server_main.zig` | Fixed local development server |
| `src/modbus_tcp_client.zig` | Synchronous Modbus TCP client |
| `src/tcp_server.zig` | Concurrent server and caller-owned device tables |
| `src/tcp_transport.zig` | Protocol-independent TCP transport |
| `src/modbus_codec.zig` | TCP MBAP/PDU codecs, RTU framing/CRC, and diagnostics |
| `src/modbus_rtu_client.zig` | Synchronous RTU client and serial adapter contract |
| `tests/` | Public API, server, interop, and decoder tests |
| `test_server/` | Python interoperability harnesses and pinned requirements |
| `build.zig`, `build.zig.zon` | Build steps, module registration, and package manifest |
| `Taskfile.yml` | Optional convenience commands |
| `.github/workflows/ci.yml` | CI build/test matrix |

## License

[MIT](LICENSE). Maintained by Tim555.
