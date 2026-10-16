#!/usr/bin/env python3
"""Optional source-lab CPU history. No network, application or artificial disk workload."""
import argparse
import datetime as dt
import fcntl
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import time
import uuid

UNIT = 'lab-cpu-simulation.service'
ROOT = Path('/var/lib/lab-cpu-simulation')
INSTALL = Path('/opt/lab-cpu-simulation')
CONTROL_LOCK = Path('/run/lab-cpu-simulation-control.lock')
DAY_HOURS = 16
NIGHT_HOURS = 24 - DAY_HOURS
DAY_START = 6
DAY_END = DAY_START + DAY_HOURS
DAY_TARGET = 15.0
NIGHT_TARGET = 2.0
EXPECTED_CPUS = 2
MAX_CORE_DUTY = DAY_TARGET * EXPECTED_CPUS / 100.0
HIGH_CPU = 30.0
RESUME_CPU = 20.0
COOLDOWN_SECONDS = 60.0
SAMPLE_SECONDS = 2.0
FRAME_SECONDS = 0.1
STALE_SECONDS = SAMPLE_SECONDS * 5


def utc(epoch=None):
    return dt.datetime.fromtimestamp(time.time() if epoch is None else epoch, dt.timezone.utc).isoformat()


def phase_target(epoch):
    hour = dt.datetime.fromtimestamp(epoch, dt.timezone.utc).hour
    return ('day', DAY_TARGET) if DAY_START <= hour < DAY_END else ('night', NIGHT_TARGET)


def cpu_snapshot(text=None):
    line = (Path('/proc/stat').read_text() if text is None else text).splitlines()[0].split()
    if len(line) < 9 or line[0] != 'cpu':
        raise ValueError('invalid_cpu_sample')
    values = [int(x) for x in line[1:9]]
    if any(x < 0 for x in values):
        raise ValueError('invalid_cpu_sample')
    # user/nice already include guest/guest_nice: only the first eight fields count.
    return sum(values), values[3] + values[4], values


def total_percent(before, after):
    if any(new < old for old, new in zip(before[2], after[2])):
        raise ValueError('counter_rollback')
    elapsed, idle = after[0] - before[0], after[1] - before[1]
    if elapsed <= 0 or idle < 0 or idle > elapsed:
        raise ValueError('invalid_cpu_delta')
    return 100.0 * (elapsed - idle) / elapsed


def decision(total, worker, cpus, now, guard=False, cooldown_until=0.0, epoch=None):
    phase, target = phase_target(time.time() if epoch is None else epoch)
    result = dict(phase=phase, targetTotalCpuPercent=target, targetWorkerCpuPercent=0.0,
                  measuredTotalCpuPercent=total, measuredWorkerCpuPercent=worker,
                  baselineCpuPercent=None, baselineAboveGoal=False, guard=guard,
                  cooldownRemainingSeconds=max(0.0, cooldown_until - now), reason='measurement_invalid')
    valid = (cpus == EXPECTED_CPUS and all(isinstance(x, (int, float)) and math.isfinite(x)
             for x in (total, worker)) and 0 <= total <= 100 and 0 <= worker <= 100 / cpus)
    if not valid:
        # Invalid telemetry never authorizes a busy frame or clears the safety guard.
        result['measuredTotalCpuPercent'] = None
        result['measuredWorkerCpuPercent'] = None
        return result, guard, cooldown_until
    baseline = max(0.0, total - worker)
    result.update(baselineCpuPercent=baseline, baselineAboveGoal=baseline >= target)
    if total >= HIGH_CPU:
        guard, cooldown_until = True, now + COOLDOWN_SECONDS
    elif guard and total >= RESUME_CPU:
        cooldown_until = now + COOLDOWN_SECONDS
    elif guard and now >= cooldown_until:
        guard = False
    result.update(guard=guard, cooldownRemainingSeconds=max(0.0, cooldown_until - now))
    if guard:
        result['reason'] = 'high_cpu_cooldown'
    elif baseline >= target:
        result['reason'] = 'baseline_above_goal'
    else:
        result['reason'] = 'running'
        result['targetWorkerCpuPercent'] = min(MAX_CORE_DUTY * 100 / cpus, target - baseline)
    return result, guard, cooldown_until


def atomic_json(path, value):
    pending = path.with_suffix('.pending')
    pending.write_text(json.dumps(value, allow_nan=False, separators=(',', ':')) + '\n')
    pending.replace(path)


