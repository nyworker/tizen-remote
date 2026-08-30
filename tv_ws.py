#!/usr/bin/env python3
"""Minimal Samsung Tizen remote-control WebSocket client, used by tizen_remote.sh."""
import asyncio
import json
import os
import ssl
import sys

import websockets

DEBUG = bool(os.environ.get("TV_WS_DEBUG"))


def log(msg):
    if DEBUG:
        sys.stderr.write(msg + "\n")


def make_ssl_context():
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


async def connect(url):
    try:
        ws = await asyncio.wait_for(websockets.connect(url, ssl=make_ssl_context()), timeout=3)
    except (asyncio.TimeoutError, OSError) as exc:
        sys.stderr.write(f"warning: connection to TV timed out after 3s ({exc})\n")
        raise
    return ws


def key_cmd(key):
    return json.dumps({
        "method": "ms.remote.control",
        "params": {
            "Cmd": "Click",
            "DataOfCmd": key,
            "Option": "false",
            "TypeOfRemote": "SendRemoteKey",
        },
    })


async def pair(url, timeout):
    ws = await connect(url)
    token = None
    deadline = asyncio.get_event_loop().time() + timeout
    try:
        while True:
            remaining = deadline - asyncio.get_event_loop().time()
            if remaining <= 0:
                break
            try:
                msg = await asyncio.wait_for(ws.recv(), timeout=remaining)
            except asyncio.TimeoutError:
                break
            log(msg)
            try:
                data = json.loads(msg)
            except ValueError:
                continue
            tok = (data.get("data") or {}).get("token")
            if tok:
                token = tok
                break
    finally:
        await ws.close()
    if token:
        print(token)
        return 0
    return 1


async def send(url, keys):
    ws = await connect(url)
    got_error = False
    try:
        # Let the initial connect ack (or an auth error) arrive before sending.
        try:
            msg = await asyncio.wait_for(ws.recv(), timeout=5)
            log(msg)
            data = json.loads(msg)
            if data.get("event") == "ms.error":
                got_error = True
        except asyncio.TimeoutError:
            pass

        if not got_error:
            for key in keys:
                await ws.send(key_cmd(key))
                await asyncio.sleep(1)

            try:
                while True:
                    msg = await asyncio.wait_for(ws.recv(), timeout=1.5)
                    log(msg)
                    data = json.loads(msg)
                    if data.get("event") == "ms.error":
                        got_error = True
            except asyncio.TimeoutError:
                pass

        if got_error and not DEBUG:
            sys.stderr.write("TV rejected the request (not authorized).\n")
    finally:
        await ws.close()
    return 1 if got_error else 0


def main():
    mode = sys.argv[1]
    if mode == "pair":
        url, timeout = sys.argv[2], float(sys.argv[3])
        rc = asyncio.run(pair(url, timeout))
    elif mode == "send":
        url, keys = sys.argv[2], sys.argv[3:]
        rc = asyncio.run(send(url, keys))
    else:
        sys.stderr.write(f"unknown mode: {mode}\n")
        rc = 2
    sys.exit(rc)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # connection errors, refused, etc.
        sys.stderr.write(f"error: {exc}\n")
        # Exit 2 so callers can tell "couldn't reach the TV" apart from a
        # rejected/expired token (exit 1), which means don't discard a token
        # just because the TV happened to be unreachable.
        sys.exit(2)
