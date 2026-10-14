#!/usr/bin/env python3
"""Replace only three lab aliases; keep unrelated hosts entries and comments."""
import argparse
import ipaddress
from pathlib import Path

START = '# BEGIN CONTOSO ORDER DESK'
END = '# END CONTOSO ORDER DESK'
ALIASES = ('onprem-sql', 'onprem-app', 'onprem-nginx')


def address(value):
    ip = ipaddress.ip_address(value)
    if ip.version != 4 or not ip.is_private or ip.is_loopback or ip.is_unspecified or ip.is_multicast or ip.is_link_local:
        raise ValueError('Use a private, routable lab IPv4 address.')
    return str(ip)


def replace_hosts(text, addresses):
    if text.splitlines().count(START) != text.splitlines().count(END) or text.splitlines().count(START) > 1:
        raise ValueError('Malformed Order Desk hosts markers; repair before proceeding.')
    result = []
    inside = False
    for line in text.splitlines():
        if line == START:
            inside = True
            continue
        if line == END:
            if not inside:
                raise ValueError('Out-of-order hosts markers.')
            inside = False
            continue
        if inside:
            continue
        body, separator, comment = line.partition('#')
        fields = body.split()
        if len(fields) >= 2 and any(name.lower() in ALIASES for name in fields[1:]):
            kept = [name for name in fields[1:] if name.lower() not in ALIASES]
            if kept:
                result.append(fields[0] + '\t' + ' '.join(kept) + (' #' + comment if separator else ''))
            elif separator:
                result.append('#' + comment)
        else:
            result.append(line)
    if inside:
        raise ValueError('Unclosed hosts markers.')
    while result and result[-1] == '':
        result.pop()
    result += ['', START]
    result += [address(ip) + '\t' + alias for alias, ip in zip(ALIASES, addresses)]
    result += [END]
    return '\n'.join(result) + '\n'


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--file', default='/etc/hosts')
    parser.add_argument('--sql', default='192.168.0.11')
    parser.add_argument('--app', default='192.168.0.13')
    parser.add_argument('--nginx', default='192.168.0.12')
    args = parser.parse_args()
    path = Path(args.file)
    output = replace_hosts(path.read_text(), (args.sql, args.app, args.nginx))
    path.write_text(output)
