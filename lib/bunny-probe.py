#!/usr/bin/env python3
"""Real TLS and RFC6455 handshake probes; never print headers or subscription URLs."""
import argparse
import base64
import hashlib
import http.client
import json
from pathlib import Path
import socket
import ssl
import sys
from jsonschema import validate


def connection(host, loopback):
    conn = http.client.HTTPSConnection(host, timeout=15, context=ssl.create_default_context())
    if loopback:
        conn._create_connection = lambda address, timeout, source_address=None: socket.create_connection(('127.0.0.1', 443), timeout)
    return conn


def probe(config, origin):
    host = config['origin'] if origin else config['cdn']
    # RFC6455 requires a 16-byte nonce.
    nonce = base64.b64encode(b'easy-all-ws-test!').decode()
    headers = {'Upgrade': 'websocket', 'Connection': 'Upgrade',
               'Sec-WebSocket-Key': nonce, 'Sec-WebSocket-Version': '13'}
    if origin:
        conn = connection(host, True)
        try:
            conn.request('GET', '/subscribe?token=invalid')
            if conn.getresponse().status not in [403, 404]:
                raise ValueError('unguarded origin')
        finally:
            conn.close()
        conn = connection(host, True)
        try:
            conn.request('GET', config['path'], headers=headers)
            if conn.getresponse().status != 404:
                raise ValueError('unguarded websocket')
        finally:
            conn.close()
        headers['X-Easy-All-Origin-Key'] = config['secret']
    conn = connection(host, origin)
    try:
        conn.request('GET', config['path'], headers=headers)
        response = conn.getresponse()
        expected = base64.b64encode(hashlib.sha1((nonce + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        if response.status != 101 or response.getheader('Sec-WebSocket-Accept') != expected:
            raise ValueError('websocket handshake failed')
    finally:
        conn.close()


def leaf_der(fullchain):
    marker = '-----END CERTIFICATE-----'
    return ssl.PEM_cert_to_DER_cert(fullchain.split(marker, 1)[0] + marker + '\n')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['cert', 'origin', 'edge'])
    parser.add_argument('--config', required=True)
    parser.add_argument('--cert')
    args = parser.parse_args()
    config = json.loads(Path(args.config).read_text())
    validate(config, {'type': 'object', 'required': ['origin','cdn','path','secret'],
        'additionalProperties': False, 'properties': {k: {'type':'string','minLength':1} for k in ['origin','cdn','path','secret']}})
    if args.command == 'cert':
        conn = connection(config['origin'], True)
        try:
            conn.connect()  # CA + origin SNI/hostname verification stays enabled.
            served = conn.sock.getpeercert(binary_form=True)
            expected = leaf_der(Path(args.cert).read_text())
            if hashlib.sha256(served).digest() != hashlib.sha256(expected).digest():
                raise ValueError('served certificate mismatch')
        finally:
            conn.close()
    else:
        probe(config, args.command == 'origin')


if __name__ == '__main__':
    try:
        main()
    except Exception:
        print('Bunny TLS/WebSocket verification failed (private details omitted)', file=sys.stderr)
        sys.exit(1)