def process_identity(pid):
    return Path('/proc/{}/stat'.format(pid)).read_text().split(') ', 1)[1].split()[19]


def expired(config, started, now, epoch):
    return epoch >= config['expiresEpoch'] or now - started >= config['durationSeconds']


def worker(config):
    ROOT.mkdir(parents=True, exist_ok=True)
    lock = (ROOT / 'worker.lock').open('a')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return 1
    started = time.monotonic()
    state = dict(runId=config['runId'], pid=os.getpid(), bootId=Path('/proc/sys/kernel/random/boot_id').read_text().strip(),
                 processStart=process_identity(os.getpid()), expiresUtc=utc(config['expiresEpoch']),
                 startedUtc=utc(), status='starting', heartbeatUtc=utc())
    stop = False

    def terminate(*_):
        nonlocal stop
        stop = True
    signal.signal(signal.SIGTERM, terminate)
    signal.signal(signal.SIGINT, terminate)
    guard, cooldown_until = False, 0.0
    cpus = os.cpu_count()
    previous = None
    previous_process = time.process_time()
    previous_time = started
    duty = 0.0
    next_sample = started
    value = 1
    try:
        while not stop and not expired(config, started, time.monotonic(), time.time()):
            now = time.monotonic()
            if now >= next_sample:
                total = measured_worker = None
                try:
                    current = cpu_snapshot()
                    current_process = time.process_time()
                    if previous is not None:
                        total = total_percent(previous, current)
                        wall = now - previous_time
                        measured_worker = 100.0 * (current_process - previous_process) / wall / cpus if wall > 0 else None
                    previous = current
                    previous_process, previous_time = current_process, now
                except (OSError, ValueError, TypeError, ZeroDivisionError):
                    previous = None
                report, guard, cooldown_until = decision(total, measured_worker, cpus, now, guard, cooldown_until)
                duty = report['targetWorkerCpuPercent'] * (cpus or EXPECTED_CPUS) / 100.0
                state.update(report, status='running', heartbeatUtc=utc())
                atomic_json(ROOT / 'state.json', state)
                next_sample = now + SAMPLE_SECONDS
            frame = time.monotonic()
            busy_end = frame + FRAME_SECONDS * min(MAX_CORE_DUTY, duty)
            busy_end = min(busy_end, started + config['durationSeconds'])
            while not stop and time.monotonic() < busy_end and time.time() < config['expiresEpoch']:
                value = (value * 1664525 + 1013904223) & 0xffffffff
            time.sleep(max(0.0, min(FRAME_SECONDS, frame + FRAME_SECONDS - time.monotonic(),
                                   config['expiresEpoch'] - time.time(), started + config['durationSeconds'] - time.monotonic())))
        state.update(status='stopped' if stop else 'expired', targetWorkerCpuPercent=0.0, heartbeatUtc=utc())
    except Exception:
        state.update(status='failed', reason='worker_failed_closed', targetWorkerCpuPercent=0.0, heartbeatUtc=utc())
    finally:
        atomic_json(ROOT / 'state.json', state)
        lock.close()
    return 0


def command(*args):
    result = subprocess.run(args, text=True, capture_output=True, timeout=20)
    if result.returncode:
        raise ValueError('cpu_control_failed')
    return result.stdout


def service():
    result = subprocess.run(('systemctl', 'show', UNIT, '--property=LoadState,ActiveState,MainPID,UnitFileState'),
                            text=True, capture_output=True, timeout=20)
    text = result.stdout
    if result.returncode not in (0, 4):
        raise ValueError('cpu_service_unknown')
    fields = dict(line.split('=', 1) for line in text.splitlines() if '=' in line)
    if fields.get('LoadState') not in ('loaded', 'not-found') or not fields.get('ActiveState'):
        raise ValueError('cpu_service_unknown')
    return dict(exists=fields['LoadState'] == 'loaded', active=fields['ActiveState'],
                pid=int(fields.get('MainPID', '0')), enabled=fields.get('UnitFileState', ''))


def status():
    observed = service()
    state, healthy, stale = None, False, True
    try:
        state = json.loads((ROOT / 'state.json').read_text())
        config = json.loads((INSTALL / 'config.json').read_text())
        heartbeat = dt.datetime.fromisoformat(state['heartbeatUtc']).timestamp()
        age = time.time() - heartbeat
        stale = not 0 <= age <= STALE_SECONDS
        healthy = (observed['active'] == 'active' and observed['pid'] > 0 and not stale and
                   observed['pid'] == state['pid'] and state['status'] == 'running' and
                   state['runId'] == config['runId'] and time.time() < config['expiresEpoch'] and
                   state['bootId'] == Path('/proc/sys/kernel/random/boot_id').read_text().strip() and
                   state['processStart'] == process_identity(observed['pid']))
    except (OSError, ValueError, KeyError, TypeError):
        pass
    return dict(service=observed, healthy=healthy, stale=stale, state=state)


