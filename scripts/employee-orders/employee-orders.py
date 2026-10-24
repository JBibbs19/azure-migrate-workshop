#!/usr/bin/env python3
"""Independent synthetic employee orders through the local Nginx proxy; UTC daytime only."""
import datetime as dt
from decimal import Decimal, InvalidOperation
import fcntl
import json
import os
from pathlib import Path
import random
import signal
import threading
import urllib.parse
import urllib.request

UTC = dt.timezone.utc
BASE = 'http://127.0.0.1:8080'
STATE = Path('/var/lib/contoso-employee-orders/state.json')
LOCK = Path('/run/contoso-employee-orders/worker.lock')
USER_AGENT = 'Contoso-Employee-Orders/1.0 (synthetic Linux-Web)'
MAX_BYTES = 524288
PAGE_SIZE = 20
REQUEST_TIMEOUT = 15
MAX_CYCLE_REQUESTS = 5  # Up to three order pages, options and one non-retried POST.


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate JSON field')
        result[key] = value
    return result


def now_utc():
    return dt.datetime.now(UTC)


def stamp(value):
    return value.astimezone(UTC).isoformat()


def daytime(value):
    return 6 <= value.astimezone(UTC).hour < 22


def dawn(value):
    value = value.astimezone(UTC)
    result = value.replace(hour=6, minute=0, second=0, microsecond=0)
    return result if value < result else result + dt.timedelta(days=1)


def dusk(value):
    return value.astimezone(UTC).replace(hour=22, minute=0, second=0, microsecond=0)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Client:
    def __init__(self):
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def request(self, path, data=None, params=None):
        if path not in ('/api/order-options', '/api/orders') or (data is not None and path != '/api/orders'):
            raise ValueError('Unapproved employee-order endpoint')
        if params is not None:
            if data is not None or path != '/api/orders' or not isinstance(params, dict):
                raise ValueError('Unapproved paging request')
            if set(params) not in ({'pageSize'}, {'pageSize', 'anchor', 'before'}):
                raise ValueError('Unapproved paging fields')
            if type(params['pageSize']) is not int or params['pageSize'] != PAGE_SIZE:
                raise ValueError('Invalid employee page size')
            if 'anchor' in params and (not valid_anchor(params['anchor']) or not valid_id(params['before']) or
                                       params['before'] > params['anchor']):
                raise ValueError('Invalid employee cursor')
        target = BASE + path + ('?' + urllib.parse.urlencode(params) if params is not None else '')
        headers = {'User-Agent': USER_AGENT, 'Accept': 'application/json'}
        if data is not None:
            headers['Content-Type'] = 'application/x-www-form-urlencoded; charset=UTF-8'
        request = urllib.request.Request(target, data=data, headers=headers)
        with self.opener.open(request, timeout=REQUEST_TIMEOUT) as response:
            expected = 200 if data is None else 201
            if response.status != expected or response.geturl() != target:
                raise ValueError('Unexpected employee-order response')
            if response.headers.get_content_type() != 'application/json':
                raise ValueError('Expected JSON')
            raw = response.read(MAX_BYTES + 1)
            if len(raw) > MAX_BYTES:
                raise ValueError('Employee-order response too large')
            return json.loads(raw.decode('utf-8'), parse_float=Decimal, object_pairs_hook=unique_object,
                              parse_constant=lambda _: (_ for _ in ()).throw(ValueError('Non-finite JSON')))


def valid_id(value):
    return type(value) is int and 1 <= value <= 2147483647


def valid_anchor(value):
    return type(value) is int and 0 <= value <= 2147483647


