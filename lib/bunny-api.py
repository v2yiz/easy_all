#!/usr/bin/env python3
"""Bunny CDN and Cloudflare DNS management API."""
import argparse
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import sys
import time
import urllib.error
import urllib.request

STATE_VERSION = 3
DEFAULT_JOURNAL = '/etc/easy_all-bunny/ownership.json'
HEADER_KEY = 'X-Easy-All-Origin-Key'
RULE_DESCRIPTION = 'easy_all private origin'
ACTION_TYPE_NUMBERS = {
    'OverrideCacheTime': 3,
    'SetRequestHeader': 6,
    'BypassPermaCache': 15,
}
TRIGGER_TYPE_NUMBERS = {
    'Url': 0,
}
CF_API = os.environ.get('EASY_ALL_CLOUDFLARE_API', 'https://api.cloudflare.com/client/v4').rstrip('/')
BUNNY_API = os.environ.get('EASY_ALL_BUNNY_API', 'https://api.bunny.net').rstrip('/')
CONFIG_SCHEMA = {
    'type': 'object',
    'required': ['zone', 'origin', 'cdn', 'ipv4', 'name', 'secret'],
    'properties': {
        'zone': {'type': 'string', 'minLength': 1},
        'origin': {'type': 'string', 'minLength': 1},
        'cdn': {'type': 'string', 'minLength': 1},
        'ipv4': {'type': 'string', 'minLength': 1},
        'name': {'type': 'string', 'minLength': 1},
        'secret': {'type': 'string', 'minLength': 1},
        'bandwidth_gb': {'type': 'number'},
    },
}
JOURNAL_SCHEMA = {
    'type': 'object',
    'required': ['version', 'config', 'zone_id', 'pull_zone', 'records'],
    'properties': {
        'version': {'const': STATE_VERSION},
        'config': CONFIG_SCHEMA,
        'zone_id': {'type': 'string'},
        'pull_zone': {
            'type': 'object',
            'required': ['id', 'name', 'cname_domain', 'created', 'state'],
            'properties': {
                'id': {'type': 'integer'},
                'name': {'type': 'string'},
                'cname_domain': {'type': 'string'},
                'created': {'type': 'boolean'},
                'state': {'type': 'object'},
            },
        },
        'hostname': {
            'type': ['object', 'null'],
            'required': ['id', 'value', 'created', 'state'],
            'properties': {
                'id': {'type': 'integer'},
                'value': {'type': 'string'},
                'created': {'type': 'boolean'},
                'state': {'type': 'object'},
            },
        },
        'rule': {
            'type': ['object', 'null'],
            'required': ['guid', 'description', 'created', 'state'],
            'properties': {
                'guid': {'type': 'string'},
                'description': {'type': 'string'},
                'created': {'type': 'boolean'},
                'state': {'type': 'object'},
            },
        },
        'records': {
            'type': 'array',
            'items': {
                'type': 'object',
                'required': ['id', 'name', 'type', 'content', 'proxied', 'ttl', 'created'],
                'properties': {
                    'id': {'type': 'string'},
                    'name': {'type': 'string'},
                    'type': {'type': 'string'},
                    'content': {'type': 'string'},
                    'proxied': {'type': 'boolean'},
                    'ttl': {'type': 'integer'},
                    'created': {'type': 'boolean'},
                },
            },
        },
    },
}


def die(msg):
    sys.stderr.write(f"Error: {msg}\n")
    sys.exit(1)


