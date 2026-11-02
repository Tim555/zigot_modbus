# zigot_modbus

A Zig-first Modbus library for operational technology (OT), maintained by Tim555.

**Status: early development.** Includes CRC-16/MODBUS, Modbus TCP codecs,
a protocol-independent TCP transport, and a synchronous client for holding registers, input registers, coils, and discrete inputs.
This is not yet a complete Modbus client or server.

## Design

- Pure Zig and the Zig standard library; no C bindings, libc requirement, or external dependencies.
- Native Zig build system (`build.zig`) and package manifest (`build.zig.zon`).
- Transport-independent protocol core, suitable for embedded and hosted applications.
- Caller-owned buffers and explicit errors planned for codecs; no hidden allocations.
- Optional TCP transport uses caller-supplied `std.Io` with configurable timeouts;
  serial devices and application scheduling remain caller concerns.

## Toolchain and development

The supported, CI-pinned toolchain is **Zig 0.17.0**.
Networking uses `std.Io.net`, not the removed `std.net` API.

```sh
zig build
zig build test
zig build test -Doptimize=ReleaseSafe
zig build check -Dtarget=aarch64-linux
zig fmt --check build.zig build.zig.zon src tests
```

`zig build` registers the source module and installs the example in `zig-out/bin`.
`test` runs unit tests and separate tests through the public package import.
`check` compiles both test suites without executing them, including for cross targets.
CI runs formatting, Debug and ReleaseSafe tests, and a cross-compilation check
on Linux, Windows, and macOS.

`task run` builds and runs the example using `zig` on your PATH. It expects a
Modbus server on `127.0.0.1:5020`; start `test_server/server.py` separately in a
Python environment with `pymodbus==3.6.9`.

## TCP client initialization

Both clients take a caller-owned `std.Io` context. In an executable, receive it
through Zig's `std.process.Init`; in tests, use `std.testing.io`.

```zig
const std = @import("std");
const modbus = @import("zigot_modbus");

pub fn main(init: std.process.Init) !void {
    var client = modbus.SyncTcpModbusClient.init(init.io);
    defer client.disconnect();
    try client.connect("127.0.0.1", 5020);
    var registers: [2]u16 = undefined;
    const count = try client.readHoldingRegister(10, 2, 1, &registers);
    std.debug.print("{any}\n", .{registers[0..count]});
}
```

For protocol-independent I/O, use `TcpClient.init(init.io)` with `connect`,
`send` (all bytes), `receive` (up to the buffer size), and `receiveExact`
(fill the buffer or report EOF). TCP is a byte stream: sends do not define
message boundaries. Calls are synchronous, with a default 5-second connect
timeout and 2-second read/write timeouts.
Hosts must be IPv4 or IPv6 literals, not DNS names.

The I/O backend must outlive the client. Do not copy a connected client or share
it concurrently. `disconnect` is idempotent; reconnecting while connected returns
`AlreadyConnected`. Transport errors and observed EOF close the socket.

### Transport timeouts

Use `TcpClient.initWithOptions(io, options)` to customize the limits:

```zig
var client = modbus.TcpClient.initWithOptions(init.io, .{
    .connect_timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } },
    .read_timeout = .{ .duration = .{ .raw = .fromMilliseconds(500), .clock = .awake } },
    .write_timeout = .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } },
});
defer client.disconnect();
```

Each option accepts a `std.Io.Timeout`: `.none` disables the timeout, `.duration`
starts a new budget per public operation, and `.deadline` uses an absolute
deadline. `send` and `receiveExact` share one deadline across all partial I/O;
receiving another fragment does not restart the timer. Empty-buffer operations
are no-ops on a connected client, even if a configured deadline has expired.

Timeouts return `error.Timeout` and close the connection. Some bytes may already
have been sent or received; reconnect/retry decisions belong to the caller.
Connect races a cancellable connect against a timer because Zig 0.17's threaded
backend does not implement the native connect timeout option. Pending operations
are cancelled and joined before returning, so they cannot outlive caller buffers.
Timed operations require an I/O backend that supports concurrency.

These are transport-operation limits, not a single Modbus transaction deadline.
The Modbus client uses the transport defaults, but its request send, header read,
and payload read each receive their own budget.

## Use as a Zig dependency

Once the repository is available, fetch a specific commit archive:

```sh
zig fetch --save=zigot_modbus https://github.com/Tim555/zigot_modbus/archive/<commit-sha>.tar.gz
```

Replace `<commit-sha>` with a real full commit SHA. Zig records the content hash
in your application's `build.zig.zon`. In the application's `build.zig`:

```zig
const dep = b.dependency("zigot_modbus", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zigot_modbus", dep.module("zigot_modbus"));
```

Then from application code:

