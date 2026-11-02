#!/usr/bin/env python3
"""Bunny CDN and Cloudflare DNS management API."""
import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import sys
import urllib.error
import urllib.request
import uuid

STATE_VERSION = 2
DEFAULT_JOURNAL = '/etc/easy_all-bunny/ownership.json'
HEADER_KEY = 'X-Easy-All-Origin-Key'
CF_API = 'https://api.cloudflare.com/client/v4'
BUNNY_API = 'https://api.bunny.net'


def die(msg):
    sys.stderr.write(f"Error: {msg}\n")
    sys.exit(1)


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
    for k in ['zone', 'origin', 'cdn', 'ipv4', 'name', 'secret']:
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


def cf_ensure_record(cf_headers, zone_id, name, rtype, content):
    url = f"{CF_API}/zones/{zone_id}/dns_records?name={name}"
    existing = http_req(url, cf_headers).get('result', [])
    match = next((r for r in existing if r['type'] == rtype and r['name'] == name), None)
    payload = {'type': rtype, 'name': name, 'content': content, 'proxied': False, 'ttl': 1}
    if match:
        if match['content'] != content or match['proxied']:
            return http_req(f"{CF_API}/zones/{zone_id}/dns_records/{match['id']}", cf_headers, 'PUT', payload)['result']
        return match
    return http_req(f"{CF_API}/zones/{zone_id}/dns_records", cf_headers, 'POST', payload)['result']


def run_apply(cfg, cf_token, bunny_key, jpath):
    cf_headers = {'Authorization': f'Bearer {cf_token}', 'Accept': 'application/json'}
    bunny_headers = {'AccessKey': bunny_key, 'Accept': 'application/json'}

    # 1. Cloudflare Zone ID & origin A 记录
    res = http_req(f"{CF_API}/zones?name={cfg['zone']}", cf_headers)
    zones = res.get('result', [])
    if not zones:
        die(f"Cloudflare zone not found: {cfg['zone']}")
    zone_id = zones[0]['id']
    rec_origin = cf_ensure_record(cf_headers, zone_id, cfg['origin'], 'A', cfg['ipv4'])

    # 2. Bunny Pull Zone
    res = http_req(f"{BUNNY_API}/pullzone?page=1&perPage=1000", bunny_headers) or []
    zones = res.get('Items', res) if isinstance(res, dict) else res
    match = next((z for z in zones if isinstance(z, dict) and z.get('Name') == cfg['name']), None)
    if match:
        pull_id = match['Id']
    else:
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
        res = http_req(f"{BUNNY_API}/pullzone", bunny_headers, 'POST', payload, ok=(200, 201))
        pull_id = res['Id']

    # 3. Cloudflare CDN CNAME 记录
    rec_cdn = cf_ensure_record(cf_headers, zone_id, cfg['cdn'], 'CNAME', f"{cfg['name']}.b-cdn.net")

    # 4. Bunny Hostname, SSL, & Edge Rule
    pull_zone = http_req(f"{BUNNY_API}/pullzone/{pull_id}", bunny_headers, ok=(200, 404))
    hostnames = [h.get('Value') for h in pull_zone.get('Hostnames', []) if isinstance(h, dict)]
    if cfg['cdn'] not in hostnames:
        http_req(f"{BUNNY_API}/pullzone/{pull_id}/addHostname", bunny_headers, 'POST', {'Hostname': cfg['cdn']}, ok=(200, 201, 204))

    for _ in range(5):
        res = http_req(f"{BUNNY_API}/pullzone/loadFreeCertificate?hostname={cfg['cdn']}", bunny_headers, ok=(200, 204, 400))
        if isinstance(res, dict) and res.get('ErrorKey'):
            time.sleep(3)
            continue
        break

    http_req(f"{BUNNY_API}/pullzone/{pull_id}/setForceSSL", bunny_headers, 'POST', {'Hostname': cfg['cdn'], 'ForceSSL': True}, ok=(200, 204, 400))

    rule = {
        'Guid': '', 'ActionType': 6, 'ActionParameter1': HEADER_KEY,
        'ActionParameter2': cfg['secret'], 'Description': 'easy_all private origin',
        'Enabled': True, 'OrderIndex': 0, 'TriggerMatchingType': 0,
        'Triggers': [{'Type': 0, 'PatternMatches': ['*'], 'PatternMatchingType': 0}],
        'ExtraActions': [{'ActionType': 3, 'ActionParameter1': '0'}, {'ActionType': 15}, {'ActionType': 34}],
    }
    http_req(f"{BUNNY_API}/pullzone/{pull_id}/edgerules/addOrUpdate", bunny_headers, 'POST', rule, ok=(200, 201, 204))

    # 5. 保存状态文件
    write_json_file(jpath, {
        'version': STATE_VERSION, 'config': cfg, 'pull_id': pull_id,
        'records': [{'id': rec_origin['id'], 'name': cfg['origin']}, {'id': rec_cdn['id'], 'name': cfg['cdn']}],
        'zone_id': zone_id, 'lifecycle': 'ready', 'complete': True
    })
    print("apply: ready (ready)")


def run_purge(cf_token, bunny_key, jpath):
    if Path(jpath).exists():
        j = read_json_file(jpath)
        pull_id = j.get('pull_id')
        if pull_id and bunny_key:
            http_req(f"{BUNNY_API}/pullzone/{pull_id}", {'AccessKey': bunny_key, 'Accept': 'application/json'}, 'DELETE', ok=(200, 204, 404))
        zone_id = j.get('zone_id')
        if zone_id and cf_token:
            cf_headers = {'Authorization': f'Bearer {cf_token}', 'Accept': 'application/json'}
            for r in j.get('records', []):
                http_req(f"{CF_API}/zones/{zone_id}/dns_records/{r['id']}", cf_headers, 'DELETE', ok=(200, 404))
        Path(jpath).unlink(missing_ok=True)
    print("purge: deleted (deleted)")


def main():
    p = argparse.ArgumentParser(prog='bunny-api')
    p.add_argument('command', choices=['apply', 'mark-committed', 'purge', 'ips', 'validate-config', 'recover'])
    p.add_argument('--key-file')
    p.add_argument('--cloudflare-token-file')
    p.add_argument('--config')
    p.add_argument('--journal', default=DEFAULT_JOURNAL)
    p.add_argument('--input')
    args = p.parse_args()

    if args.command == 'ips':
        for ip in edge_ips(read_json_file(args.input or die("ips requires --input"))):
            print(ip)
    elif args.command == 'validate-config':
        validate_config(read_json_file(args.config or die("validate-config requires --config")))
    elif args.command == 'recover':
        j = read_json_file(args.journal)
        write_json_file(args.config, j['config'])
    elif args.command == 'mark-committed':
        if Path(args.journal).exists():
            j = read_json_file(args.journal)
            j['lifecycle'] = 'committed'
            write_json_file(args.journal, j)
        print("mark-committed: ready (committed)")
    elif args.command == 'purge':
        bkey = Path(args.key_file).read_text().strip() if args.key_file and Path(args.key_file).exists() else None
        cftoken = Path(args.cloudflare_token_file).read_text().strip() if args.cloudflare_token_file and Path(args.cloudflare_token_file).exists() else None
        run_purge(cftoken, bkey, args.journal)
    elif args.command == 'apply':
        cfg = validate_config(read_json_file(args.config or die("apply requires --config")))
        bkey = Path(args.key_file).read_text().strip()
        cftoken = Path(args.cloudflare_token_file).read_text().strip()
        run_apply(cfg, cftoken, bkey, args.journal)


if __name__ == '__main__':
    main()