def order_page(value, anchor=None, before=None):
    if not isinstance(value, dict):
        raise ValueError('Invalid order-page contract')
    for key in ('count', 'customerCount'):
        if type(value.get(key)) is not int or value[key] < 0:
            raise ValueError('Invalid global count')
    rows, customers, page = value.get('orders'), value.get('customers'), value.get('pagination')
    if not isinstance(rows, list) or len(rows) > PAGE_SIZE or not isinstance(customers, list) or len(customers) > 20:
        raise ValueError('Unbounded order page')
    for customer in customers:
        if not isinstance(customer, dict) or not valid_id(customer.get('customerId')) or not isinstance(customer.get('name'), str):
            raise ValueError('Invalid page customer')
    if not isinstance(page, dict) or type(page.get('pageSize')) is not int or page['pageSize'] != PAGE_SIZE:
        raise ValueError('Invalid page size')
    if not valid_anchor(page.get('anchor')) or (anchor is not None and page['anchor'] != anchor):
        raise ValueError('Snapshot changed')
    for key in ('hasNext', 'hasPrevious'):
        if type(page.get(key)) is not bool:
            raise ValueError('Invalid page direction')
    previous = page['anchor'] + 1 if before is None else before
    for row in rows:
        if not isinstance(row, dict) or not {'orderId', 'customerId', 'customer', 'productName', 'quantity', 'unitPrice', 'orderDate'} <= set(row):
            raise ValueError('Incomplete order row')
        if not valid_id(row.get('orderId')) or not valid_id(row.get('customerId')):
            raise ValueError('Invalid order row')
        if not row['orderId'] < previous or row['orderId'] > page['anchor']:
            raise ValueError('Order cursor did not advance')
        previous = row['orderId']
        if not valid_id(row.get('quantity')) or not isinstance(row.get('customer'), str) or not isinstance(row.get('productName'), str):
            raise ValueError('Invalid order fields')
        price, date = row.get('unitPrice'), row.get('orderDate')
        if price is not None and (type(price) not in (int, Decimal) or not Decimal(price).is_finite()):
            raise ValueError('Invalid recorded price')
        if date is not None and not isinstance(date, str):
            raise ValueError('Invalid order date')
    for flag, cursor, index in [('hasNext', 'nextBefore', -1), ('hasPrevious', 'previousAfter', 0)]:
        if cursor not in page or (page[flag] and (not rows or not valid_id(page[cursor]) or page[cursor] != rows[index]['orderId'])):
            raise ValueError('Invalid page cursor')
        if not page[flag] and page[cursor] is not None:
            raise ValueError('Unexpected page cursor')
    if page['hasNext'] and len(rows) != PAGE_SIZE:
        raise ValueError('Incomplete nonterminal page')
    if before is not None and not rows:
        raise ValueError('History changed; skip this cycle')
    return page, len(rows)


class CycleInterrupted(Exception):
    pass


def options(value):
    if not isinstance(value, dict) or value.get('source') != 'order-history':
        raise ValueError('Invalid order-options contract')
    customers, products = value.get('customers'), value.get('products')
    if not isinstance(customers, list) or not isinstance(products, list) or len(customers) > 500 or len(products) > 500:
        raise ValueError('Unbounded order options')
    ids = sorted({row['customerId'] for row in customers
                  if isinstance(row, dict) and valid_id(row.get('customerId'))})
    eligible = {}
    for row in products:
        if not isinstance(row, dict):
            continue
        name = row.get('productName')
        if not isinstance(name, str) or not name or name != name.strip() or any(ord(c) < 32 or 127 <= ord(c) <= 159 for c in name):
            continue
        try:
            if len(name.encode('utf-16-le')) // 2 > 100:
                continue
            raw = row.get('unitPrice')
            if type(raw) not in (int, Decimal):
                continue
            price = Decimal(raw)
            if not price.is_finite() or not Decimal('0.01') <= price <= Decimal('1000') or price != price.quantize(Decimal('0.01')):
                continue
        except (UnicodeError, InvalidOperation, ValueError):
            continue
        eligible.setdefault(name, format(price.quantize(Decimal('0.01')), 'f'))
    return ids, sorted(eligible.items())


def read_state(path=STATE):
    try:
        if path.stat().st_size > 4096:
            return {}
        value = json.loads(path.read_text(encoding='utf-8'))
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def save_state(value, path=STATE):
    pending = path.with_suffix('.pending')
    with pending.open('w', encoding='utf-8') as stream:
        json.dump(value, stream, ensure_ascii=True)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(pending, path)


def log(message):
    print('employee-orders synthetic: ' + message, flush=True)


