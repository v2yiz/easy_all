#!/usr/bin/env python3
"""easy_all hellogfw：直连 TCP 443 主动探测日志的一次性启发式分析。

只用 Python 3 标准库。输出的是候选线索，不是 GFW 归因证明：
它只比较内核 ``GFW_CHK:`` LOG 记录的来源与频次，不测连接时长、不看 payload。
"""

from __future__ import annotations

import argparse
import datetime as dt
import ipaddress
import os
import re
import subprocess
import sys

PREFIX = 'GFW_CHK:'
DIRECT_PORT = '443'
DEFAULT_SINCE = '24 hours ago'
REF_MIN_COUNT = 3
REF_LIMIT = 2
CANDIDATE_MIN_SECONDS = 1.0
CANDIDATE_MAX_SECONDS = 120.0
CANDIDATE_MAX_COUNT = 2
SINGBOX_UNIT = 'easy_all-singbox'

KERNEL_LOG_OVERRIDE = 'HELLOGFW_KERNEL_LOG_FILE'
SINGBOX_LOG_OVERRIDE = 'HELLOGFW_SINGBOX_LOG_FILE'

TIMESTAMP_RE = re.compile(
    r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:Z|[+-]\d{2}:?\d{2})?)(?=\s)')
TIMESTAMP_PARTS_RE = re.compile(
    r'^(?P<base>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?)(?P<tz>Z|[+-]\d{2}:?\d{2})?$')
SRC_RE = re.compile(r'(?:^|\s)SRC=(\S+)')
DPT_RE = re.compile(r'(?:^|\s)DPT=(\S+)')
ALERT_RE = re.compile(r'(?i)\b(warn|error)\b')


class InputError(Exception):
    """输入来源不可用；必须显式失败，不能当成零记录。"""


def parse_timestamp(text):
    """解析 journalctl short-iso 时间戳；统一成带时区的 datetime。"""
    match = TIMESTAMP_PARTS_RE.match(text.strip().replace(',', '.'))
    if not match:
        return None
    base = match.group('base')
    zone = match.group('tz')
    if zone in (None, 'Z'):
        iso = base + '+00:00'
    elif ':' in zone:
        iso = base + zone
    else:
        iso = '{}{}:{}'.format(base, zone[:3], zone[3:])
    try:
        return dt.datetime.fromisoformat(iso)
    except ValueError:
        return None


def read_source(command, override_env, label):
    path = os.environ.get(override_env, '').strip()
    if path:
        try:
            with open(path, 'r', encoding='utf-8', errors='replace') as handle:
                return handle.read()
        except OSError as exc:
            raise InputError('无法读取{}样本文件 {}：{}'.format(
                label, path, exc.strerror or exc)) from exc
    try:
        result = subprocess.run(command, capture_output=True, text=True,
                                errors='replace', check=False)
    except OSError as exc:
        raise InputError('无法执行 journalctl 读取{}：{}'.format(
            label, exc.strerror or exc)) from exc
    if result.returncode != 0:
        detail = (result.stderr or '').strip().splitlines()
        raise InputError('journalctl 读取{}失败（退出码 {}）：{}'.format(
            label, result.returncode, detail[0] if detail else '无错误输出'))
    return result.stdout


def collect_kernel_records(text):
    """返回 (有效记录, 匹配行总数, 关键字段无法解析的行数)。"""
    records = []
    matched = 0
    malformed = 0
    for line in text.splitlines():
        if PREFIX not in line:
            continue
        port = DPT_RE.search(line)
        if port is None or port.group(1) != DIRECT_PORT:
            continue
        matched += 1
        stamp = TIMESTAMP_RE.match(line)
        when = parse_timestamp(stamp.group(1)) if stamp else None
        source_match = SRC_RE.search(line)
        source = source_match.group(1) if source_match else ''
        if when is None:
            malformed += 1
            continue
        try:
            ipaddress.IPv4Address(source)
        except ipaddress.AddressValueError:
            malformed += 1
            continue
        records.append((when, source))
    return records, matched, malformed


def count_alerts(text):
    return sum(1 for line in text.splitlines() if ALERT_RE.search(line))


def count_sources(records):
    counts = {}
    for _, source in records:
        counts[source] = counts.get(source, 0) + 1
    return counts


def select_references(counts, explicit):
    """显式 --my-ip 优先；否则取出现次数 >= 3 的前 2 个来源作为正常客户端参照。"""
    if explicit:
        return list(dict.fromkeys(explicit))
    ranked = sorted(counts.items(), key=lambda item: (-item[1], item[0]))
    return [source for source, count in ranked if count >= REF_MIN_COUNT][:REF_LIMIT]


