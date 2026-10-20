#!/usr/bin/env python3
"""Offline CPU logic, mocked guest control and bounded low-duty worker checks. No services/cloud."""
import ast
import base64
import datetime as dt
import gzip
import importlib.util
import json
import math
from pathlib import Path
import re
import shutil
import sys
import time
import unittest
import uuid
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / 'scripts/cpu-simulation'
WORK_ROOT = ROOT / 'tests/.static-work'
EVIDENCE = WORK_ROOT / ('cpu-checks-' + uuid.uuid4().hex)
MADE_WORK_ROOT = False
SPEC = importlib.util.spec_from_file_location('lab_cpu', ASSETS / 'linux-cpu.py')
cpu = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cpu)
DAY = dt.datetime(2026, 10, 16, 12, tzinfo=dt.timezone.utc).timestamp()


def setUpModule():
    global MADE_WORK_ROOT
    try:
        WORK_ROOT.mkdir()
        MADE_WORK_ROOT = True
    except FileExistsError:
        pass
    EVIDENCE.mkdir(exist_ok=False)


def tearDownModule():
    shutil.rmtree(EVIDENCE)
    if MADE_WORK_ROOT:
        try:
            WORK_ROOT.rmdir()
        except OSError:
            pass


class CpuChecks(unittest.TestCase):
    def test_numeric_budget_and_schedule_boundaries(self):
        self.assertEqual((cpu.DAY_HOURS, cpu.NIGHT_HOURS), (16, 8))
        self.assertEqual(cpu.MAX_CORE_DUTY, 0.30)
        self.assertEqual(cpu.MAX_CORE_DUTY * 100 / 2, 15)
        for hour, phase, target in ((5, 'night', 2), (6, 'day', 15), (21, 'day', 15), (22, 'night', 2), (0, 'night', 2)):
            epoch = dt.datetime(2026, 10, 16, hour, tzinfo=dt.timezone.utc).timestamp()
            self.assertEqual(cpu.phase_target(epoch), (phase, target))

    def test_proc_stat_guest_is_not_counted_twice(self):
        before = cpu.cpu_snapshot('cpu 100 0 100 800 0 0 0 0 90 0\n')
        after = cpu.cpu_snapshot('cpu 110 0 110 880 0 0 0 0 100 0\n')
        self.assertEqual(before[:2], (1000, 800))
        self.assertEqual(cpu.total_percent(before, after), 20)
        self.assertEqual(cpu.cpu_snapshot('cpu 110 0 110 880 0 0 0 0 9999 0\n'), after)
        for text in ('no cpu', 'cpu 1 2', 'cpu -1 0 0 1 0 0 0 0'):
            with self.assertRaises(ValueError):
                cpu.cpu_snapshot(text)

    def test_counter_rollback_or_invalid_delta_never_authorizes_work(self):
        before = cpu.cpu_snapshot('cpu 10 0 10 80 0 0 0 0')
        for text in ('cpu 10 0 10 80 0 0 0 0', 'cpu 9 0 30 100 0 0 0 0', 'cpu 10 0 10 79 0 0 0 0'):
            with self.assertRaises(ValueError):
                cpu.total_percent(before, cpu.cpu_snapshot(text))

    def test_feedback_subtracts_worker_and_baseline_above_goal(self):
        report, _, _ = cpu.decision(14, 9, 2, 0, epoch=DAY)
        self.assertEqual(report['baselineCpuPercent'], 5)
        self.assertEqual(report['targetWorkerCpuPercent'], 10)
        self.assertEqual(cpu.decision(0, 0, 2, 0, epoch=DAY)[0]['targetWorkerCpuPercent'], 15)
        for baseline in (15, 17, 29):
            report, _, _ = cpu.decision(baseline, 0, 2, 0, epoch=DAY)
            self.assertTrue(report['baselineAboveGoal'])
            self.assertEqual(report['targetWorkerCpuPercent'], 0)
        night = DAY + 10 * 3600
        self.assertEqual(cpu.decision(0, 0, 2, 0, epoch=night)[0]['targetWorkerCpuPercent'], 2)

    def test_high_cpu_hysteresis_and_continuous_cooldown(self):
        report, guard, until = cpu.decision(30, 0, 2, 0, epoch=DAY)
        self.assertTrue(guard)
        self.assertEqual(until, 60)
        self.assertEqual(report['targetWorkerCpuPercent'], 0)
        report, guard, until = cpu.decision(20, 0, 2, 59, guard, until, DAY)
        self.assertEqual(until, 119)
        report, guard, until = cpu.decision(10, 0, 2, 118, guard, until, DAY)
        self.assertTrue(guard)
        report, guard, until = cpu.decision(10, 0, 2, 119, guard, until, DAY)
        self.assertFalse(guard)
        self.assertEqual(report['targetWorkerCpuPercent'], 5)

    def test_unavailable_nan_out_of_range_and_cpu_count_fail_closed(self):
        for total, worker, cpus in ((None, 0, 2), (math.nan, 0, 2), (math.inf, 0, 2), (-1, 0, 2),
                                    (101, 0, 2), (15, -1, 2), (10, 51, 2), (0, 0, 0), (0, 0, 4)):
            report, guard, until = cpu.decision(total, worker, cpus, 1, True, 60, DAY)
            self.assertEqual(report['targetWorkerCpuPercent'], 0)
            self.assertEqual(report['reason'], 'measurement_invalid')
            self.assertIsNone(report['measuredTotalCpuPercent'])
            self.assertTrue(guard)
            self.assertEqual(until, 60)
            json.dumps(report, allow_nan=False)

    def test_utc_and_monotonic_expiry_independently_bound_worker(self):
        config = dict(expiresEpoch=200, durationSeconds=100)
        self.assertTrue(cpu.expired(config, 5, 105, 0))
        self.assertTrue(cpu.expired(config, 5, 6, 200))
        self.assertFalse(cpu.expired(config, 5, 104, 199))

    def test_service_not_found_and_unknown_are_distinct(self):
        class Result:
            returncode = 4
            stdout = 'LoadState=not-found\nActiveState=inactive\nMainPID=0\nUnitFileState=\n'
        with patch.object(cpu.subprocess, 'run', return_value=Result()):
            self.assertFalse(cpu.service()['exists'])
        Result.stdout = ''
        with patch.object(cpu.subprocess, 'run', return_value=Result()):
            with self.assertRaises(ValueError):
                cpu.service()

    def test_start_idempotence_expired_record_requires_renew_and_runtime_bound(self):
        runtime = EVIDENCE / ('control-fixture-' + uuid.uuid4().hex)
        runtime.mkdir(parents=True, exist_ok=False)
        install = runtime / 'install'
        install.mkdir()
        config_path = install / 'config.json'
        old = {'runId': 'a'*32, 'expiresEpoch': 12345, 'durationSeconds': 86400}
        config_path.write_text(json.dumps(old))
        active = dict(healthy=True, service=dict(active='active', pid=123))
        absent = dict(healthy=False, service=dict(active='inactive', pid=0))
        try:
            with patch.object(cpu, 'INSTALL', install), patch.object(cpu, 'ROOT', runtime), patch.object(cpu, 'CONTROL_LOCK', runtime/'control.lock'):
                with patch.object(cpu, 'status', return_value=active), patch.object(cpu, 'command') as run:
                    self.assertEqual(cpu.control('Start'), active)
                    run.assert_not_called()
                    self.assertEqual(json.loads(config_path.read_text()), old)
                with patch.object(cpu, 'status', return_value=absent), patch.object(cpu, 'command') as run:
                    with self.assertRaisesRegex(ValueError, 'explicit_renew'):
                        cpu.control('Start')
                    run.assert_not_called()
                with patch.object(cpu, 'status', side_effect=[absent, active]), patch.object(cpu, 'stop_worker') as stop, patch.object(cpu, 'command') as run:
                    self.assertEqual(cpu.control('Start', 168, True), active)
                    stop.assert_called_once()
                    args = run.call_args.args
                    self.assertIn('--property=RuntimeMaxSec=604800', args)
                    self.assertIn('--property=CPUQuota=30%', args)
                    self.assertNotEqual(json.loads(config_path.read_text())['runId'], old['runId'])
        finally:
            shutil.rmtree(runtime)

    def test_status_needs_actual_running_identity_and_heartbeat(self):
        runtime = EVIDENCE / ('status-fixture-' + uuid.uuid4().hex)
        runtime.mkdir(parents=True, exist_ok=False)
        try:
            state = dict(runId='a'*32, pid=123, status='running', heartbeatUtc=cpu.utc(), processStart='456',
                         bootId=Path('/proc/sys/kernel/random/boot_id').read_text().strip())
            (runtime/'config.json').write_text(json.dumps(dict(runId='a'*32, expiresEpoch=time.time()+60)))
            def write():
                (runtime/'state.json').write_text(json.dumps(state))
            write()
            with patch.object(cpu, 'ROOT', runtime), patch.object(cpu, 'INSTALL', runtime), patch.object(cpu, 'process_identity', return_value='456'):
                with patch.object(cpu, 'service', return_value=dict(active='active', pid=123)):
                    self.assertTrue(cpu.status()['healthy'])
                    state['heartbeatUtc'] = cpu.utc(time.time()-11)
                    write()
                    self.assertFalse(cpu.status()['healthy'])
                    self.assertTrue(cpu.status()['stale'])
                    state['heartbeatUtc'] = cpu.utc()
                    state['runId'] = 'b'*32
                    write()
                    self.assertFalse(cpu.status()['healthy'])
                state['runId'] = 'a'*32
                write()
                with patch.object(cpu, 'service', return_value=dict(active='inactive', pid=0)):
                    self.assertFalse(cpu.status()['healthy'])
        finally:
            shutil.rmtree(runtime)

    def test_stop_verification_never_reports_running_worker_as_stopped(self):
        active = dict(exists=True, active='active', pid=123, enabled='transient')
        with patch.object(cpu, 'service', side_effect=[active, active]), patch.object(cpu, 'command'):
            with self.assertRaisesRegex(ValueError, 'stop_unverified'):
                cpu.stop_worker()
        windows = (ASSETS/'windows-cpu.ps1').read_text()
        stop = windows.split('function Stop-CpuWorker {', 1)[1].split('function Invoke-CpuWorker', 1)[0]
        self.assertNotIn('SilentlyContinue', stop)
        self.assertIn("Get-ScheduledTask -ErrorAction Stop", stop)
        self.assertLess(stop.index('CPU process exit/disarm unverified'), stop.index("$state.status='stopped'"))
        self.assertIn("$processes.Count -gt 0", stop)

    def test_no_hidden_autostart_or_application_actions(self):
        linux = (ASSETS / 'linux-cpu.py').read_text()
        windows = (ASSETS / 'windows-cpu.ps1').read_text()
        self.assertIn("'--property=RuntimeMaxSec={}'.format(seconds)", linux)
        self.assertIn("'--property=CPUQuota={}%'.format", linux)
        self.assertIn("'--property=CPUQuotaPeriodSec=100ms'", linux)
        self.assertIn('-ExecutionTimeLimit (New-TimeSpan -Seconds $seconds)', windows)
        self.assertNotIn('New-ScheduledTaskTrigger', windows)
        self.assertNotIn("command('systemctl', 'enable'", linux)
        self.assertNotIn('Restart-Service', windows)
        self.assertNotRegex(linux + windows, r'(?i)https?://|SqlConnection|stress-ng|dd if=')
        self.assertIn("if (Test-Path (Join-Path $root 'config.json'))", windows)
        self.assertIn("if (INSTALL / 'config.json').exists()", linux)

    def test_prompts_independent_decisions_and_remote_carry(self):
        source = (ROOT / 'scripts/migrate-step1-setup-project.ps1').read_text(encoding='utf-8-sig')
        offer = source.split('function Invoke-LabTrafficOffer {', 1)[1].split('# Target networking configuration', 1)[0]
        self.assertLess(offer.index('Would you like to initiate lab traffic'), offer.index('Would you like to turn on optional CPU Simulation'))
        self.assertLess(offer.index('No additional VM'), offer.index('Would you like to turn on optional CPU Simulation'))
        self.assertIn('extending uptime for capture continues normal lab charges', offer)
        self.assertIn('Earlier data can be partial', offer)
        self.assertIn("if (-not $networkStart -and $cpuChoice -eq 'Skip') { return }", offer)
        self.assertIn('-StartNetwork $networkStart -CpuChoice $cpuChoice', offer)
        self.assertIn("elseif ($script:LabStep1Interactive)", offer)
        self.assertIn("-Component '__COMPONENT__' -CpuSimulation $cpuChoice -CpuDurationHours __CPU_HOURS__", source)
        host = (ROOT / 'scripts/enable-lab-traffic.ps1').read_text(encoding='utf-8-sig')
        self.assertIn("if ($NonInteractive -and $CpuSimulation -eq 'Prompt') { $CpuSimulation = 'Skip' }", host)
        execution = host.split('# ---------- Execution ----------', 1)[1]
        prompt = execution.index('Would you like to initiate lab traffic')
        self.assertLess(prompt, execution.index("Write-Step 'Adding hosts entries"))
        self.assertIn("if (-not $NonInteractive -and -not $PSBoundParameters.ContainsKey('Mode') -and", execution)
        self.assertIn("-not $PSBoundParameters.ContainsKey('Component'))", execution)
        declined = execution.split("if ($answer -notmatch '^(?i:y|yes)$')", 1)[1].split("Write-Step 'Adding hosts", 1)[0]
        self.assertIn('Invoke-RequestedCpuStart', declined)
        self.assertIn('return', declined)
        self.assertIn("if ($Mode -ne 'Start' -and -not $PSBoundParameters.ContainsKey('Component')) { $Component = 'Both' }", host)
        self.assertLess(host.index("Write-Output 'LAB_TRAFFIC_FULLY_STARTED'", host.index('# ---------- Execution')), host.index('    Invoke-RequestedCpuStart\n} catch'))

    def test_payload_composition_preserves_exact_assets_and_stages_only(self):
        host = (ROOT / 'scripts/host/configure-host.ps1').read_text(encoding='utf-8-sig')
        deploy = (ROOT / 'scripts/deploy-lab.ps1').read_text(encoding='utf-8-sig')
        self.assertEqual(host.count('__LAB_CPU_ASSETS_PAYLOAD__'), 1)
        self.assertIn("Join-Path $scriptsRoot ('cpu-simulation/' + $name)", deploy)
        self.assertLess(deploy.index('$cpuAssets = [ordered]@{}'), deploy.index('$hostScript = Read-LabHostConfiguration'))
        assets = {name: (ASSETS / name).read_text() for name in ('control.ps1', 'windows-cpu.ps1', 'linux-cpu.py')}
        encoded = base64.b64encode(gzip.compress(json.dumps(assets).encode())).decode()
        decoded = json.loads(gzip.decompress(base64.b64decode(encoded)))
        self.assertEqual(decoded, assets)
        stage = host.split("$cpuAssetPayload = '__LAB_CPU_ASSETS_PAYLOAD__'", 1)[1].split('# Deployment knows', 1)[0]
        self.assertIn("Join-Path $labRoot 'cpu-simulation'", stage)
        self.assertNotIn('Invoke-LabCpuSimulation', stage)
        self.assertNotIn('Start-ScheduledTask', stage)

    def test_postmigration_payload_is_self_contained_and_disarms_all_roles(self):
        source = (ROOT / 'scripts/post-migration-labtraffic.ps1').read_text(encoding='utf-8-sig')
        self.assertIn("foreach ($target in $Targets) { $null=Invoke-GuestAction $target 'Pause' }", source)
        self.assertIn('function Stop-LabGenerators {\n    Stop-InheritedCpu', source)
        self.assertIn('def pause_generators():\n    stop_inherited_cpu()', source)
        self.assertIn('cpu=(Get-InheritedCpuObservation)', source)
        self.assertIn('cpu=cpu_observation()', source)
        self.assertIn('Unregister-ScheduledTask -Confirm:$false', source)
        self.assertNotIn('Get-Content (Join-Path $cpuAssetsPath', source)
        self.assertIn('[ValidateRange(1,120)][int]$DurationMinutes = 60', source)
        body = re.search(r"\$LinuxPythonBody = @'\n(.*?)\n'@", source, re.S).group(1)
        ast.parse(body)
        namespace = {'__name__': 'offline_fixture'}
        exec(compile(body, '<postmigration>', 'exec'), namespace)
        namespace['self_test']()

    def test_bounded_real_worker_at_low_duty_without_services(self):
        runtime = EVIDENCE / ('bounded-worker-run-' + uuid.uuid4().hex)
        runtime.mkdir(parents=True, exist_ok=False)
        try:
            config = dict(runId='a'*32, expiresEpoch=time.time()+4.3, durationSeconds=4.3)
            before_cpu, before_wall = time.process_time(), time.monotonic()
            with patch.object(cpu, 'ROOT', runtime), patch.object(cpu.os, 'cpu_count', return_value=2), \
                 patch.object(cpu, 'DAY_TARGET', .1), patch.object(cpu, 'NIGHT_TARGET', .1), patch.object(cpu, 'MAX_CORE_DUTY', .002):
                self.assertEqual(cpu.worker(config), 0)
            elapsed_cpu, elapsed_wall = time.process_time()-before_cpu, time.monotonic()-before_wall
            state = json.loads((runtime / 'state.json').read_text())
            self.assertEqual(state['status'], 'expired')
            self.assertEqual(state['targetWorkerCpuPercent'], 0)
            self.assertLess(elapsed_wall, 6)
            self.assertLess(elapsed_cpu, .25)
            self.assertLess((runtime / 'state.json').stat().st_size, 4096)
            atomic = dict(elapsedWallSeconds=round(elapsed_wall, 3), processCpuSeconds=round(elapsed_cpu, 4),
                          simulatedTargetTotalCpuPercent=.1, finalState=state, servicesInstalled=False)
            (EVIDENCE / 'bounded-worker-result.json').write_text(json.dumps(atomic, indent=2)+'\n')
            print('Bounded Linux worker evidence: ' + json.dumps(atomic, sort_keys=True))
        finally:
            shutil.rmtree(runtime)


if __name__ == '__main__':
    unittest.main(verbosity=2)
