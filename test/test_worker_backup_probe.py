#!/usr/bin/env python3
"""Exercise the real probe wire codec without external network access."""
import base64
import hashlib
import importlib.util
from pathlib import Path
import struct
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('probe', Path(__file__).resolve().parents[1] / 'scripts/probe-worker-backup.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
config = {'domain': 'backup.example.com', 'path': '/ws', 'uuid': '11111111-2222-4333-8444-555555555555'}


class Peer:
    def __init__(self, bad=False):
        self.data = bytearray()
        self.payloads = []
        self.bad = bad

    def __enter__(self):
        return self

    def __exit__(self, *_):
        pass

    def settimeout(self, _):
        pass

    def recv(self, size):
        result = self.data[:min(size, 3)]
        del self.data[:len(result)]
        return result

    def sendall(self, data):
        if data.startswith(b'GET '):
            assert b'Host: backup.example.com\r\n' in data
            key = data.split(b'Sec-WebSocket-Key: ')[1].split(b'\r\n')[0]
            accept = base64.b64encode(hashlib.sha1(key + b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest())
            self.data.extend(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: ' + accept + b'\r\n\r\n')
        else:
            size = data[1] & 127
            offset = 2
            if size == 126:
                size = struct.unpack('!H', data[2:4])[0]
                offset = 4
            mask = data[offset:offset + 4]
            payload = bytes(value ^ mask[i % 4] for i, value in enumerate(data[offset + 4:]))
            assert len(payload) == size
            self.payloads.append((data[0] & 15, payload))
            if data[0] & 15 == 2:
                assert payload[:17] == b'\0' + module.uuid.UUID(config['uuid']).bytes
                assert b'www.gstatic.com' in payload
                # Ping interleaved with the VLESS response and fragmented HTTP status.
                response = b'\0\0HTTP/1.1 ' + (b'500' if self.bad else b'204') + b' No Content\r\n'
                self.data.extend(b'\x89\x02hi\x02\x01' + response[:1] + bytes([0x80, len(response) - 1]) + response[1:])


for bad in (False, True):
    peer = Peer(bad)
    class Context:
        def wrap_socket(self, raw, server_hostname):
            assert server_hostname == config['domain']
            return raw
    with patch.object(module.socket, 'getaddrinfo', return_value=[(2, 1, 6, '', ('104.16.1.1', 443))]), \
            patch.object(module.socket, 'create_connection', return_value=peer), \
            patch.object(module.ssl, 'create_default_context', return_value=Context()):
        if bad:
            try:
                module.probe(config)
                raise AssertionError('Non-204 response accepted')
            except ValueError:
                pass
        else:
            result = module.probe(config)
            assert result['ip'] == '104.16.1.1'
            assert (10, b'hi') in peer.payloads
            assert peer.payloads[-1] == (8, struct.pack('!H', 1000))
# Verify stale local DNS triggers DoH fallback when connection fails
peer_doh = Peer(bad=False)
def connect_mock(addr, timeout=None):
    if addr[0] == '104.16.1.1':
        raise ConnectionRefusedError('Stale local IP')
    return peer_doh

with patch.object(module.socket, 'getaddrinfo', return_value=[(2, 1, 6, '', ('104.16.1.1', 443))]), \
        patch.object(module, 'resolve_doh', return_value=['104.16.2.2']), \
        patch.object(module.socket, 'create_connection', side_effect=connect_mock), \
        patch.object(module.ssl, 'create_default_context', return_value=Context()):
    result = module.probe(config)
    assert result['ip'] == '104.16.2.2'

# A probe-wide timeout must not be swallowed and followed by more network I/O.
with patch.object(module.socket, 'getaddrinfo', side_effect=module.DeadlineExceeded()), \
        patch.object(module, 'resolve_doh') as doh:
    try:
        module.resolve_ips(config['domain'], module.time.monotonic() + 12)
        raise AssertionError('Probe deadline was swallowed')
    except module.DeadlineExceeded:
        pass
    doh.assert_not_called()

# The socket read loop must propagate the same deadline instead of retrying via DoH.
deadline_peer = Peer()
with patch.object(module.time, 'monotonic', side_effect=[0, 0, 0, 0, 13]), \
        patch.object(module.socket, 'getaddrinfo', return_value=[(2, 1, 6, '', ('104.16.1.1', 443))]), \
        patch.object(module.socket, 'create_connection', return_value=deadline_peer), \
        patch.object(module.ssl, 'create_default_context', return_value=Context()), \
        patch.object(module, 'resolve_doh') as doh:
    try:
        module.probe(config)
        raise AssertionError('Socket read deadline was swallowed')
    except module.DeadlineExceeded:
        pass
    doh.assert_not_called()

print('Worker probe TLS hostname, masking, fragmentation and relay verification passed')