def find_candidates(records, counts, references):
    references_set = set(references)
    reference_records = [(when, source) for when, source in records if source in references_set]
    if not reference_records:
        return []
    candidates = []
    seen = set()
    for when, source in records:
        if source in references_set or source in seen:
            continue
        if counts.get(source, 0) > CANDIDATE_MAX_COUNT:
            continue
        best = None
        for ref_when, ref_source in reference_records:
            delta = (when - ref_when).total_seconds()
            if CANDIDATE_MIN_SECONDS <= delta <= CANDIDATE_MAX_SECONDS:
                if best is None or delta < best[0]:
                    best = (delta, ref_source)
        if best is None:
            continue
        seen.add(source)
        candidates.append((when, source, best[0], best[1]))
    candidates.sort(key=lambda item: item[0])
    return candidates


def format_when(when):
    return when.strftime('%Y-%m-%dT%H:%M:%S%z')


def build_parser():
    parser = argparse.ArgumentParser(
        prog='easy_all hellogfw',
        usage='%(prog)s [--since <时间范围>] [--my-ip <IPv4> ...]',
        description=(
            '分析直连 TCP 443 的 GFW_CHK: 内核日志。\n'
            '输出只是基于连接时序与频次的候选线索，不构成 GFW 归因证明。'),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        add_help=False,
    )
    parser.add_argument('-h', '--help', action='help',
                        help='显示本帮助并退出（免 root，无需安装状态）')
    parser.add_argument('--since', default=DEFAULT_SINCE, metavar='时间范围',
                        help='journalctl --since 的时间范围，默认 "%s"' % DEFAULT_SINCE)
    parser.add_argument('--my-ip', action='append', default=[], metavar='IPv4',
                        dest='my_ips',
                        help='已知正常客户端的 IPv4，可重复；省略时自动识别')
    return parser


def analyze(args):
    since = args.since
    kernel_log = read_source(
        ['journalctl', '-k', '--since', since, '-o', 'short-iso', '--no-pager'],
        KERNEL_LOG_OVERRIDE, '内核日志')
    records, matched, malformed = collect_kernel_records(kernel_log)
    if matched > 0 and not records:
        raise InputError(
            '匹配到 {} 条 GFW_CHK: DPT=443 记录，但时间戳或来源地址全部无法解析：'
            '结果不完整，未得出结论'.format(matched))
    singbox_log = read_source(
        ['journalctl', '-u', SINGBOX_UNIT, '--since', since, '--no-pager'],
        SINGBOX_LOG_OVERRIDE, 'sing-box 日志')
    alerts = count_alerts(singbox_log)

    counts = count_sources(records)
    references = select_references(counts, args.my_ips)
    candidates = find_candidates(records, counts, references)

    print('直连 TCP 443 主动探测日志分析（启发式线索，不构成 GFW 归因证明）')
    print('时间窗：--since {}（截至本次运行）'.format(since))
    print('采集口径：内核日志含 {} 且 DPT={}；规则按 30/min 限速'.format(PREFIX, DIRECT_PORT))
    print('内核日志匹配 SYN 记录：{} 条'.format(matched))
    print('独立来源 IP：{} 个'.format(len(counts)))
    if references:
        rendered = '、'.join(
            '{}（{} 次）'.format(source, counts.get(source, 0)) for source in references)
        print('正常客户端参照：{}'.format(rendered))
    else:
        print('正常客户端参照：参照样本不足（未指定 --my-ip，且没有出现次数 >= {} 的来源）'
              .format(REF_MIN_COUNT))
    print('sing-box 同期 WARN/ERROR：{} 条'.format(alerts))
    if malformed:
        print('注意：有 {} 条匹配记录的时间戳或来源地址无法解析，本结果不完整'.format(malformed))

    if matched == 0:
        print('该时间窗没有匹配记录（不代表未发生主动探测；30/min 限速、'
              'systemd-journald 全局 30 天保留上限与主机既有容量限制都可能让记录不完整）。')
        return 0
    if not references:
        print('没有可比对的正常客户端参照：不做无依据关联，候选列表留空。')
        return 0
    if not candidates:
        print('该时间窗没有低频陌生连接候选（1.0–120.0 秒关联 + 全窗次数 <= {} 的启发式'
              '无命中；这不代表未发生主动探测）。'.format(CANDIDATE_MAX_COUNT))
        return 0
    print('低频陌生连接候选（按时间排序；启发式线索，不构成 GFW 归因证明）：')
    for index, (when, source, delta, ref_source) in enumerate(candidates, 1):
        print('  {}. {}  全窗 {} 次  首次 {}  距参照 {} 的连接 {:.1f} 秒'.format(
            index, source, counts.get(source, 0), format_when(when), ref_source, delta))
    return 0


def main(argv):
    parser = build_parser()
    args = parser.parse_args(argv)
    for value in args.my_ips:
        try:
            ipaddress.IPv4Address(value)
        except ipaddress.AddressValueError:
            parser.error('--my-ip 不是合法 IPv4 地址：{}'.format(value))
    if not args.since.strip():
        parser.error('--since 不能为空')
    try:
        return analyze(args)
    except InputError as exc:
        print('失败：{}'.format(exc), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