def stop_worker():
    observed = service()
    if observed['exists']:
        # Normal workers are transient; disable any unexpectedly inherited persistent unit too.
        if observed['enabled'] not in ('transient', '', 'disabled', 'masked', 'static'):
            command('systemctl', 'disable', UNIT)
        command('systemctl', 'stop', UNIT)
        after = service()
        if after['active'] not in ('inactive', 'failed') or after['pid']:
            raise ValueError('cpu_stop_unverified')
    if (ROOT / 'state.json').exists():
        try:
            state = json.loads((ROOT / 'state.json').read_text())
        except (ValueError, OSError):
            state = {}
        state.update(status='stopped', targetWorkerCpuPercent=0.0, heartbeatUtc=utc())
        atomic_json(ROOT / 'state.json', state)


def control(action, duration_hours=24, renew=False):
    if action == 'Status':
        return status()
    lock = CONTROL_LOCK.open('a')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    try:
        if action == 'Stop':
            stop_worker()
            return status()
        if not 1 <= duration_hours <= 168:
            raise ValueError('invalid_duration')
        observed = status()
        if not renew:
            if observed['service']['active'] in ('active', 'activating', 'deactivating') or observed['service']['pid']:
                if not observed['healthy']:
                    raise ValueError('existing_cpu_run_unresolved_use_status_stop_or_renew')
                return observed
            # Starting again after reboot/expiry must not silently extend a recorded run.
            if (INSTALL / 'config.json').exists():
                raise ValueError('existing_cpu_deadline_use_explicit_renew')
        stop_worker()
        ROOT.mkdir(parents=True, exist_ok=True)
        INSTALL.mkdir(parents=True, exist_ok=True)
        seconds = duration_hours * 60 * 60
        config = dict(runId=uuid.uuid4().hex, durationSeconds=seconds, expiresEpoch=time.time() + seconds)
        atomic_json(INSTALL / 'config.json', config)
        (INSTALL / 'config.json').chmod(0o644)
        command('systemd-run', '--quiet', '--collect', '--unit=' + UNIT,
                '--property=Type=exec', '--property=DynamicUser=yes', '--property=StateDirectory=lab-cpu-simulation',
                '--property=Nice=19', '--property=CPUQuota={}%'.format(int(MAX_CORE_DUTY * 100)),
                '--property=CPUQuotaPeriodSec=100ms', '--property=MemoryMax=64M',
                '--property=NoNewPrivileges=yes', '--property=ProtectSystem=strict', '--property=ProtectHome=yes',
                '--property=PrivateDevices=yes', '--property=RestrictAddressFamilies=AF_UNIX',
                '--property=RuntimeMaxSec={}'.format(seconds), '--property=Restart=no',
                '/usr/bin/python3', str(INSTALL / 'linux-cpu.py'), '--worker')
        until = time.monotonic() + 15
        while time.monotonic() < until:
            observed = status()
            if observed['healthy']:
                return observed
            time.sleep(0.25)
        raise ValueError('cpu_start_unverified')
    finally:
        lock.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--worker', action='store_true')
    parser.add_argument('--mode', choices=('Start', 'Status', 'Stop'), default='Status')
    parser.add_argument('--duration-hours', type=int, default=24)
    parser.add_argument('--renew', action='store_true')
    args = parser.parse_args()
    if args.worker:
        config = json.loads((INSTALL / 'config.json').read_text())
        if (not isinstance(config.get('durationSeconds'), int) or not 3600 <= config['durationSeconds'] <= 168 * 3600 or
                not isinstance(config.get('expiresEpoch'), (int, float)) or not math.isfinite(config['expiresEpoch']) or
                not isinstance(config.get('runId'), str) or len(config['runId']) != 32):
            raise ValueError('invalid_worker_config')
        raise SystemExit(worker(config))
    print('LAB_CPU_JSON ' + json.dumps(control(args.mode, args.duration_hours, args.renew), allow_nan=False, separators=(',', ':')))
    print('LAB_CPU_CONFIRMED')


if __name__ == '__main__':
    main()
