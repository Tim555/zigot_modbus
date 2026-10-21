# zigot_modbus

A Zig-first Modbus library for operational technology (OT), maintained by Tim555.

**Status: project skeleton.** This is not yet a complete Modbus client or server.
Currently includes protocol constants, function codes, and CRC-16/MODBUS with tests.

## Design

- Pure Zig and the Zig standard library; no C bindings, libc requirement, or external dependencies.
- Native Zig build system (`build.zig`) and package manifest (`build.zig.zon`).
- Transport-independent protocol core, suitable for embedded and hosted applications.
- Caller-owned buffers and explicit errors planned for codecs; no hidden allocations.
- TCP sockets, serial devices, timeouts, and scheduling remain application concerns.

## Toolchain and development

The supported, CI-pinned toolchain is **Zig 0.15.2**. Newer Zig releases are not yet validated.

```sh
zig build
zig build test
zig build test -Doptimize=ReleaseSafe
zig build check -Dtarget=aarch64-linux
zig fmt --check build.zig build.zig.zon src tests
```

`zig build` registers the source module; this source-only package does not install a binary.
`test` runs unit tests and separate tests through the public package import.
`check` compiles both test suites without executing them, including for cross targets.
CI runs formatting, Debug and ReleaseSafe tests, and a cross-compilation check
on Linux, Windows, and macOS.

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
| `src/tcp.zig` | TCP constants and future MBAP codec |
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