```zig
const zigot_modbus = @import("zigot_modbus");
const checksum = zigot_modbus.rtu.crc16(&.{ 0x01, 0x03, 0x00, 0x00, 0x00, 0x0a });
// checksum == 0xcdc5; transmit RTU CRC bytes as 0xc5, 0xcd.
```

## Layout

| Path | Purpose |
| --- | --- |
| `src/root.zig` | Public package API and function codes |
| `src/rtu.zig` | RTU primitives and unit tests |
| `src/modbus_codec.zig` | Modbus frame and PDU encoding/decoding (`modbus_codec`; currently TCP MBAP) |
| `src/tcp_transport.zig` | Protocol-independent `std.Io.net` transport |
| `src/modbus_tcp.zig` | Synchronous Modbus TCP client |
| `tests/root.zig` | Tests using the public module |
| `build.zig` | Module registration and development steps |
| `build.zig.zon` | Native package version, dependencies, and distribution paths |
| `.github/workflows/ci.yml` | Cross-platform CI |

## Roadmap

- PDU codecs: coils, discrete inputs, holding registers, and input registers.
- MBAP header validation and Modbus TCP ADU encode/decode.
- RTU ADU encode/decode, CRC validation, and explicit timing requirements.
- Exception responses, malformed-frame tests, and interoperability fixtures.
- Client/server state machines with caller-provided transport and clocks.

The library is a starting point for development; no live-device interoperability
or production-readiness claims are made.

## License

[MIT](LICENSE).

TCP reads use caller-owned output buffers: `readInputRegister(address, quantity, unit_id, out)`
accepts `[]u16` (1–125 registers); `readCoils` and `readDiscreteInputs` accept
`[]bool` (1–2000 bits). Bits follow address order, with the least significant bit
first on the wire; final-byte padding is ignored. Each method also has a
`Detailed` variant returning a count or the complete Modbus exception payload.
Responses must contain exactly the requested number of registers or packed bytes.

## TCP write operations

The synchronous client supports the standard single and multiple writes:

| Method | Function | Value argument | Successful return |
| --- | --- | --- | --- |
| `writeSingleCoil(address, value, unit_id)` | FC05 | `bool` | `1` |
| `writeSingleRegister(address, value, unit_id)` | FC06 | `u16` | `1` |
| `writeMultipleCoils(address, values, unit_id)` | FC15 | `[]const bool`, 1–1968 values | `values.len` |
| `writeMultipleRegisters(address, values, unit_id)` | FC16 | `[]const u16`, 1–123 values | `values.len` |

Addresses are zero-based wire offsets. Registers are holding registers; input
registers and discrete inputs are read-only. Each method has a `Detailed`
variant returning `WriteResult` (`.count` or the complete `.exception`). The
simple variants return `error.ModbusException` for server exceptions.

```zig
_ = try client.writeSingleCoil(10, true, 1);
_ = try client.writeSingleRegister(20, 0x1234, 1);
_ = try client.writeMultipleCoils(10, &.{ true, false, true }, 1);
_ = try client.writeMultipleRegisters(20, &.{ 0x1234, 0xabcd }, 1);
```

Writes validate the acknowledgment's function, address, and echoed value or
quantity. Invalid quantities and ranges extending beyond address 65535 fail
before transmission. Writes are never retried automatically: a timeout or
connection failure can occur after the server has applied the write.

## Interoperability and decoder robustness

The optional interop harness runs a real **PyModbus 3.6.9** TCP server and its
reference client, then checks this Zig client against the reference results.
It uses an ephemeral loopback port and closes the server after the run.
Install the pinned dependency in an isolated environment if needed:

```bash
python3 -m venv /tmp/modbus-interop-venv
/tmp/modbus-interop-venv/bin/python -m pip install -r test_server/interop-requirements.txt
/tmp/modbus-interop-venv/bin/python test_server/interop.py --artifacts /tmp/interop-debug
/tmp/modbus-interop-venv/bin/python test_server/interop.py --optimize ReleaseSafe --artifacts /tmp/interop-release
zig build fuzz-smoke
```

An existing `test_server/.venv` with the pinned dependency can be used instead.
The harness accepts `--zig PATH`, `--zig-cache-dir PATH`, `--seed N`, and
`--random-cases N` (per function/unit pair). It retains reference vectors, a
JSON report, and Zig output in the artifact directory. The default 352 read cases
cover all four read functions, two units, maximum quantities, bit boundaries,
illegal addresses, transaction rollover, and reconnects. Another 88 write cases
cover FC05/06/15/16, with immediate Zig readback and independent PyModbus
readback of the final state. These tests are
opt-in; `zig build test` requires no Python server.

`fuzz-smoke` runs 20,000 deterministic read/write decoder mutations and six oversized
MBAP-length cases with runtime safety checks. It complements valid-request
interop tests; it is not a coverage-guided fuzz campaign. The reusable
[`modbus-interop` skill](skills/modbus-interop/SKILL.md) describes the workflow
and deeper fuzzing and network-fault tests.
