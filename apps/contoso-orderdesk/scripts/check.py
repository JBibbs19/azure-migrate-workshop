#!/usr/bin/env python3
"""Actual target-side HTTP validation; writes only with an explicit --write switch."""
import argparse
import json
import urllib.error
import urllib.parse
import urllib.request


def call(base, path, data=None, expected=200):
    body = None if data is None else urllib.parse.urlencode(data).encode('utf-8')
    req = urllib.request.Request(base + path, data=body,
                                 headers={'Content-Type': 'application/x-www-form-urlencoded'})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(req, timeout=20) as response:
            if response.status != expected:
                raise ValueError('Unexpected HTTP status for ' + path)
            return response.read().decode('utf-8')
    except urllib.error.HTTPError as error:
        if error.code == expected:
            return error.read().decode('utf-8')
        raise ValueError('HTTP {0} from {1}; inspect application readiness locally.'.format(error.code, path)) from None


def validate(base, health_only=False, api_only=False, write=False):
    health = json.loads(call(base, '/api/health'))
    assert health['status'] == 'healthy' and health['server'] == 'OnPrem-Linux-App'
    assert health['app'] == 'Contoso Order Desk' and isinstance(health['timestamp'], str)
    if health_only:
        print('PASS: preserved health contract; Contoso Order Desk is responding.')
        return
    assert json.loads(call(base, '/api/info'))['app'] == 'Contoso Order Desk'
    assert json.loads(call(base, '/api/ready'))['status'] == 'ready'
    data = json.loads(call(base, '/api/orders'))
    assert isinstance(data['count'], int) and isinstance(data['customerCount'], int)
    assert isinstance(data['orders'], list) and isinstance(data['customers'], list)
    assert len(data['orders']) <= 20 and len(data['customers']) <= 20
    if not api_only:
        assert 'Contoso Order Desk' in call(base, '/')
    if write:
        assert data['customers'], 'No existing seeded customers; no write attempted.'
        form = {'customerId': data['customers'][0]['customerId'], 'productName': 'Order Desk validation',
                'quantity': '1', 'unitPrice': '9.99'}
        invalid = dict(form, quantity='11')
        assert 'error' in json.loads(call(base, '/api/orders', invalid, 400))
        created = json.loads(call(base, '/api/orders', form, 201))
        after = json.loads(call(base, '/api/orders'))
        assert created['status'] == 'created' and isinstance(created['orderId'], int)
        assert any(row['orderId'] == created['orderId'] for row in after['orders'])
        assert after['count'] >= data['count'] + 1
        print('PASS: rejected invalid input and inserted/read back one real sample order #{0}.'.format(created['orderId']))
    print('PASS: health, info, SQL readiness, recent orders and counts' + ('.' if api_only else ', named HTML desk.'))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--base', default='http://127.0.0.1:3001')
    parser.add_argument('--health-only', action='store_true')
    parser.add_argument('--api-only', action='store_true')
    parser.add_argument('--write', action='store_true')
    args = parser.parse_args()
    uri = urllib.parse.urlparse(args.base)
    if uri.scheme != 'http' or uri.username or uri.password or uri.path not in ('', '/'):
        raise SystemExit('Use a local-lab HTTP base URL without credentials or a path.')
    try:
        validate(args.base.rstrip('/'), args.health_only, args.api_only, args.write)
    except (ValueError, AssertionError, KeyError, urllib.error.URLError, OSError) as error:
        raise SystemExit('FAIL: ' + str(error)) from None
