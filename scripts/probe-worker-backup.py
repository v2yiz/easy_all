#!/usr/bin/env python3
"""TLS + WS + authenticated VLESS relay probe. Configuration arrives on stdin."""
import base64
import hashlib
import json
import os
import socket
import signal
import ssl
import struct
import sys
import time
import uuid


class DeadlineExceeded(TimeoutError):
    """The probe-wide deadline has expired."""


def frame(data, opcode=2):
    mask = os.urandom(4)
    size = len(data)
    header = bytes([0x80 | opcode, 0x80 | size]) if size < 126 else bytes([0x80 | opcode, 0xfe]) + struct.pack('!H', size)
    return header + mask + bytes(value ^ mask[i % 4] for i, value in enumerate(data))


def remaining_timeout(deadline, maximum):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise DeadlineExceeded()
    return min(maximum, remaining)


def resolve_doh(domain, deadline):
    ips = []
    try:
        import urllib.request
        req = urllib.request.Request(
            f'https://1.1.1.1/dns-query?name={domain}&type=A',
            headers={'Accept': 'application/dns-json', 'User-Agent': 'curl/7.88.1'}
        )
        with urllib.request.urlopen(req, timeout=remaining_timeout(deadline, 3)) as resp:
            data = json.loads(resp.read().decode())
            for ans in data.get('Answer', []):
                if ans.get('type') == 1 and ans.get('data'):
                    candidate = ans['data'].strip()
                    if candidate not in ips:
                        ips.append(candidate)
    except DeadlineExceeded:
        raise
    except Exception:
        pass
    return ips


def resolve_ips(address, deadline):
    try:
        socket.inet_aton(address)
        return [address]
    except OSError:
        pass
    ips = []
    try:
        for res in socket.getaddrinfo(address, 443, socket.AF_INET, socket.SOCK_STREAM):
            candidate = res[4][0]
            if candidate not in ips:
                ips.append(candidate)
        remaining_timeout(deadline, 1)
    except DeadlineExceeded:
        raise
    except Exception:
        pass
    if not ips:
        ips = resolve_doh(address, deadline)
    if not ips:
        raise ValueError(f'Unable to resolve IPv4 for {address}')
    return ips


def probe(config):
    started = time.monotonic()
    deadline = started + 12
    domain = config['domain']
    address = config.get('ip') or domain
    candidate_ips = resolve_ips(address, deadline)
    doh_attempted = (address != domain)
    last_error = None
    idx = 0
    while idx < len(candidate_ips):
        ip = candidate_ips[idx]
        idx += 1
        if deadline - time.monotonic() <= 1:
            break
        try:
            with socket.create_connection((ip, 443), timeout=min(5, max(1, deadline - time.monotonic()))) as raw:
                with ssl.create_default_context().wrap_socket(raw, server_hostname=domain) as sock:
                    def read(size):
                        data = bytearray()
                        while len(data) < size:
                            remaining = deadline - time.monotonic()
                            if remaining <= 0:
                                raise DeadlineExceeded()
                            sock.settimeout(remaining)
                            part = sock.recv(size - len(data))
                            if not part:
                                raise ValueError('Unexpected EOF')
                            data.extend(part)
                        return bytes(data)

                    key = base64.b64encode(os.urandom(16)).decode()
                    sock.sendall((f"GET {config['path']} HTTP/1.1\r\nHost: {domain}\r\n"
                                  f"Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
                                  "Sec-WebSocket-Version: 13\r\n\r\n").encode())
                    headers = bytearray()
                    while not headers.endswith(b'\r\n\r\n'):
                        if len(headers) > 16384:
                            raise ValueError('Oversized headers')
                        headers.extend(read(1))
                    lines = headers.decode('latin1').split('\r\n')
                    fields = dict(line.lower().split(':', 1) for line in lines[1:] if ':' in line)
                    accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
                    # Header names are case-insensitive; the accept value is not.
                    original = dict((line.split(':', 1)[0].lower(), line.split(':', 1)[1].strip()) for line in lines[1:] if ':' in line)
                    if lines[0].split()[1] != '101' or original.get('sec-websocket-accept') != accept:
                        raise ValueError('WebSocket upgrade failed')
                    if fields.get('upgrade', '').strip() != 'websocket':
                        raise ValueError('Invalid upgrade')
                    target = b'www.gstatic.com'
                    payload = (b'\0' + uuid.UUID(config['uuid']).bytes + b'\0\1\0\x50\2' + bytes([len(target)]) + target +
                               b'GET /generate_204 HTTP/1.1\r\nHost: www.gstatic.com\r\nConnection: close\r\n\r\n')
                    sock.sendall(frame(payload))
                    response = bytearray()
                    while b'\r\n' not in response:
                        first, second = read(2)
                        opcode, length = first & 15, second & 127
                        if second & 128 or first & 0x70:
                            raise ValueError('Invalid server frame')
                        if length == 126:
                            length = struct.unpack('!H', read(2))[0]
                        elif length == 127:
                            length = struct.unpack('!Q', read(8))[0]
                        if length > 65536 or len(response) + length > 65536:
                            raise ValueError('Oversized response')
                        data = read(length)
                        if opcode == 9:
                            sock.sendall(frame(data, 10))
                        elif opcode in (0, 2):
                            response.extend(data)
                        else:
                            raise ValueError('Relay closed')
                    if response[:2] != b'\0\0' or not response[2:].startswith((b'HTTP/1.1 204', b'HTTP/1.0 204')):
                        raise ValueError('Relay verification failed')
                    sock.sendall(frame(struct.pack('!H', 1000), 8))
                    return {'ip': ip, 'elapsed_ms': round((time.monotonic() - started) * 1000),
                            'cf_ray': original.get('cf-ray', ''), 'verified_at': int(time.time())}
        except DeadlineExceeded:
            raise
        except Exception as err:
            last_error = err
            if idx == len(candidate_ips) and not doh_attempted:
                doh_attempted = True
                doh_ips = [d for d in resolve_doh(domain, deadline) if d not in candidate_ips]
                candidate_ips.extend(doh_ips)
            continue
    raise last_error or ValueError('All candidate IPs failed')


if __name__ == '__main__':
    try:
        # Bound DNS resolution as well as socket I/O on the Linux installer host.
        def expired(*_):
            raise DeadlineExceeded()
        signal.signal(signal.SIGALRM, expired)
        signal.alarm(15)
        print(json.dumps(probe(json.load(sys.stdin))))
    except Exception:
        # Never print the config, UUID or request headers.
        print('Worker relay probe failed', file=sys.stderr)
        sys.exit(1)
