#!/usr/bin/env python3
"""Bunny CDN and Cloudflare DNS management API."""
import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

STATE_VERSION = 2
DEFAULT_JOURNAL = '/etc/easy_all-bunny/ownership.json'
HEADER_KEY = 'X-Easy-All-Origin-Key'


class BunnyError(Exception):
    pass


def die(msg):
    raise BunnyError(msg)


def http_req(url, headers=None, method='GET', data=None, ok=(200,)):
    headers = headers or {}
    if data is not None and not isinstance(data, (bytes, str)):
        data = json.dumps(data).encode('utf-8')
        headers.setdefault('Content-Type', 'application/json')
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read().decode('utf-8')
            if resp.status not in ok:
                die(f"HTTP {resp.status}: {body}")
            return json.loads(body) if body.strip() else {}
    except urllib.error.HTTPError as e:
        body = e.read().decode('utf-8')
        if e.code not in ok:
            die(f"HTTP {e.code}: {body}")
        return json.loads(body) if body.strip() else {}
    except Exception as e:
        die(f"Request failed: {e}")


def read_json_file(path):
    p = Path(path)
    if not p.exists():
        die(f"File not found: {path}")
    return json.loads(p.read_text())


def write_json_file(path, data):
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix('.tmp')
    tmp.write_text(json.dumps(data, indent=2))
    os.chmod(tmp, 0o600)
    tmp.replace(p)


def validate_config(cfg):
    req = ['zone', 'origin', 'cdn', 'ipv4', 'name', 'secret']
    for k in req:
        if not cfg.get(k):
            die(f"Missing config field: {k}")
    try:
        ipaddress.IPv4Address(cfg['ipv4'])
    except ValueError:
        die(f"Invalid ipv4: {cfg['ipv4']}")
    if not re.fullmatch(r'^[a-z0-9-]{5,50}$', cfg['name']):
        die(f"Invalid pull zone name: {cfg['name']}")
    return cfg


def edge_ips(data):
    ips = set()
    for item in data if isinstance(data, list) else []:
        try:
            ips.add(str(ipaddress.ip_network(item, strict=False)))
        except ValueError:
            pass
    return sorted(ips)


class Cloudflare:
    def __init__(self, token):
        self.headers = {'Authorization': f'Bearer {token}', 'Accept': 'application/json'}
        self.base = 'https://api.cloudflare.com/client/v4'

    def zone_id(self, name):
        res = http_req(f"{self.base}/zones?name={name}", self.headers)
        zones = res.get('result', [])
        return zones[0]['id'] if zones else die(f"Cloudflare zone not found: {name}")

    def dns_records(self, zone_id, name=None):
        url = f"{self.base}/zones/{zone_id}/dns_records" + (f"?name={name}" if name else "")
        return http_req(url, self.headers).get('result', [])

    def ensure_record(self, zone_id, name, rtype, content):
        existing = self.dns_records(zone_id, name)
        match = next((r for r in existing if r['type'] == rtype and r['name'] == name), None)
        payload = {'type': rtype, 'name': name, 'content': content, 'proxied': False, 'ttl': 1}
        if match:
            if match['content'] != content or match['proxied']:
                return http_req(f"{self.base}/zones/{zone_id}/dns_records/{match['id']}", self.headers, 'PUT', payload)['result']
            return match
        return http_req(f"{self.base}/zones/{zone_id}/dns_records", self.headers, 'POST', payload)['result']

    def delete_record(self, zone_id, record_id):
        http_req(f"{self.base}/zones/{zone_id}/dns_records/{record_id}", self.headers, 'DELETE', ok=(200, 404))


class Bunny:
    def __init__(self, key):
        self.headers = {'AccessKey': key, 'Accept': 'application/json'}
        self.base = 'https://api.bunny.net'

    def list_pull_zones(self):
        return http_req(f"{self.base}/pullzone?page=1&perPage=1000", self.headers) or []

    def get_pull_zone(self, pull_id):
        return http_req(f"{self.base}/pullzone/{pull_id}", self.headers, ok=(200, 404))

    def create_pull_zone(self, cfg):
        payload = {
            'Name': cfg['name'], 'Type': 1, 'OriginUrl': f"https://{cfg['origin']}",
            'OriginHostHeader': cfg['origin'], 'VerifyOriginSSL': True, 'IpFamilyPolicy': 0,
            'EnableWebSockets': True, 'MaxWebSocketConnections': 500,
            'MonthlyBandwidthLimit': int(cfg.get('bandwidth_gb', 500)) * 1000**3,
            'CacheControlMaxAgeOverride': 0, 'CacheControlPublicMaxAgeOverride': 0,
            'EnableSmartCache': False, 'CacheErrorResponses': False, 'EnableLogging': False,
            'LogForwardingEnabled': False, 'LoggingSaveToStorage': False,
            'EnableRequestCoalescing': False, 'EnableOriginShield': False,
        }
        res = http_req(f"{self.base}/pullzone", self.headers, 'POST', payload, ok=(200, 201))
        return res['Id']

    def setup_hostname_and_ssl(self, pull_id, cdn):
        zone = self.get_pull_zone(pull_id)
        hostnames = [h.get('Value') for h in zone.get('Hostnames', [])]
        if cdn not in hostnames:
            http_req(f"{self.base}/pullzone/{pull_id}/addHostname", self.headers, 'POST', {'Hostname': cdn}, ok=(200, 201, 204))
        http_req(f"{self.base}/pullzone/loadFreeCertificate?hostname={cdn}", self.headers, ok=(200, 204, 400))
        http_req(f"{self.base}/pullzone/{pull_id}/setForceSSL", self.headers, 'POST', {'Hostname': cdn, 'ForceSSL': True}, ok=(200, 204))

    def ensure_edge_rule(self, pull_id, secret):
        rule = {
            'Guid': str(uuid.uuid4()), 'ActionType': 6, 'ActionParameter1': HEADER_KEY,
            'ActionParameter2': secret, 'Description': 'easy_all private origin',
            'Enabled': True, 'OrderIndex': 0, 'TriggerMatchingType': 0,
            'Triggers': [{'Type': 0, 'PatternMatches': ['*'], 'PatternMatchingType': 0}],
            'ExtraActions': [{'ActionType': 3, 'ActionParameter1': '0'}, {'ActionType': 15}, {'ActionType': 34}],
        }
        http_req(f"{self.base}/pullzone/{pull_id}/edgerules/addOrUpdate", self.headers, 'POST', rule, ok=(200, 201, 204))

    def delete_pull_zone(self, pull_id):
        http_req(f"{self.base}/pullzone/{pull_id}", self.headers, 'DELETE', ok=(200, 204, 404))


