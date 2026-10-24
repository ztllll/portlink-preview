#!/usr/bin/env python3
"""Isolated real-SSH HTTP multipart regression; never touches user port 3080.

Uses only stdlib + the already isolated asyncssh dependency. The fixed SSH
request destination is mapped to an ephemeral HTTP server by the fixture.
"""
import asyncio
import hashlib
import json
import signal

import asyncssh

BOUNDARY = "portlink-upload-regression-boundary"
PREFIX = ("--" + BOUNDARY + "\r\nContent-Disposition: form-data; name=\"file\"; "
          "filename=\"large-image.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n").encode()
SUFFIX = ("\r\n--" + BOUNDARY + "--\r\n").encode()
BLOCK_SIZE = 16384


def block(seed):
    return bytes((index + seed) % 251 for index in range(BLOCK_SIZE))


def expected(size, seed):
    digest = hashlib.sha256()
    chunk = block(seed)
    remaining = size
    while remaining:
        part = chunk[:min(remaining, len(chunk))]
        digest.update(part)
        remaining -= len(part)
    return {"fileBytes": size, "fileSha256": digest.hexdigest()}


def response_bytes(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


async def http(reader, writer):
    try:
        while True:
            try:
                raw = await reader.readuntil(b"\r\n\r\n")
            except asyncio.IncompleteReadError:
                break  # SSH ready probes close without sending HTTP bytes.
            lines = raw.decode("ascii").split("\r\n")
            method, path, _ = lines[0].split(" ", 2)
            headers = {}
            for line in lines[1:]:
                if line:
                    key, value = line.split(":", 1)
                    headers[key.lower()] = value.strip()
            if method == "POST" and path == "/upload":
                if headers.get("content-type") != "multipart/form-data; boundary=" + BOUNDARY:
                    raise ValueError("unexpected multipart content type")
                remaining = int(headers["content-length"])
                if remaining < len(PREFIX) + len(SUFFIX):
                    raise ValueError("invalid multipart length")
                if await reader.readexactly(len(PREFIX)) != PREFIX:
                    raise ValueError("invalid multipart prefix")
                file_length = remaining - len(PREFIX) - len(SUFFIX)
                remaining = file_length
                digest = hashlib.sha256()
                while remaining:
                    chunk = await reader.readexactly(min(BLOCK_SIZE, remaining))
                    digest.update(chunk)
                    remaining -= len(chunk)
                    # Exercise repeated SSH window updates / delayed consumers.
                    if remaining % (256 * 1024) == 0:
                        await asyncio.sleep(0.001)
                if await reader.readexactly(len(SUFFIX)) != SUFFIX:
                    raise ValueError("invalid multipart suffix")
                body = response_bytes({"fileBytes": file_length, "fileSha256": digest.hexdigest()})
            elif method == "GET" and path == "/alive":
                body = b'{"alive":true}'
            else:
                raise ValueError("unexpected HTTP request")
            reply = ("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
                     + str(len(body)) + "\r\nX-Body-SHA256: " + hashlib.sha256(body).hexdigest()
                     + "\r\nConnection: keep-alive\r\n\r\n").encode()
            writer.write(reply + body)
            await writer.drain()
    except (ConnectionError, asyncio.IncompleteReadError, asyncio.CancelledError):
        pass
    finally:
        writer.close()
        try:
            await writer.wait_closed()
        except ConnectionError:
            pass


async def main():
    target = await asyncio.start_server(http, "127.0.0.1", 0)
    target_port = target.sockets[0].getsockname()[1]

    class Server(asyncssh.SSHServer):
        def connection_made(self, connection):
            self.connection = connection

        def begin_auth(self, username):
            return True

        def password_auth_supported(self):
            return True

        def validate_password(self, username, password):
            return username == "portlink-test" and password == "fixture-only-password"

        def connection_requested(self, host, port, *_):
            if host != "127.0.0.1" or port != 3080:
                return False
            return self.connection.forward_connection("127.0.0.1", target_port)

    key = asyncssh.generate_private_key("ssh-ed25519")
    server = await asyncssh.create_server(Server, "127.0.0.1", 0,
        server_host_keys=[key], encoding=None, login_timeout=15)
    cases = []
    for size, seed in [(32 * 1024 * 1024, 9), *[(4 * 1024 * 1024, seed) for seed in range(4)]]:
        value = expected(size, seed)
        body = response_bytes(value)
        cases.append({"size": size, "seed": seed, **value,
                      "response": body.decode(), "responseSha256": hashlib.sha256(body).hexdigest()})
    print(json.dumps({"port": server.get_port(), "fingerprint": key.get_fingerprint("sha256"),
                      "boundary": BOUNDARY, "prefix": PREFIX.decode(), "suffix": SUFFIX.decode(),
                      "cases": cases}), flush=True)
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop.set)
    await stop.wait()
    server.close()
    await server.wait_closed()
    target.close()
    await target.wait_closed()


if __name__ == "__main__":
    asyncio.run(main())