def acquire_lock(path, inherited_fd=None):
    if inherited_fd is not None:
        expected = os.stat(path)
        inherited = os.fstat(inherited_fd)
        if (expected.st_dev, expected.st_ino) != (inherited.st_dev, inherited.st_ino):
            die(f"继承的锁文件描述符与运行时锁不一致: {path}")
        fcntl.flock(inherited_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return None
    lock_path = Path(path)
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    handle = lock_path.open('a+')
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        handle.close()
        die('另一个 easy_all 配置或云端清理任务正在运行')
    return handle


def release_lock(handle):
    if handle is not None:
        fcntl.flock(handle, fcntl.LOCK_UN)
        handle.close()


def http_req(url, headers=None, method='GET', data=None, ok=(200,)):
    headers = headers or {}
    if data is not None and not isinstance(data, (bytes, str)):
        data = json.dumps(data).encode('utf-8')
        headers.setdefault('Content-Type', 'application/json')
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read().decode('utf-8')
            return json.loads(body) if body.strip() else {}
    except urllib.error.HTTPError as error:
        body = error.read().decode('utf-8')
        if error.code == 404 and 404 in ok:
            return None
        if error.code not in ok:
            die(f"HTTP {error.code}: {body}")
        return json.loads(body) if body.strip() else {}
    except Exception as error:
        die(f"Request failed: {error}")


def read_json_file(path):
    file_path = Path(path)
    if not file_path.exists():
        die(f"File not found: {path}")
    try:
        return json.loads(file_path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        die(f"无法读取 JSON 文件 {path}: {error}")


def validate_json(data, schema, label):
    try:
        from jsonschema import ValidationError, validate
    except ImportError:
        die("缺少 Python jsonschema；请安装 python3-jsonschema 后重试")
    try:
        validate(instance=data, schema=schema)
    except ValidationError as error:
        location = '.'.join(str(part) for part in error.absolute_path) or '<root>'
        die(f"{label} schema 校验失败: {location} ({error.validator})")
    return data


def write_json_file(path, data):
    file_path = Path(path)
    file_path.parent.mkdir(parents=True, exist_ok=True)
    tmp = file_path.with_suffix(file_path.suffix + '.tmp')
    tmp.write_text(json.dumps(data, indent=2))
    os.chmod(tmp, 0o600)
    tmp.replace(file_path)


def validate_config(cfg):
    validate_json(cfg, CONFIG_SCHEMA, 'Bunny 配置')
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


def bunny_headers(key):
    return {'AccessKey': key, 'Accept': 'application/json'}


def cloudflare_headers(token):
    return {'Authorization': f'Bearer {token}', 'Accept': 'application/json'}


def expected_zone_state(cfg):
    return {
        'OriginUrl': f"https://{cfg['origin']}",
        'OriginHostHeader': cfg['origin'],
        'VerifyOriginSSL': True,
        'EnableWebSockets': True,
        'MaxWebSocketConnections': 500,
        'MonthlyBandwidthLimit': int(cfg.get('bandwidth_gb', 500)) * 1000**3,
        'Type': 1,
        'OriginType': 0,
        'Enabled': True,
        'Suspended': False,
        'ZoneSecurityEnabled': False,
        'DisableLetsEncrypt': False,
        'PreloadingScreenShowOnFirstVisit': False,
    }


def zone_state(zone):
    return {
        'OriginUrl': zone.get('OriginUrl'),
        'OriginHostHeader': zone.get('OriginHostHeader'),
        'VerifyOriginSSL': zone.get('VerifyOriginSSL'),
        'EnableWebSockets': zone.get('EnableWebSockets'),
        'MaxWebSocketConnections': zone.get('MaxWebSocketConnections'),
        'MonthlyBandwidthLimit': zone.get('MonthlyBandwidthLimit'),
        'Type': 1 if zone.get('Type') in (1, 'Volume') else zone.get('Type'),
        'OriginType': 0 if zone.get('OriginType') in (0, 'OriginUrl') else zone.get('OriginType'),
        'Enabled': zone.get('Enabled'),
        'Suspended': zone.get('Suspended'),
        'ZoneSecurityEnabled': zone.get('ZoneSecurityEnabled'),
        'DisableLetsEncrypt': zone.get('DisableLetsEncrypt'),
        'PreloadingScreenShowOnFirstVisit': zone.get('PreloadingScreenShowOnFirstVisit'),
    }


def hostname_state(hostname):
    return {
        'Value': hostname.get('Value'),
        'ForceSSL': hostname.get('ForceSSL'),
        'HasCertificate': hostname.get('HasCertificate'),
        'IsSystemHostname': hostname.get('IsSystemHostname'),
        'IsManagedHostname': hostname.get('IsManagedHostname'),
    }


def optional_string(item, key):
    value = item.get(key)
    return '' if value is None else value


def normalize_action(action):
    action_type = action.get('ActionType')
    return {
        'ActionType': (
            ACTION_TYPE_NUMBERS.get(action_type, action_type)
            if type(action_type) is str else action_type
        ),
        'ActionParameter1': optional_string(action, 'ActionParameter1'),
        'ActionParameter2': optional_string(action, 'ActionParameter2'),
        'ActionParameter3': optional_string(action, 'ActionParameter3'),
    }


def normalize_rule(rule):
    triggers = rule.get('Triggers')
    extra_actions = rule.get('ExtraActions')
    return {
        **normalize_action(rule),
        'Description': rule.get('Description'),
        'Enabled': rule.get('Enabled'),
        'OrderIndex': rule.get('OrderIndex'),
        'TriggerMatchingType': rule.get('TriggerMatchingType'),
        'Triggers': [
            {
                'Type': (
                    TRIGGER_TYPE_NUMBERS.get(trigger.get('Type'), trigger.get('Type'))
                    if type(trigger.get('Type')) is str else trigger.get('Type')
                ),
                'PatternMatches': (
                    [] if trigger.get('PatternMatches') is None
                    else trigger.get('PatternMatches')
                ),
                'PatternMatchingType': trigger.get('PatternMatchingType'),
                'Parameter1': optional_string(trigger, 'Parameter1'),
            }
            for trigger in ([] if triggers is None else triggers)
        ],
        'ExtraActions': [
            normalize_action(action)
            for action in ([] if extra_actions is None else extra_actions)
        ],
    }


def difference_paths(actual, expected, path):
    if isinstance(actual, dict) and isinstance(expected, dict):
        paths = []
        for key in sorted(set(actual) | set(expected)):
            child = f'{path}.{key}'
            if key not in actual or key not in expected:
                paths.append(child)
            elif actual[key] != expected[key]:
                hidden = ' [value hidden]' if key in (
                    'ActionParameter2',
                    'ActionParameter3',
                ) else ''
                paths.extend(difference_paths(actual[key], expected[key], child + hidden))
        return paths
    if isinstance(actual, list) and isinstance(expected, list):
        paths = []
        for index in range(max(len(actual), len(expected))):
            child = f'{path}[{index}]'
            if index >= len(actual) or index >= len(expected):
                paths.append(child)
            else:
                paths.extend(difference_paths(actual[index], expected[index], child))
        return paths
    return [] if actual == expected else [path]


def expected_rule(cfg, guid=''):
    return {
        'Guid': guid,
        'ActionType': 6,
        'ActionParameter1': HEADER_KEY,
        'ActionParameter2': cfg['secret'],
        'Description': RULE_DESCRIPTION,
        'Enabled': True,
        'OrderIndex': 0,
        'TriggerMatchingType': 0,
        'Triggers': [{'Type': 0, 'PatternMatches': ['*'], 'PatternMatchingType': 0}],
        'ExtraActions': [
            {'ActionType': 3, 'ActionParameter1': '0'},
            {'ActionType': 15},
        ],
    }


def rule_matches_except_secret(rule, cfg, legacy=False):
    expected = expected_rule(cfg)
    if legacy:
        expected['ExtraActions'].append({'ActionType': 34})
    actual_state = normalize_rule(rule)
    expected_state = normalize_rule(expected)
    actual_state['ActionParameter2'] = ''
    expected_state['ActionParameter2'] = ''
    return actual_state == expected_state


def list_pull_zones(headers):
    zones = []
    page = 1
    while True:
        result = http_req(
            f"{BUNNY_API}/pullzone?page={page}&perPage=1000&includeCertificate=true",
            headers,
        )
        items = result.get('Items') if isinstance(result, dict) else None
        if not isinstance(items, list):
            die('Bunny Pull Zone 列表结构无效')
        for item in items:
            detail = http_req(
                f"{BUNNY_API}/pullzone/{item['Id']}?includeCertificate=true",
                headers,
                ok=(200, 404),
            )
            if detail is None:
                die(f"Bunny Pull Zone {item['Id']} 在分页盘点期间消失")
            zones.append(detail)
        if not result.get('HasMoreItems'):
            return zones
        page += 1


def cloudflare_records(headers, zone_id, name):
    result = http_req(f"{CF_API}/zones/{zone_id}/dns_records?name={name}", headers).get('result')
    if not isinstance(result, list):
        die(f"Cloudflare DNS 记录结构无效: {name}")
    return [record for record in result if record.get('name') == name]


def dns_record(records, expected_type):
    typed = [record for record in records if record.get('type') == expected_type]
    if len(typed) > 1:
        die(f"Cloudflare {expected_type} 记录重复，无法安全复用")
    return typed[0] if typed else None


def journal_record(record, created):
    return {
        'id': record['id'],
        'name': record['name'],
        'type': record['type'],
        'content': record['content'],
        'proxied': record['proxied'],
        'ttl': record['ttl'],
        'created': created,
    }


def keep_created(current, identity_key, identity):
    return bool(current and current.get(identity_key) == identity and current.get('created'))


def put_zone(journal, zone, created=None):
    current = journal.get('pull_zone') or {}
    journal['pull_zone'] = {
        'id': zone['Id'],
        'name': zone.get('Name'),
        'cname_domain': zone.get('CnameDomain'),
        'created': keep_created(current, 'id', zone['Id']) if created is None else created,
        'state': zone_state(zone),
    }


def put_hostname(journal, hostname, created=None):
    current = journal.get('hostname') or {}
    journal['hostname'] = {
        'id': hostname['Id'],
        'value': hostname.get('Value'),
        'created': keep_created(current, 'id', hostname['Id']) if created is None else created,
        'state': hostname_state(hostname),
    }


def put_rule(journal, rule, created=None):
    current = journal.get('rule') or {}
    journal['rule'] = {
        'guid': rule.get('Guid'),
        'description': rule.get('Description'),
        'created': keep_created(current, 'guid', rule.get('Guid'))
        if created is None else created,
        'state': normalize_rule(rule),
    }


def put_record(journal, record, created=None):
    state = journal_record(record, False)
    current = next(
        (item for item in journal.get('records', []) if item.get('id') == record['id']),
        None,
    )
    state['created'] = keep_created(current, 'id', record['id']) if created is None else created
    journal['records'] = [
        item for item in journal.get('records', []) if item.get('id') != record['id']
    ] + [state]


def find_hostname(zone, value):
    return next(
        (
            hostname
            for hostname in zone.get('Hostnames', [])
            if isinstance(hostname, dict) and hostname.get('Value') == value
        ),
        None,
    )


def find_hostname_by_id(zone, hostname_id, value):
    return next(
        (
            hostname
            for hostname in zone.get('Hostnames', [])
            if hostname.get('Id') == hostname_id and hostname.get('Value') == value
        ),
        None,
    )


def custom_hostnames(zone):
    return {
        hostname.get('Value')
        for hostname in zone.get('Hostnames', [])
        if isinstance(hostname, dict)
        and not hostname.get('IsSystemHostname')
        and hostname.get('Value')
    }


def rules_with_description(zone):
    return [
        rule
        for rule in zone.get('EdgeRules', [])
        if isinstance(rule, dict) and rule.get('Description') == RULE_DESCRIPTION
    ]


def refresh_zone(pull_id, headers):
    zone = http_req(
        f"{BUNNY_API}/pullzone/{pull_id}?includeCertificate=true",
        headers,
        ok=(200, 404),
    )
    if zone is None:
        die(f"Bunny Pull Zone {pull_id} 不存在")
    return zone


def refresh_dns(headers, zone_id, name, expected_type):
    record = dns_record(cloudflare_records(headers, zone_id, name), expected_type)
    if record is None:
        die(f"Cloudflare {expected_type} 记录写入后未找到: {name}")
    return record


def run_apply(cfg, cf_token, bunny_key, jpath, lock_file, lock_fd):
    lock_handle = acquire_lock(lock_file, lock_fd)
    try:
        cf_headers = cloudflare_headers(cf_token)
        bunny = bunny_headers(bunny_key)
        journal = read_json_file(jpath) if Path(jpath).exists() else {}
        if journal.get('version') != STATE_VERSION:
            journal = {
                'version': STATE_VERSION,
                'config': cfg,
                'records': [],
            }
        else:
            validate_json(journal, JOURNAL_SCHEMA, 'Bunny journal')
        journal['config'] = cfg

        cloudflare_zones = http_req(
            f"{CF_API}/zones?name={cfg['zone']}", cf_headers
        ).get('result')
        if not isinstance(cloudflare_zones, list) or len(cloudflare_zones) != 1:
            die(f"Cloudflare zone 必须唯一存在: {cfg['zone']}")
        cf_zone_id = cloudflare_zones[0]['id']
        journal['zone_id'] = cf_zone_id

        origin_records = cloudflare_records(cf_headers, cf_zone_id, cfg['origin'])
        cdn_records = cloudflare_records(cf_headers, cf_zone_id, cfg['cdn'])
        origin_match = dns_record(origin_records, 'A')
        cdn_match = dns_record(cdn_records, 'CNAME')
        if any(record.get('type') in ('AAAA', 'CNAME') for record in origin_records):
            die(f"源站域名存在 IPv6 或 CNAME 记录，拒绝写入: {cfg['origin']}")
        if any(record.get('type') != 'CNAME' for record in cdn_records):
            die(f"CDN 域名存在非 CNAME 记录，拒绝写入: {cfg['cdn']}")

        zones = list_pull_zones(bunny)
        owners = [zone for zone in zones if find_hostname(zone, cfg['cdn']) is not None]
        if len(owners) > 1:
            die(f"CDN Hostname 同时属于多个 Pull Zone: {cfg['cdn']}")
        same_name = [zone for zone in zones if zone.get('Name') == cfg['name']]
        if len(same_name) > 1:
            die(f"Pull Zone 名称不唯一: {cfg['name']}")
        owner = owners[0] if owners else None
        named = same_name[0] if same_name else None
        if owner and named and owner['Id'] != named['Id']:
            print(
                f"warning: 忽略未承载 {cfg['cdn']} 的同名 Pull Zone {cfg['name']}",
                file=sys.stderr,
            )
            named = None
        selected = owner or named
        zone_created = False

        if selected:
            expected_state = expected_zone_state(cfg)
            actual_state = zone_state(selected)
            expected_core = {
                key: value for key, value in expected_state.items()
                if key not in ('DisableLetsEncrypt', 'PreloadingScreenShowOnFirstVisit')
            }
            actual_core = {key: actual_state[key] for key in expected_core}
            if actual_core != expected_core:
                die(
                    f"已有 Pull Zone {selected['Name']} 的关键配置不匹配，"
                    "拒绝自动修改共享资源"
                )
            if not selected.get('CnameDomain'):
                die(f"已有 Pull Zone {selected['Name']} 缺少 CnameDomain")
            existing_hostname = find_hostname(selected, cfg['cdn'])
            if (not existing_hostname or not existing_hostname.get('HasCertificate')) \
                    and selected.get('DisableLetsEncrypt'):
                die(f"Pull Zone {selected['Name']} 禁止 Let's Encrypt，无法申请边缘证书")
            target_only = not (custom_hostnames(selected) - {cfg['cdn']})
            existing_rules = rules_with_description(selected)
            if len(existing_rules) > 1 and not target_only:
                die("共享 Pull Zone 存在多条 easy_all Edge Rule，拒绝修改")
            expected_rule_state = normalize_rule(expected_rule(cfg))
            for rule in existing_rules:
                exact = normalize_rule(rule) == expected_rule_state
                recognized = (
                    exact
                    or rule_matches_except_secret(rule, cfg)
                    or rule_matches_except_secret(rule, cfg, True)
                )
                if not recognized:
                    paths = ', '.join(
                        difference_paths(
                            normalize_rule(rule),
                            expected_rule_state,
                            'EdgeRule',
                        )[:8]
                    )
                    die(
                        "已有 easy_all Edge Rule 的结构不匹配，拒绝修改"
                        + (f"；差异字段: {paths}" if paths else '')
                    )
                if not target_only and not exact:
                    paths = ', '.join(
                        difference_paths(
                            normalize_rule(rule),
                            expected_rule_state,
                            'EdgeRule',
                        )[:8]
                    )
                    die(
                        "共享 Pull Zone 的 easy_all Edge Rule 不是当前格式，拒绝修改"
                        + (f"；差异字段: {paths}" if paths else '')
                    )
            if not existing_rules and not target_only:
                die("共享 Pull Zone 缺少 easy_all Edge Rule，拒绝创建通配规则")

        if selected is None:
            payload = {
                **expected_zone_state(cfg),
                'Name': cfg['name'],
                'CacheControlMaxAgeOverride': 0,
                'CacheControlPublicMaxAgeOverride': 0,
                'EnableSmartCache': False,
                'CacheErrorResponses': False,
                'EnableLogging': False,
                'LogForwardingEnabled': False,
                'LoggingSaveToStorage': False,
                'EnableRequestCoalescing': False,
                'EnableOriginShield': False,
                'IpFamilyPolicy': 0,
            }
            http_req(f"{BUNNY_API}/pullzone", bunny, 'POST', payload, ok=(200, 201))
            created = [
                zone for zone in list_pull_zones(bunny)
                if zone.get('Name') == cfg['name']
            ]
            if len(created) != 1:
                die("Pull Zone 创建后无法唯一定位新资源")
            selected = created[0]
            zone_created = True
            put_zone(journal, selected, True)
            write_json_file(jpath, journal)
        else:
            zone_created = keep_created(
                journal.get('pull_zone'), 'id', selected['Id']
            )
            put_zone(journal, selected)
        target_only = zone_created or not (custom_hostnames(selected) - {cfg['cdn']})

        for name, expected_type, content, match in (
            (cfg['origin'], 'A', cfg['ipv4'], origin_match),
            (cfg['cdn'], 'CNAME', selected['CnameDomain'], cdn_match),
        ):
            changed = False
            if match is None:
                created = http_req(
                    f"{CF_API}/zones/{cf_zone_id}/dns_records",
                    cf_headers,
                    'POST',
                    {
                        'type': expected_type,
                        'name': name,
                        'content': content,
                        'proxied': False,
                        'ttl': 1,
                    },
                ).get('result')
                if not isinstance(created, dict) or not created.get('id'):
                    die(f"Cloudflare {expected_type} 创建响应缺少稳定 ID: {name}")
                put_record(journal, created, True)
                write_json_file(jpath, journal)
                match = refresh_dns(cf_headers, cf_zone_id, name, expected_type)
                changed = True
            elif (
                match.get('content') != content
                or match.get('proxied') is not False
                or match.get('ttl') != 1
            ):
                updated = http_req(
                    f"{CF_API}/zones/{cf_zone_id}/dns_records/{match['id']}",
                    cf_headers,
                    'PUT',
                    {
                        'type': expected_type,
                        'name': name,
                        'content': content,
                        'proxied': False,
                        'ttl': 1,
                    },
                ).get('result')
                if not isinstance(updated, dict) or not updated.get('id'):
                    die(f"Cloudflare {expected_type} 更新响应缺少稳定 ID: {name}")
                put_record(journal, updated)
                write_json_file(jpath, journal)
                match = refresh_dns(cf_headers, cf_zone_id, name, expected_type)
                changed = True
            put_record(journal, match)
            if changed:
                current_zone = refresh_zone(selected['Id'], bunny)
                put_zone(journal, current_zone)
                current_host = find_hostname(current_zone, cfg['cdn'])
                if current_host and not journal.get('hostname'):
                    put_hostname(journal, current_host)
                current_rules = rules_with_description(current_zone)
                if len(current_rules) == 1 and not journal.get('rule'):
                    put_rule(journal, current_rules[0])
                write_json_file(jpath, journal)
                selected = current_zone

        hostname = find_hostname(selected, cfg['cdn'])
        if hostname is None:
            http_req(
                f"{BUNNY_API}/pullzone/{selected['Id']}/addHostname",
                bunny,
                'POST',
                {'Hostname': cfg['cdn']},
                ok=(200, 201, 204),
            )
            selected = refresh_zone(selected['Id'], bunny)
            hostname = find_hostname(selected, cfg['cdn'])
            if hostname is None:
                die("Hostname 创建后无法定位")
            put_zone(journal, selected)
            put_hostname(journal, hostname, True)
            write_json_file(jpath, journal)
        else:
            put_zone(journal, selected)
            put_hostname(journal, hostname)

        if not hostname.get('HasCertificate'):
            for attempt in range(5):
                response = http_req(
                    f"{BUNNY_API}/pullzone/loadFreeCertificate?hostname={cfg['cdn']}",
                    bunny,
                    ok=(200, 202, 204, 400),
                )
                selected = refresh_zone(selected['Id'], bunny)
                hostname = find_hostname(selected, cfg['cdn'])
                if hostname and hostname.get('HasCertificate'):
                    put_zone(journal, selected)
                    put_hostname(journal, hostname)
                    write_json_file(jpath, journal)
                    break
                if attempt == 4:
                    detail = response.get('ErrorKey') if isinstance(response, dict) else None
                    die(f"Bunny 免费证书未就绪{': ' + detail if detail else ''}")
                time.sleep(3)

        if not hostname.get('ForceSSL'):
            http_req(
                f"{BUNNY_API}/pullzone/{selected['Id']}/setForceSSL",
                bunny,
                'POST',
                {'Hostname': cfg['cdn'], 'ForceSSL': True},
                ok=(200, 204),
            )
            selected = refresh_zone(selected['Id'], bunny)
            hostname = find_hostname(selected, cfg['cdn'])
            if not hostname or not hostname.get('ForceSSL'):
                die("Bunny ForceSSL 设置后未生效")
            put_zone(journal, selected)
            put_hostname(journal, hostname)
            write_json_file(jpath, journal)

        existing_rules = rules_with_description(selected)
        selected_rule = next(
            (
                rule for rule in existing_rules
                if normalize_rule(rule) == normalize_rule(expected_rule(cfg))
            ),
            None,
        )
        if selected_rule is None and existing_rules and target_only:
            rule = existing_rules[0]
            http_req(
                f"{BUNNY_API}/pullzone/{selected['Id']}/edgerules/addOrUpdate",
                bunny,
                'POST',
                expected_rule(cfg, rule.get('Guid', '')),
                ok=(200, 201, 204),
            )
            selected = refresh_zone(selected['Id'], bunny)
            selected_rule = next(
                (
                    item for item in rules_with_description(selected)
                    if item.get('Guid') == rule.get('Guid')
                ),
                None,
            )
            if selected_rule is None:
                die("Edge Rule 更新后无法定位")
            put_zone(journal, selected)
            put_hostname(journal, find_hostname(selected, cfg['cdn']))
            put_rule(journal, selected_rule)
            write_json_file(jpath, journal)
        elif selected_rule is None and target_only:
            prior_guids = {item.get('Guid') for item in existing_rules}
            http_req(
                f"{BUNNY_API}/pullzone/{selected['Id']}/edgerules/addOrUpdate",
                bunny,
                'POST',
                expected_rule(cfg),
                ok=(200, 201, 204),
            )
            selected = refresh_zone(selected['Id'], bunny)
            new_rules = [
                rule for rule in rules_with_description(selected)
                if rule.get('Guid') not in prior_guids
            ]
            if len(new_rules) != 1:
                die("Edge Rule 创建后无法唯一定位")
            selected_rule = new_rules[0]
            put_zone(journal, selected)
            put_hostname(journal, find_hostname(selected, cfg['cdn']))
            put_rule(journal, selected_rule, True)
            write_json_file(jpath, journal)
        elif selected_rule is None:
            die("共享 Pull Zone 的 Edge Rule 无法安全复用")

        extra_rules = [
            rule for rule in rules_with_description(selected)
            if rule.get('Guid') != selected_rule.get('Guid')
        ]
        if extra_rules:
            if not target_only:
                die("共享 Pull Zone 存在重复 easy_all Edge Rule，拒绝删除")
            for rule in extra_rules:
                http_req(
                    f"{BUNNY_API}/pullzone/{selected['Id']}/edgerules/{rule['Guid']}",
                    bunny,
                    'DELETE',
                    ok=(200, 204, 404),
                )
            selected = refresh_zone(selected['Id'], bunny)
            selected_rule = next(
                (
                    rule for rule in rules_with_description(selected)
                    if rule.get('Guid') == selected_rule.get('Guid')
                ),
                None,
            )
            if selected_rule is None:
                die("Edge Rule 清理后受管规则消失")

        put_zone(journal, selected)
        put_hostname(journal, find_hostname(selected, cfg['cdn']))
        put_rule(journal, selected_rule)
        put_record(journal, refresh_dns(cf_headers, cf_zone_id, cfg['origin'], 'A'))
        put_record(journal, refresh_dns(cf_headers, cf_zone_id, cfg['cdn'], 'CNAME'))
        journal['lifecycle'] = 'ready'
        journal['complete'] = True
        write_json_file(jpath, journal)
        print("apply: ready (ready)")
    finally:
        release_lock(lock_handle)


def run_purge(cf_token, bunny_key, jpath, lock_file, lock_fd):
    lock_handle = acquire_lock(lock_file, lock_fd)
    try:
        journal_path = Path(jpath)
        if not journal_path.exists():
            die(f"Bunny 所有权 journal 不存在: {jpath}")
        journal = read_json_file(jpath)
        if journal.get('version') != STATE_VERSION:
            die("旧版 Bunny journal 没有逐资源所有权，拒绝删除云端资源")
        validate_json(journal, JOURNAL_SCHEMA, 'Bunny journal')
        recorded_zone = journal.get('pull_zone') or {}
        recorded_hostname = journal.get('hostname') or {}
        recorded_rule = journal.get('rule') or {}
        created_records = [
            record for record in journal.get('records', []) if record.get('created') is True
        ]
        needs_bunny = any((resource.get('created') for resource in (
            recorded_zone, recorded_hostname, recorded_rule,
        )))
        if needs_bunny and not bunny_key:
            die("cloud purge 需要 Bunny API Key；journal 已保留")
        if created_records and not cf_token:
            die("cloud purge 需要 Cloudflare Token；journal 已保留")

        pull_id = recorded_zone.get('id')
        current_zone = None
        if pull_id and bunny_key:
            current_zone = http_req(
                f"{BUNNY_API}/pullzone/{pull_id}?includeCertificate=true",
                bunny_headers(bunny_key),
                ok=(200, 404),
            )

        if current_zone is not None and recorded_zone.get('created'):
            current_host = find_hostname_by_id(
                current_zone, recorded_hostname.get('id'), recorded_hostname.get('value')
            )
            current_rules = [
                rule for rule in current_zone.get('EdgeRules', [])
                if isinstance(rule, dict)
            ]
            if zone_state(current_zone) != recorded_zone.get('state'):
                die("自建 Pull Zone 配置已被修改，保留 Zone 与 journal")
            expected_hostnames = (
                {recorded_hostname.get('value')} if recorded_hostname else set()
            )
            if custom_hostnames(current_zone) != expected_hostnames:
                die("自建 Pull Zone 包含额外 Hostname，保留 Zone 与 journal")
            if recorded_hostname and (
                not current_host
                or hostname_state(current_host) != recorded_hostname.get('state')
            ):
                die("自建 Pull Zone 的 Hostname 已变化，保留 Zone 与 journal")
            expected_rule_count = 1 if recorded_rule else 0
            if len(current_rules) != expected_rule_count:
                die("自建 Pull Zone 的 Edge Rule 数量已变化，保留 Zone 与 journal")
            if recorded_rule and (
                current_rules[0].get('Guid') != recorded_rule.get('guid')
                or normalize_rule(current_rules[0])
                != normalize_rule(recorded_rule.get('state'))
            ):
                die("自建 Pull Zone 的 Edge Rule 已被修改，保留 Zone 与 journal")
        elif current_zone is not None:
            if recorded_hostname.get('created'):
                current_host = find_hostname_by_id(
                    current_zone, recorded_hostname.get('id'), recorded_hostname.get('value')
                )
                if current_host and hostname_state(current_host) != recorded_hostname.get('state'):
                    die("复用 Pull Zone 的 Hostname 已被修改，保留 journal")
            if recorded_rule.get('created'):
                current_rule = next(
                    (
                        rule for rule in rules_with_description(current_zone)
                        if rule.get('Guid') == recorded_rule.get('guid')
                    ),
                    None,
                )
                if current_rule and (
                    normalize_rule(current_rule)
                    != normalize_rule(recorded_rule.get('state'))
                ):
                    die("复用 Pull Zone 的 Edge Rule 已被修改，保留 journal")

        pending_records = []
        cf_headers = cloudflare_headers(cf_token) if cf_token else None
        for record in created_records:
            current = http_req(
                f"{CF_API}/zones/{journal.get('zone_id')}/dns_records/{record['id']}",
                cf_headers,
                ok=(200, 404),
            )
            if current is None:
                continue
            current = current.get('result')
            if journal_record(current, True) != record:
                die(f"Cloudflare DNS 记录 {record['id']} 已被修改，保留 journal")
            pending_records.append(record)

        if current_zone is not None and recorded_zone.get('created'):
            http_req(
                f"{BUNNY_API}/pullzone/{pull_id}",
                bunny_headers(bunny_key),
                'DELETE',
                ok=(200, 204, 404),
            )
        elif current_zone is not None:
            if recorded_hostname.get('created') \
                    and find_hostname_by_id(
                        current_zone,
                        recorded_hostname.get('id'),
                        recorded_hostname.get('value'),
                    ):
                http_req(
                    f"{BUNNY_API}/pullzone/{pull_id}/removeHostname",
                    bunny_headers(bunny_key),
                    'DELETE',
                    {'Hostname': recorded_hostname.get('value')},
                    ok=(200, 204, 404),
                )
            if recorded_rule.get('created') \
                    and any(
                        rule.get('Guid') == recorded_rule.get('guid')
                        for rule in rules_with_description(current_zone)
                    ):
                http_req(
                    f"{BUNNY_API}/pullzone/{pull_id}/edgerules/{recorded_rule['guid']}",
                    bunny_headers(bunny_key),
                    'DELETE',
                    ok=(200, 204, 404),
                )

        for record in pending_records:
            http_req(
                f"{CF_API}/zones/{journal.get('zone_id')}/dns_records/{record['id']}",
                cf_headers,
                'DELETE',
                ok=(200, 204, 404),
            )
        journal_path.unlink()
        print("purge: deleted (deleted)")
    finally:
        release_lock(lock_handle)


def main():
    parser = argparse.ArgumentParser(prog='bunny-api')
    parser.add_argument(
        'command',
        choices=['apply', 'mark-committed', 'purge', 'ips', 'validate-config', 'recover'],
    )
    parser.add_argument('--key-file')
    parser.add_argument('--cloudflare-token-file')
    parser.add_argument('--config')
    parser.add_argument('--journal', default=DEFAULT_JOURNAL)
    parser.add_argument('--input')
    parser.add_argument('--lock-file')
    parser.add_argument('--lock-fd', type=int)
    args = parser.parse_args()
    lock_file = args.lock_file or str(Path(args.journal).parent / 'runtime-write.lock')

    if args.command == 'ips':
        for ip in edge_ips(read_json_file(args.input or die("ips requires --input"))):
            print(ip)
    elif args.command == 'validate-config':
        validate_config(read_json_file(args.config or die("validate-config requires --config")))
    elif args.command == 'recover':
        journal = read_json_file(args.journal)
        write_json_file(args.config, validate_config(journal['config']))
    elif args.command == 'mark-committed':
        if Path(args.journal).exists():
            journal = read_json_file(args.journal)
            if journal.get('version') == STATE_VERSION:
                validate_json(journal, JOURNAL_SCHEMA, 'Bunny journal')
            journal['lifecycle'] = 'committed'
            write_json_file(args.journal, journal)
        print("mark-committed: ready (committed)")
    elif args.command == 'purge':
        bunny_key = (
            Path(args.key_file).read_text().strip()
            if args.key_file and Path(args.key_file).exists()
            else None
        )
        cloudflare_token = (
            Path(args.cloudflare_token_file).read_text().strip()
            if args.cloudflare_token_file and Path(args.cloudflare_token_file).exists()
            else None
        )
        run_purge(cloudflare_token, bunny_key, args.journal, lock_file, args.lock_fd)
    elif args.command == 'apply':
        cfg = validate_config(read_json_file(args.config or die("apply requires --config")))
        bunny_key = Path(args.key_file).read_text().strip()
        cloudflare_token = Path(args.cloudflare_token_file).read_text().strip()
        run_apply(cfg, cloudflare_token, bunny_key, args.journal, lock_file, args.lock_fd)


if __name__ == '__main__':
    main()
