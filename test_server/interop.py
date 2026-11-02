#!/usr/bin/env python3
"""Run the Zig TCP client against PyModbus, using its client as an oracle."""
import argparse
import asyncio
import json
from pathlib import Path
import random
import subprocess
import tempfile
import time

import pymodbus
from pymodbus.client import ModbusTcpClient
from pymodbus.datastore import ModbusSlaveContext, ModbusSparseDataBlock, ModbusServerContext
from pymodbus.server import ModbusTcpServer

ROOT = Path(__file__).resolve().parents[1]
VERSION = "3.6.9"
SIZE = 4096


def value(function, address, unit):
    if function <= 2:
        return int(((address * 13 + address // 7 + unit + function) % 11) < 5)
    edges = [0, 1, 0x7FFF, 0x8000, 0xFFFF, 0x1234, 0xABCD]
    return edges[address] if address < len(edges) else (address * 257 + unit * 101 + function * 4099) & 0xFFFF


def context():
    devices = {}
    for unit in (1, 7):
        blocks = {name: ModbusSparseDataBlock({i: value(fc, i, unit) for i in range(SIZE)})
                  for fc, name in ((1, "co"), (2, "di"), (3, "hr"), (4, "ir"))}
        devices[unit] = ModbusSlaveContext(**blocks, zero_mode=True)
    return ModbusServerContext(slaves=devices, single=False)


def cases(seed, random_cases):
    result = []
    rng = random.Random(seed)
    for function in (1, 2, 3, 4):
        limit = 2000 if function <= 2 else 125
        quantities = (1, 7, 8, 9, 15, 16, 17, 1999, 2000) if function <= 2 else (1, 2, 3, 124, 125)
        for unit in (1, 7):
            for quantity in quantities:
                for address in (0, 7, SIZE - quantity):
                    result.append(dict(function=function, unit=unit, address=address, quantity=quantity))
            for _ in range(random_cases):
                quantity = rng.randint(1, limit)
                result.append(dict(function=function, unit=unit, address=rng.randint(0, SIZE - quantity), quantity=quantity))
            # Illegal address, including a read crossing the end of the datastore.
            for address, quantity in ((SIZE, 1), (SIZE - 1, 2), (65535, 1)):
                result.append(dict(function=function, unit=unit, address=address, quantity=quantity, exception=2))
    rng.shuffle(result)
    return result


def run_clients(args, port, vectors, artifacts):
    methods = {1: "read_coils", 2: "read_discrete_inputs", 3: "read_holding_registers", 4: "read_input_registers"}
    client = ModbusTcpClient("127.0.0.1", port=port, timeout=2, retries=0)
    if not client.connect():
        raise RuntimeError("reference client failed to connect")
    try:
        for case in vectors:
            response = getattr(client, methods[case["function"]])(case["address"], count=case["quantity"], slave=case["unit"])
            if "exception" in case:
                if not response.isError() or response.exception_code != case["exception"]:
                    raise AssertionError((case, str(response)))
                case["values"] = []
            else:
                if response.isError():
                    raise AssertionError((case, str(response)))
                actual = response.bits[:case["quantity"]] if case["function"] <= 2 else response.registers
                expected = [value(case["function"], case["address"] + i, case["unit"]) for i in range(case["quantity"])]
                if actual != expected:
                    raise AssertionError((case, actual, expected))
                # Feed actual reference-client results to Zig, not a duplicated Zig formula.
                case["values"] = list(map(int, actual))
    finally:
        client.close()
    (artifacts / "vectors.json").write_text(json.dumps(vectors, indent=2) + "\n")
    source = ['pub const Case = struct { function: u8, unit: u8, address: u16, quantity: u16, exception: u8, values: []const u16 };', 'pub const cases: []const Case = &.{']
    for case in vectors:
        values = ",".join(map(str, case["values"]))
        source.append('.{ .function = %d, .unit = %d, .address = %d, .quantity = %d, .exception = %d, .values = &.{%s} },' % (case["function"], case["unit"], case["address"], case["quantity"], case.get("exception", 0), values))
    source.append('};')
    fixture = artifacts / "vectors.zig"
    fixture.write_text("\n".join(source) + "\n")
    command = [args.zig, "build", "interop-test", f"-Dinterop-port={port}", f"-Dinterop-vectors={fixture}", f"-Doptimize={args.optimize}", "--summary", "all"]
    if args.zig_cache_dir:
        command += ["--cache-dir", args.zig_cache_dir]
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=args.timeout)
    (artifacts / "zig.log").write_text(result.stdout + result.stderr)
    print(result.stdout + result.stderr, end="", flush=True)
    result.check_returncode()


async def run(args):
    if pymodbus.__version__ != VERSION:
        raise RuntimeError(f"Expected pymodbus=={VERSION}, got {pymodbus.__version__}; use interop-requirements.txt")
    artifacts = Path(args.artifacts or tempfile.mkdtemp(prefix="modbus-interop-")).resolve()
    artifacts.mkdir(parents=True, exist_ok=True)
    vectors = cases(args.seed, args.random_cases)
    (artifacts / "input-cases.json").write_text(json.dumps(vectors, indent=2) + "\n")
    server = ModbusTcpServer(context(), address=("127.0.0.1", 0))
    started = time.monotonic()
    report = dict(stack=f"pymodbus=={VERSION}", seed=args.seed, cases=len(vectors), optimize=args.optimize, status="failed")
    try:
        if not await server.listen():
            raise RuntimeError("PyModbus server failed to listen")
        port = server.transport.sockets[0].getsockname()[1]
        print(f"PyModbus {VERSION} on 127.0.0.1:{port}; {len(vectors)} cases; artifacts: {artifacts}", flush=True)
        await asyncio.to_thread(run_clients, args, port, vectors, artifacts)
        report["status"] = "passed"
    except Exception as exc:
        report["error"] = str(exc)
        raise
    finally:
        await server.shutdown()
        report["elapsed_seconds"] = round(time.monotonic() - started, 3)
        (artifacts / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zig", default="zig")
    parser.add_argument("--zig-cache-dir")
    parser.add_argument("--optimize", choices=("Debug", "ReleaseSafe"), default="Debug")
    parser.add_argument("--seed", type=int, default=20261102)
    parser.add_argument("--random-cases", type=int, default=20, help="per function/unit pair")
    parser.add_argument("--timeout", type=float, default=180, help="Zig subprocess deadline in seconds")
    parser.add_argument("--artifacts", help="retain vectors, Zig output and report here (default: new /tmp directory)")
    args = parser.parse_args()
    if args.random_cases < 0 or args.timeout <= 0:
        parser.error("random-cases must be nonnegative and timeout must be positive")
    asyncio.run(run(args))
