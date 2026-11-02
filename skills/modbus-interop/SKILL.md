---
name: modbus-interop
description: Test Modbus TCP interoperability between this Zig client and an independent server/client stack, and exercise decoder robustness with reproducible randomized cases. Use for Modbus interoperability or fuzz-testing requests.
---

# Modbus interoperability

Use an independent implementation as the peer and reference client. For the
`zigot_modbus` repository, use the maintained harness in `test_server/interop.py`
and `tests/interop.zig`, rather than modifying the example or implementing a
replacement server in Zig. Locate the repository from the working directory;
if elsewhere, ask for its location. Read the build configuration and local
instructions, and preserve existing changes.

## Run the real-stack comparison

1. Inspect `test_server/interop-requirements.txt` and the installed version.
   The harness pins **PyModbus 3.6.9** intentionally. Its `slave=` and
   `zero_mode=True` API differs from newer releases. Use the existing
   `test_server/.venv/bin/python` if its version matches. Otherwise create an
   isolated venv (for example under `/tmp`) and install the pinned requirements;
   follow the environment's network and execution permission mechanism.
   Do not silently upgrade or change a shared Python environment.
2. Run from the repository root:

   ```bash
   test_server/.venv/bin/python test_server/interop.py --artifacts /tmp/modbus-interop-run
   ```

   Use a fresh artifact directory for each run. The harness binds only
   `127.0.0.1` on an OS-assigned port, checks readiness, seeds two distinct units,
   runs PyModbus's client, then compares actual reference-client values with the
   Zig client. It closes its server on success or failure. Use `--zig PATH`
   and `--zig-cache-dir PATH` when needed; select a real compatible Zig binary.
   If socket or cache access is denied, request the required execution approval.
3. Run once in Debug and once with `--optimize ReleaseSafe`. Defaults cover all
   four read functions, minimum and maximum quantities, bit/byte boundaries,
   nonzero and end-of-map addresses, register high bits, two unit IDs, illegal
   addresses, persistent connections, reconnects, and transaction-ID rollover.
   The reference client checks deterministic datastore expectations before its
   results become Zig vectors. The Zig client also checks output sentinels.
4. Retain `report.json`, `vectors.json`, `vectors.zig`, and `zig.log`, and report
   the actual version, seed, case count, modes and results. Expected Modbus
   illegal-address responses are passing cases, not server errors. On a
   failure, isolate the smallest function/unit/address/quantity case and keep
   the original artifacts before changing the implementation or oracle.

Increase `--random-cases N` and vary `--seed N` for a bounded valid-request
campaign. A seed plus the pinned stack and retained vectors makes failures
reproducible. A passing self-test of the Python client alone is insufficient:
the Zig client must perform the same reads against that live server.

The library currently implements a client, not a server. Do not claim reverse
server interoperability. A second independent stack or actual device can be
added when broader interoperability is requested. Keep those results separate.

## Fuzzing and fault injection

Fuzzing complements interoperability. Use two different oracles:

- Valid randomized reads: compare Zig values/counts/exceptions to the independent
  client and seeded map using the harness above.
- Malformed responses: require bounded output, no panic or out-of-bounds access,
  no hang, and appropriate rejection. A normal server will not produce these;
  exercise codecs directly or use a deliberately faulty loopback peer.

Run `zig build fuzz-smoke` for the bounded deterministic mutation smoke test
(20,000 mutations plus oversized MBAP-length cases). It targets the four read
response decoders and exception decoder. It is **not** a coverage-guided fuzz
campaign and does not cover every diagnostic parser or TCP state transition.
Run `zig build test` after fixes; preserve minimized crashes as regression tests.
Debug/ReleaseSafe checks are essential for integer and bounds errors.

For deeper fuzzing, inspect the installed Zig `std.testing.fuzz`/Smith API and
build help instead of assuming older fuzz APIs. Seed a coverage-guided corpus
with valid FC01–04 responses and exceptions, then mutate MBAP length/IDs,
function, byte count, truncation, quantity/output-capacity boundaries, and
near-overflow lengths. Use an explicit time budget and save crash inputs.
Round-trip tests alone can preserve a shared encoder/decoder bug.

For network faults, use a bounded loopback proxy or fake peer to split headers
and payloads, coalesce responses, close mid-frame, delay beyond timeouts, and
send mismatched IDs/functions. Check reconnection and subsequent-request
behavior. An ordinary loopback exchange does not prove fragmentation behavior.
Only run active fuzzing against the local test process or a specifically
authorized target; the default workflow never contacts a PLC or production bus.

## References and known checks

- [PyModbus 3.6.9 client API](https://pymodbus.readthedocs.io/en/v3.6.9/source/client.html)
- [PyModbus 3.6.9 examples](https://pymodbus.readthedocs.io/en/v3.6.9/source/examples.html)
- Installed pinned source under the venv is authoritative for datastore/listener APIs.

The first campaign found arithmetic overflows for valid 125-register responses
(`9 + byte_count` evaluated as u8) and near-65535 MBAP lengths (`6 + length`
evaluated as u16). The fix widens wire-length fields to `usize` before addition.
Keep those boundary regressions even if a longer random campaign passes.