class Worker:
    def __init__(self, client, stop, clock=now_utc, rng=None, state_path=STATE):
        self.client, self.stop, self.clock = client, stop, clock
        self.rng = rng or random.SystemRandom()
        self.path = state_path
        self.state = read_state(state_path)

    def record(self, phase, due, outcome=None):
        self.state.update(pid=os.getpid(), phase=phase, updatedUtc=stamp(self.clock()),
                          nextDueUtc=stamp(due))
        if outcome is not None:
            self.state['lastOutcome'] = outcome
        save_state(self.state, self.path)

    def wait_until(self, due):
        while not self.stop.is_set():
            now = self.clock()
            if not daytime(now):
                target, phase = dawn(now), 'night-sleep'
            else:
                target, phase = min(due, dusk(now)), 'day-wait'
                if now >= target:
                    return
            self.record(phase, target)
            self.stop.wait(min(10, max(0.01, (target - now).total_seconds())))

    def eligible_now(self):
        if self.stop.is_set() or not daytime(self.clock()):
            raise CycleInterrupted()

    def read(self, phase, due, path, params=None):
        self.eligible_now()
        self.record(phase, due)
        self.eligible_now()
        value = self.client.request(path, params=params) if params is not None else self.client.request(path)
        self.record(phase, due)  # A heartbeat between each request, not just once per multi-page cycle.
        self.eligible_now()
        return value

    def cycle(self):
        now = self.clock()
        if not daytime(now) or self.stop.is_set():
            return dawn(now)
        delay = self.rng.randint(120, 1200)
        requested_pages = self.rng.randint(1, 3)
        # Cover all five request timeouts before reading; refresh again immediately before the one possible write.
        due = now + dt.timedelta(seconds=delay + MAX_CYCLE_REQUESTS * REQUEST_TIMEOUT)
        self.state.update(pagesRequested=requested_pages, pagesBrowsed=0, recordsBrowsed=0)
        phase, outcome = 'browsing-orders', 'browse-unavailable; skipped'
        try:
            anchor, before = None, None
            for _ in range(requested_pages):
                params = dict(pageSize=PAGE_SIZE)
                if before is not None:
                    params.update(anchor=anchor, before=before)
                value = self.read('browsing-orders', due, '/api/orders', params)
                page, records = order_page(value, anchor, before)
                anchor = page['anchor']
                self.state['pagesBrowsed'] += 1
                self.state['recordsBrowsed'] += records
                self.record('browsing-orders', due)
                if not records:
                    raise ValueError('No fresh order rows; skip this cycle')
                if not page['hasNext']:
                    break
                before = page['nextBefore']
            phase = 'fetching-options'
            ids, products = options(self.read(phase, due, '/api/order-options'))
            if ids and products:
                name, price = self.rng.choice(products)
                fields = dict(customerId=self.rng.choice(ids), productName=name,
                              quantity=self.rng.randint(1, 3), unitPrice=price)
                body = urllib.parse.urlencode(fields, encoding='utf-8', errors='strict').encode('ascii')
                self.eligible_now()
                due = self.clock() + dt.timedelta(seconds=delay + REQUEST_TIMEOUT)
                self.record('submitting', due)
                self.eligible_now()
                try:
                    response = self.client.request('/api/orders', body)
                    if not isinstance(response, dict) or response.get('status') != 'created' or not valid_id(response.get('orderId')):
                        raise ValueError('Invalid insert acknowledgement')
                    outcome = 'created orderId=' + str(response['orderId'])
                except Exception:
                    # Even HTTP/parse/connection failures may follow a committed insert.
                    outcome = 'outcome-unknown; no POST retry'
            else:
                outcome = 'no-eligible-options; skipped'
        except CycleInterrupted:
            outcome = 'day-window-ended; skipped' if not daytime(self.clock()) else 'stopping; skipped'
        except Exception:
            outcome = ('browse-unavailable' if phase == 'browsing-orders' else 'options-unavailable') + '; skipped'
        now = self.clock()
        due = now + dt.timedelta(seconds=delay)
        self.record('stopping' if self.stop.is_set() else ('day-wait' if daytime(now) else 'night-sleep'),
                    due if daytime(now) else dawn(now), outcome)
        log('pages=' + str(self.state['pagesBrowsed']) + '/' + str(requested_pages) +
            '; records=' + str(self.state['recordsBrowsed']) + '; ' + outcome + '; next independent cycle=' + stamp(due))
        return due

    def run(self):
        due = self.clock()
        try:
            saved = dt.datetime.fromisoformat(self.state.get('nextDueUtc', ''))
            if saved.tzinfo is not None and saved > due:
                due = saved.astimezone(UTC)
        except (ValueError, TypeError):
            pass
        log('started; UTC active window 06:00 inclusive to 22:00 exclusive')
        while not self.stop.is_set():
            self.wait_until(due)
            if self.stop.is_set():
                break
            due = self.cycle()
        self.record('stopped', due)  # Stop must not erase the persisted no-replay boundary.
        log('stopped; no queued orders')


def status():
    state = read_state()
    now = now_utc()
    try:
        updated = dt.datetime.fromisoformat(state['updatedUtc'])
        fresh = updated.tzinfo is not None and -5 <= (now - updated).total_seconds() <= 60
        live = state.get('phase') in ('night-sleep', 'day-wait', 'browsing-orders', 'fetching-options', 'submitting')
        expected = int(os.environ.get('EMPLOYEE_EXPECTED_PID', '0'))
        live = live and expected > 0 and state.get('pid') == expected
        due = dt.datetime.fromisoformat(state['nextDueUtc'])
        if due.tzinfo is None:
            raise ValueError('Missing UTC offset')
    except (KeyError, ValueError, TypeError):
        fresh, live = False, False
    print(json.dumps(dict(synthetic='employee-orders', utcPhase='day' if daytime(now) else 'night',
                          healthy=fresh and live, state=state), separators=(',', ':')))
    return 0 if fresh and live else 1


def main():
    import sys
    if sys.argv[1:] == ['--status']:
        return status()
    if sys.argv[1:]:
        return 2
    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    with LOCK.open('w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            log('duplicate refused')
            return 1
        Worker(Client(), stop).run()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
