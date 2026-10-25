#!/usr/bin/env python3
"""Length-delimited echo acceptance against one explicit, disposable emulator.
Requires already-connected UI fixture session; does not configure user accounts.
"""
import argparse
import json
import pathlib
import socket
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--adb', required=True, type=pathlib.Path)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--output', type=pathlib.Path)
    args = parser.parse_args()
    if args.serial != 'emulator-5580':
        parser.error('Only the dedicated PortLink test emulator-5580 is accepted')

    def command(*parts):
        result = subprocess.run([str(args.adb), '-s', args.serial, *parts], capture_output=True, text=True, timeout=20)
        if result.returncode:
            raise RuntimeError('Dedicated emulator command failed: ' + ' '.join(parts[:2]))
        return result.stdout

    port = int(command('forward', 'tcp:0', 'tcp:3080').strip())
    report = {'serial': args.serial, 'api': command('shell', 'getprop', 'ro.build.version.sdk').strip(),
              'abi': command('shell', 'getprop', 'ro.product.cpu.abi').strip(), 'checks': [],
              'server': 'isolated fixture via test-only adb reverse; not user server'}
    try:
        for phase in ['foreground', 'background-home']:
            if phase == 'background-home':
                command('shell', 'input', 'keyevent', 'KEYCODE_HOME')
                time.sleep(1)
            services = command('shell', 'dumpsys', 'activity', 'services', 'dev.portlink.portlink')
            if 'TunnelSessionService' not in services or 'isForeground=true' not in services:
                raise RuntimeError('Real foreground service is not running')
            total = 0
            with socket.create_connection(('127.0.0.1', port), timeout=10) as stream:
                # Multiple requests over one open tunnel; do not FIN before echo.
                # adb forwarding itself does not reliably preserve half-close.
                for round_number in range(12):
                    size = 1024 if round_number < 4 else 65536
                    data = bytes((i + round_number) % 251 for i in range(size))
                    stream.sendall(data)
                    reply = bytearray()
                    while len(reply) < len(data):
                        block = stream.recv(min(65536, len(data) - len(reply)))
                        if not block:
                            break
                        reply.extend(block)
                    if reply != data:
                        raise RuntimeError('Tunneled echo mismatch/EOF in ' + phase)
                    total += len(reply)
            report['checks'].append({'phase': phase, 'matched': True, 'rounds': 12, 'bytes': total})
        report['success'] = True
    except Exception as error:
        report['success'] = False
        report['failureType'] = type(error).__name__
        report['failure'] = str(error)
    finally:
        command('forward', '--remove', 'tcp:' + str(port))
    text = json.dumps(report, indent=2)
    if args.output:
        args.output.write_text(text)
    print(text)
    return 0 if report['success'] else 1

if __name__ == '__main__':
    raise SystemExit(main())
