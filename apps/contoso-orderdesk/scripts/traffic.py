#!/usr/bin/env python3
"""No SQL credentials: all database work is performed inside the Tomcat JVM."""
import json
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


def request(base, path, data=None):
    body = None if data is None else urllib.parse.urlencode(data).encode('ascii')
    req = urllib.request.Request(base + path, data=body,
                                 headers={'Content-Type': 'application/x-www-form-urlencoded'})
    # Do not route local lab traffic through environment-configured Internet proxies.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(req, timeout=15) as response:
        return json.load(response)


def cycle(base):
    health = request(base, '/api/health')
    if health.get('app') != 'Contoso Order Desk' or health.get('status') != 'healthy':
        raise ValueError('Not the expected Tomcat application')
    rows = request(base, '/api/orders')
    customers = rows.get('customers', [])
    if not customers:
        print('No existing customer; no order inserted.', flush=True)
        return
    created = request(base, '/api/orders', {
        'customerId': customers[0]['customerId'], 'productName': 'Order Desk demo',
        'quantity': 1, 'unitPrice': '9.99'})
    print('Order Desk cycle completed; order #{0}.'.format(created['orderId']), flush=True)


def main():
    config = json.loads(Path('/etc/contoso-orderdesk-traffic.json').read_text())
    base = config['baseUrl']
    interval = int(config['intervalSeconds'])
    if base != 'http://onprem-nginx:8080' or not 20 <= interval <= 600:
        raise ValueError('Invalid local traffic configuration')
    while True:
        try:
            cycle(base)
        except (urllib.error.URLError, ValueError, KeyError, TimeoutError, OSError):
            print('Order Desk cycle unavailable; check proxy/application/readiness locally.', flush=True)
        time.sleep(interval)


if __name__ == '__main__':
    main()
