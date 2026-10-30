# Code review

Date: 2026-10-23

## Scope and validation

Reviewed the current working tree, including uncommitted changes: the Zig protocol core, TCP client, example, unit/public API tests, build configuration, CI, and Python test server. No implementation files were changed.

This is a source-level review. The validation command was cancelled; no successful build, test, formatting, or interoperability run is claimed. The active `zig version` reported **0.17.0**, whereas the README and CI specify **0.15.2**. Re-run validation with the supported toolchain before treating any compiler failure as a repository defect.

Priorities: **P1** = high-impact correctness/reliability issue; **P2** = medium-impact defect or validation gap. Findings below are based on code inspection, not executed reproductions.

## Findings

### 1. P1 — A silent or partially responding peer can block a read indefinitely

**Location:** `src/tcp_client.zig`, `readExact` and `SyncTcpModbusClient.readHoldingRegister`.

The client opens a blocking TCP connection and reads until every requested byte arrives, without a response deadline. A server can accept the request and send nothing, or send an MBAP header advertising a body that never completes. In either case, the calling thread can remain blocked while the connection stays open. `writeAll` also has no application-controlled deadline.

This can stop an application's polling loop indefinitely. Unlike a caller-supplied transport abstraction, this API owns the blocking I/O and exposes no timeout argument.

**Recommendation:** Add configurable transaction deadlines covering request transmission and the complete response. Close/invalidate the connection when a partial exchange times out. Prefer an overall deadline rather than restarting the timeout after each received byte.

**Regression test:** Have a loopback server withhold the response, then separately send only a header or partial payload. Verify bounded completion with a timeout error and defined connection state.

### 2. P1 — Successful responses are not checked against the requested quantity

**Location:** `src/tcp_client.zig`, the final decode call in `readHoldingRegister`; `src/tcp.zig`, `decode_read_holding_registers_response`.

The client checks that the output buffer can hold the requested quantity, but never checks that the server actually returned that quantity. The decoder derives the result count solely from the response byte count.

For example, a request for two registers can receive a structurally valid response containing one register and return success with count `1`. The second output element is left unchanged. Conversely, if the caller provides spare capacity, a response containing more registers than requested is also accepted.

The example compounds the short-response case by printing the entire two-element `result` array, rather than only the returned slice; the unwritten element was initialized as `undefined`.

**Recommendation:** Require the response register count to equal the request quantity, preferably before writing the caller's buffer. Keep a generic frame decoder if useful, but enforce request/response consistency in the client. Print only initialized output in the example.

**Regression test:** Request two registers and return one or three, with sufficient output capacity in the latter case. Both responses should fail with a count/length mismatch.

### 3. P2 — Failed exchanges leave a connected-looking, potentially desynchronized stream

**Location:** `src/tcp_client.zig`, `readHoldingRegister` header validation and I/O error paths; `isConnected`.

After reading the seven-byte header, the client immediately returns on transaction, protocol, unit, or length errors. It neither consumes the remaining response nor closes the connection. The next operation sends another request and can interpret leftover payload bytes as its next MBAP header.

Likewise, an EOF or transport error propagates without clearing `_connected`, so `isConnected()` still reports true after an observed connection failure.

**Recommendation:** Invalidate and close the connection on transport errors and framing failures that leave stream alignment uncertain. Define which errors preserve usability; a fully consumed, valid Modbus exception need not automatically close the connection. Avoid indiscriminately disconnecting for pre-request input-validation errors.

**Regression test:** Send a mismatched header followed by a payload, then attempt another request. Verify that stale bytes cannot become a new header. Also verify disconnected state after EOF.

### 4. P2 — Calling `connect` twice leaks the existing socket

**Location:** `src/tcp_client.zig`, `SyncTcpModbusClient.connect`.

`connect` unconditionally assigns a newly opened stream to `self.connection`. If the client already has a live connection and the second connection succeeds, the original stream handle is lost without being closed. A later `disconnect` closes only the new stream.

Applications that reconnect through this method can accumulate open file descriptors and server-side sessions.

**Recommendation:** Either reject calls while connected with an explicit error, or implement documented replacement semantics that close the old stream and preserve sensible state if opening the replacement fails.

**Regression test:** Connect twice and verify either an explicit already-connected error or closure of the original connection.

### 5. P2 — A holding-register read accepts exceptions for unrelated functions

**Location:** `src/tcp.zig`, the exception branch in `decode_read_holding_registers_response`.

Any function code with its high bit set is passed to `decode_exception_response`, whose decoded base function code is then discarded. Consequently, a frame with function `0x84` and matching transaction/unit identifiers is reported as a Modbus exception for the pending `0x03` holding-register read, even though it belongs to function `0x04`.

Normal responses are checked against `0x03`; exception responses need the equivalent `0x83` check. Otherwise malformed or unrelated responses are misclassified as legitimate device exceptions.

**Recommendation:** Verify that the decoded exception's base function is `0x03`, or require the wire function code to be `0x83`, before returning `error.ModbusException`.

**Regression test:** Verify that `0x83` is accepted as a holding-register exception and `0x84` returns `error.InvalidFunctionCode`.

## Additional observations

- **Network behavior is not exercised by the tests.** The TCP client test covers transaction-ID wrapping only. Public API tests cover CRC and constants, not connection establishment or request/response exchanges. Add loopback tests for fragmentation, EOF, malformed lengths, timeouts, count mismatches, and connection recovery.
- **CI does not build the example.** `test` and `check` depend on test artifacts, not the installed executable. Zig's lazy analysis also means that merely importing the client and testing its transaction counter does not validate every networking method. Add an explicit `zig build` CI step and tests that call the network API.
- **README/API documentation is stale.** The README describes a constants/CRC skeleton and says no binary is installed; the current build installs an example executable. `src/root.zig` says the package does not open sockets, although it exports a socket-owning client. Document the actual API, IPv4-literal host requirement, initialization, connection lifecycle, and blocking behavior.
- **Python test-server dependencies are not declared.** The supplied installation output reports `pymodbus==3.6.9`, and the server uses that generation's API, but the repository has no requirements file or Python project manifest recording it. Pin and document the test dependency so a fresh setup does not accidentally install an incompatible release.
- **The example masks failures with successful process exit.** Its connection/read error handlers print an error and return normally from `main`. Propagate errors if scripts should detect failure; add `defer client.disconnect()` immediately after a successful connection for reliable cleanup on all subsequent paths.
- **Exception detail is lost in the high-level API.** The standalone exception decoder exposes the device exception code, but `readHoldingRegister` reduces all such responses to `error.ModbusException`. Consider exposing the code so callers can distinguish invalid addresses, busy devices, and gateway failures.

## Recommended validation before release

Using Zig 0.15.2, run:

```sh
zig fmt --check build.zig build.zig.zon src tests
zig build
zig build test
zig build test -Doptimize=ReleaseSafe
zig build check -Dtarget=aarch64-linux
```

Then run the example against the Python server with `pymodbus==3.6.9`; the configured holding registers at addresses 10 and 11 should return 12 and 13. Supplement that happy-path check with the adversarial loopback tests above. No live-device or production-readiness assessment was performed.
