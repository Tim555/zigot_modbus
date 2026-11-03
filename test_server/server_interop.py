#!/usr/bin/env python3
"""Check the Zig server with the pinned PyModbus client, including concurrent peers."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import selectors
import subprocess
import tempfile

import pymodbus
from pymodbus.client import ModbusTcpClient

ROOT = Path(__file__).resolve().parents[1]


def check(response):
    if response.isError():
        raise AssertionError(str(response))
    return response


def client_for(port):
    client = ModbusTcpClient("127.0.0.1", port=port, timeout=3, retries=0)
    if not client.connect():
        raise RuntimeError("failed to connect to Zig server")
    return client


def worker(port, index):
    # Separate regions allow exact readback assertions even with concurrent writers.
    client = client_for(port)
    unit = 1 if index % 2 == 0 else 7
    address = index * 64
    values = [index + 100] * 32
    try:
        for _ in range(10):
            check(client.write_registers(address, values, slave=unit))
            actual = check(client.read_holding_registers(address, count=32, slave=unit))
            if actual.registers != values:
                raise AssertionError((index, actual.registers))
    finally:
        client.close()


def exercise(port):
    client = client_for(port)
    try:
        for unit in (1, 7):
            assert check(client.read_input_registers(0, count=125, slave=unit)).registers == [0x1234] * 125
            assert all(check(client.read_discrete_inputs(7, count=2000, slave=unit)).bits[:2000])
            check(client.write_coil(7, True, slave=unit))
            assert check(client.read_coils(7, count=1, slave=unit)).bits[0]
            check(client.write_coil(7, False, slave=unit))
            assert not check(client.read_coils(7, count=1, slave=unit)).bits[0]
            check(client.write_register(0, 0xffff, slave=unit))
            assert check(client.read_holding_registers(0, count=1, slave=unit)).registers == [0xffff]
            for quantity in (1, 7, 8, 9, 1968):
                values = [i % 3 == 0 for i in range(quantity)]
                check(client.write_coils(7, values, slave=unit))
                assert check(client.read_coils(7, count=quantity, slave=unit)).bits[:quantity] == values
            for quantity in (1, 2, 123):
                values = [(i * 257 + 0x8000) & 0xffff for i in range(quantity)]
                check(client.write_registers(7, values, slave=unit))
                assert check(client.read_holding_registers(7, count=quantity, slave=unit)).registers == values
            invalid = client.read_holding_registers(4096, count=1, slave=unit)
            assert invalid.isError() and invalid.exception_code == 2
    finally:
        client.close()
    with ThreadPoolExecutor(max_workers=16) as pool:
        list(pool.map(lambda index: worker(port, index), range(16)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zig", default="zig")
    parser.add_argument("--zig-cache-dir")
    parser.add_argument("--optimize", choices=("Debug", "ReleaseSafe"), default="Debug")
    parser.add_argument("--artifacts", help="retain build log, server log, and report here (default: new /tmp directory)")
    args = parser.parse_args()
    if pymodbus.__version__ != "3.6.9":
        raise RuntimeError("Install interop-requirements.txt (pymodbus==3.6.9)")
    artifacts = Path(args.artifacts or tempfile.mkdtemp(prefix="modbus-server-interop-")).resolve()
    artifacts.mkdir(parents=True, exist_ok=True)
    binary = artifacts / "server"
    command = [args.zig, "build-exe", f"-O{args.optimize}", "--dep", "zigot_modbus", f"-Mroot={ROOT / 'tests/interop_server.zig'}", f"-Mzigot_modbus={ROOT / 'src/root.zig'}", f"-femit-bin={binary}"]
    if args.zig_cache_dir:
        command += ["--cache-dir", args.zig_cache_dir]
    server = None
    report = dict(stack=f"pymodbus=={pymodbus.__version__}", optimize=args.optimize, concurrent_clients=16, concurrent_requests=320, status="failed")
    try:
        try:
            result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=180)
        except subprocess.TimeoutExpired as exc:
            (artifacts / "zig.log").write_text(
                (exc.stdout or b"").decode(errors="replace") + (exc.stderr or b"").decode(errors="replace"))
            raise
        (artifacts / "zig.log").write_text(result.stdout + result.stderr)
        print(result.stdout + result.stderr, end="", flush=True)
        result.check_returncode()
        server = subprocess.Popen([str(binary)], stderr=subprocess.PIPE, text=True)
        # Bound readiness so startup failures cannot leave the harness hanging.
        with selectors.DefaultSelector() as selector:
            selector.register(server.stderr, selectors.EVENT_READ)
            if not selector.select(timeout=5):
                raise TimeoutError("server did not report its port")
            port = int(server.stderr.readline())
        exercise(port)
        report["status"] = "passed"
    except Exception as exc:
        report["error"] = str(exc)
        raise
    finally:
        if server is not None:
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
            (artifacts / "server.log").write_text(server.stderr.read())
            server.stderr.close()
        (artifacts / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        print(f"Artifacts: {artifacts}")
        print(json.dumps(report))


if __name__ == "__main__":
    main()