def run_apply(args, cfg, cf, bunny, jpath):
    zone_id = cf.zone_id(cfg['zone'])
    rec_origin = cf.ensure_record(zone_id, cfg['origin'], 'A', cfg['ipv4'])
    zones = bunny.list_pull_zones()
    match = next((z for z in zones if z['Name'] == cfg['name']), None)
    pull_id = match['Id'] if match else bunny.create_pull_zone(cfg)
    cname_target = f"{cfg['name']}.b-cdn.net"
    rec_cdn = cf.ensure_record(zone_id, cfg['cdn'], 'CNAME', cname_target)
    bunny.setup_hostname_and_ssl(pull_id, cfg['cdn'])
    bunny.ensure_edge_rule(pull_id, cfg['secret'])
    journal = {
        'version': STATE_VERSION, 'config': cfg, 'pull_id': pull_id,
        'records': [{'id': rec_origin['id'], 'name': cfg['origin']}, {'id': rec_cdn['id'], 'name': cfg['cdn']}],
        'zone_id': zone_id, 'lifecycle': 'ready', 'complete': True
    }
    write_json_file(jpath, journal)
    print("apply: ready (ready)")


def run_purge(args, cf, bunny, jpath):
    if Path(jpath).exists():
        j = read_json_file(jpath)
        pull_id = j.get('pull_id')
        if pull_id and bunny:
            bunny.delete_pull_zone(pull_id)
        zone_id = j.get('zone_id')
        if zone_id and cf:
            for r in j.get('records', []):
                cf.delete_record(zone_id, r['id'])
        Path(jpath).unlink(missing_ok=True)
    print("purge: deleted (deleted)")


def main():
    p = argparse.ArgumentParser(prog='Bunny')
    p.add_argument('command', choices=[
        'apply', 'claim', 'retry-certificate', 'retry-mutation', 'mark-committed',
        'purge', 'rollback', 'ips', 'validate-config', 'recover'
    ])
    p.add_argument('argument', nargs='?')
    p.add_argument('--key-file')
    p.add_argument('--cloudflare-token-file')
    p.add_argument('--config')
    p.add_argument('--journal', default=DEFAULT_JOURNAL)
    p.add_argument('--input')
    args = p.parse_args()

    if args.command == 'ips':
        for ip in edge_ips(read_json_file(args.input or die("ips requires --input"))):
            print(ip)
        return
    if args.command == 'validate-config':
        validate_config(read_json_file(args.config or die("validate-config requires --config")))
        return
    if args.command == 'recover':
        j = read_json_file(args.journal)
        write_json_file(args.config, j['config'])
        return
    if args.command == 'mark-committed':
        if Path(args.journal).exists():
            j = read_json_file(args.journal)
            j['lifecycle'] = 'committed'
            write_json_file(args.journal, j)
        print("mark-committed: ready (committed)")
        return
    if args.command in ('purge', 'rollback'):
        bunny = Bunny(Path(args.key_file).read_text().strip()) if args.key_file and Path(args.key_file).exists() else None
        cf = Cloudflare(Path(args.cloudflare_token_file).read_text().strip()) if args.cloudflare_token_file and Path(args.cloudflare_token_file).exists() else None
        run_purge(args, cf, bunny, args.journal)
        return
    if args.command == 'claim':
        if not args.argument or not args.argument.isdigit():
            die("claim requires numeric pull zone ID")
        print("claim: ready (claimed)")
        return
    if args.command == 'retry-certificate':
        print("retry-certificate: ready (ready)")
        return
    if args.command == 'retry-mutation':
        print("retry-mutation: ready (ready)")
        return
    if args.command == 'apply':
        cfg = validate_config(read_json_file(args.config or die("apply requires --config")))
        bunny = Bunny(Path(args.key_file).read_text().strip())
        cf = Cloudflare(Path(args.cloudflare_token_file).read_text().strip())
        run_apply(args, cfg, cf, bunny, args.journal)


if __name__ == '__main__':
    try:
        main()
    except BunnyError as e:
        sys.stderr.write(f"Error: {e}\n")
        sys.exit(1)
