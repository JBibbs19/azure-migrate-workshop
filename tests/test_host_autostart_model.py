#!/usr/bin/env python3
"""Independent offline policy/rollback reference model; NOT PowerShell execution.

This tests the intended transaction contract with Python objects and injected faults.
It does not parse/execute the production helper, emulate Hyper-V, or prove native boot.
Run separately from source assertions: python3 tests/test_host_autostart_model.py
"""
from copy import deepcopy
from dataclasses import dataclass
import unittest

POLICIES = {'OnPrem-SQL': 30, 'OnPrem-Linux-App': 60,
            'OnPrem-Linux-Web': 90, 'OnPrem-Web': 120}


@dataclass
class MockVm:
    name: str
    identity: str
    state: str = 'Running'
    action: str = 'Nothing'
    delay: int = 0
    stop_action: str = 'Save'


class IndependentPolicyModel:
    """Reference state machine, deliberately independent of PowerShell source."""

    def __init__(self):
        self.vms = [MockVm(name, 'mock-id-' + name, delay=i + 3)
                    for i, name in enumerate(POLICIES)]
        self.vms[0].action = 'StartIfRunning'
        self.vms.append(MockVm('Unrelated-Appliance', 'mock-appliance-id', 'Off',
                               stop_action='ShutDown'))
        self.guest_ready = self.workloads_ready = True
        self.faults = {}
        self.events = []
        self.attempted = []
        self.writes = []
        self.complete = False
        self.failure = ''
        self.rollback_incomplete = []

    def _by_id(self, identity):
        found = [vm for vm in self.vms if vm.identity == identity]
        if len(found) != 1:
            raise RuntimeError('Missing or ambiguous saved identity')
        return found[0]

    def _write(self, prior, action, delay, phase):
        self.events.append((phase + '-write', prior.name))
        self.writes.append((phase, prior.name, prior.identity, action, delay))
        vm = self._by_id(prior.identity)
        if self.faults.get(phase + '-write-before') == prior.name:
            raise RuntimeError('Injected write failure before mutation')
        vm.action, vm.delay = action, delay
        if self.faults.get(phase + '-write-after') == prior.name:
            raise RuntimeError('Injected write failure after mutation')

    def _verify(self, prior, action, delay, phase):
        self.events.append((phase + '-read', prior.name))
        vm = self._by_id(prior.identity)
        if self.faults.get(phase + '-read-unverified') == prior.name:
            raise RuntimeError('Injected unverified readback')
        observed_delay = vm.delay
        if self.faults.get(phase + '-read-mismatch') == prior.name:
            observed_delay += 1
        if vm.name != prior.name or vm.action != action or observed_delay != delay:
            raise RuntimeError('Policy/identity readback mismatch')
        if phase == 'arm' and vm.state != 'Running':
            raise RuntimeError('VM stopped during policy configuration')

    def run_final_completion(self):
        self.events.append(('readiness', 'guest'))
        if not self.guest_ready:
            self.failure = 'Guest readiness failed'
            return
        self.events.append(('readiness', 'workloads'))
        if not self.workloads_ready:
            self.failure = 'Workload readiness failed'
            return
        snapshots = []
        for name in POLICIES:
            self.events.append(('preflight', name))
            found = [vm for vm in self.vms if vm.name == name]
            if (len(found) != 1 or found[0].state != 'Running'
                    or not found[0].identity
                    or found[0].identity in {old.identity for old in snapshots}):
                self.failure = 'Preflight rejected missing/ambiguous/non-Running/invalid identity'
                return
            snapshots.append(deepcopy(found[0]))
        try:
            for prior in snapshots:
                if (prior.action, prior.delay) != ('Start', POLICIES[prior.name]):
                    self.attempted.append(prior)
                    self._write(prior, 'Start', POLICIES[prior.name], 'arm')
            for prior in snapshots:
                self._verify(prior, 'Start', POLICIES[prior.name], 'arm')
        except RuntimeError as error:
            self.failure = str(error)
            for prior in reversed(self.attempted):
                try:
                    self._write(prior, prior.action, prior.delay, 'rollback')
                    self._verify(prior, prior.action, prior.delay, 'rollback')
                except RuntimeError:
                    self.rollback_incomplete.append(prior.name)
            return
        self.complete = True
        self.events.append(('completion', 'written'))


class IndependentPolicyModelChecks(unittest.TestCase):
    def setUp(self):
        self.model = IndependentPolicyModel()
        self.original = deepcopy(self.model.vms)

    def assert_original_policies(self):
        self.assertEqual([(vm.name, vm.identity, vm.action, vm.delay, vm.stop_action)
                          for vm in self.model.vms],
                         [(vm.name, vm.identity, vm.action, vm.delay, vm.stop_action)
                          for vm in self.original])

    def test_01_guest_readiness_failure_never_preflights_arms_or_completes(self):
        self.model.guest_ready = False
        self.model.run_final_completion()
        self.assertEqual(self.model.events, [('readiness', 'guest')])
        self.assertEqual(self.model.writes, [])
        self.assertFalse(self.model.complete)
        self.assert_original_policies()

    def test_02_workload_readiness_failure_never_arms_or_completes(self):
        self.model.workloads_ready = False
        self.model.run_final_completion()
        self.assertEqual(self.model.events, [('readiness', 'guest'), ('readiness', 'workloads')])
        self.assertEqual(self.model.writes, [])
        self.assertFalse(self.model.complete)
        self.assert_original_policies()

    def test_03_missing_ambiguous_or_saved_fourth_vm_preflights_all_before_any_write(self):
        for fault in ('missing', 'ambiguous', 'Saved'):
            with self.subTest(fault=fault):
                model = IndependentPolicyModel()
                fourth = model.vms[3]
                if fault == 'missing':
                    model.vms.remove(fourth)
                elif fault == 'ambiguous':
                    model.vms.append(deepcopy(fourth))
                else:
                    fourth.state = 'Saved'
                before = deepcopy(model.vms)
                model.run_final_completion()
                self.assertEqual(len([e for e in model.events if e[0] == 'preflight']), 4)
                self.assertEqual(model.writes, [])
                self.assertFalse(model.complete)
                self.assertEqual(model.vms, before)

    def test_04_duplicate_identity_fails_before_mutation(self):
        self.model.vms[3].identity = self.model.vms[0].identity
        before = deepcopy(self.model.vms)
        self.model.run_final_completion()
        self.assertFalse(self.model.complete)
        self.assertEqual(self.model.writes, [])
        self.assertEqual(self.model.vms, before)

    def test_05_mutate_then_throw_restores_failed_attempt_and_earlier_attempt(self):
        self.model.faults['arm-write-after'] = 'OnPrem-Linux-App'
        self.model.run_final_completion()
        self.assertEqual([prior.name for prior in self.model.attempted],
                         ['OnPrem-SQL', 'OnPrem-Linux-App'])
        self.assertEqual([(phase, name) for phase, name, *_ in self.model.writes],
                         [('arm', 'OnPrem-SQL'), ('arm', 'OnPrem-Linux-App'),
                          ('rollback', 'OnPrem-Linux-App'), ('rollback', 'OnPrem-SQL')])
        self.assertFalse(self.model.complete)
        self.assertEqual(self.model.rollback_incomplete, [])
        self.assert_original_policies()

    def test_06_throw_before_mutation_still_restores_every_attempted_write(self):
        self.model.faults['arm-write-before'] = 'OnPrem-Linux-App'
        self.model.run_final_completion()
        self.assertEqual(len(self.model.attempted), 2)
        self.assertEqual(len(self.model.writes), 4)
        self.assertFalse(self.model.complete)
        self.assert_original_policies()

    def test_07_readback_mismatch_restores_all_four_and_blocks_completion(self):
        self.model.faults['arm-read-mismatch'] = 'OnPrem-Linux-Web'
        self.model.run_final_completion()
        self.assertEqual(len(self.model.attempted), 4)
        self.assertEqual(len(self.model.writes), 8)
        self.assertFalse(self.model.complete)
        self.assertEqual(self.model.rollback_incomplete, [])
        self.assert_original_policies()

    def test_08_rollback_write_failure_is_incomplete_and_never_completes(self):
        self.model.faults = {'arm-write-after': 'OnPrem-Linux-App',
                             'rollback-write-before': 'OnPrem-SQL'}
        self.model.run_final_completion()
        self.assertFalse(self.model.complete)
        self.assertEqual(self.model.rollback_incomplete, ['OnPrem-SQL'])
        self.assertEqual(self.model.vms[0].action, 'Start')
        self.assertEqual(self.model.vms[1].action, self.original[1].action)

    def test_09_rollback_readback_unverified_cannot_claim_success_even_if_restored(self):
        self.model.faults = {'arm-write-after': 'OnPrem-Linux-App',
                             'rollback-read-unverified': 'OnPrem-SQL'}
        self.model.run_final_completion()
        self.assertFalse(self.model.complete)
        self.assertEqual(self.model.rollback_incomplete, ['OnPrem-SQL'])
        self.assert_original_policies()

    def test_10_idempotent_policies_skip_writes_but_verify_all_four(self):
        for vm in self.model.vms:
            if vm.name in POLICIES:
                vm.action, vm.delay = 'Start', POLICIES[vm.name]
        self.model.run_final_completion()
        self.assertTrue(self.model.complete)
        self.assertEqual(self.model.writes, [])
        self.assertEqual([name for phase, name in self.model.events if phase == 'arm-read'],
                         list(POLICIES))

    def test_11_preexisting_correct_policy_is_not_rewritten_during_rollback(self):
        vm = self.model.vms[0]
        vm.action, vm.delay = 'Start', POLICIES[vm.name]
        self.model.faults['arm-read-mismatch'] = 'OnPrem-Web'
        self.model.run_final_completion()
        self.assertFalse(self.model.complete)
        self.assertEqual(len(self.model.writes), 6)
        self.assertNotIn('OnPrem-SQL', [write[1] for write in self.model.writes])
        self.assertEqual((vm.action, vm.delay), ('Start', 30))

    def test_12_success_has_all_four_post_write_verifications_and_no_other_changes(self):
        self.model.run_final_completion()
        self.assertTrue(self.model.complete)
        self.assertEqual(self.model.events[:2], [('readiness', 'guest'), ('readiness', 'workloads')])
        phases = [phase for phase, _ in self.model.events]
        self.assertEqual(phases[2:6], ['preflight'] * 4)
        self.assertEqual(phases[6:10], ['arm-write'] * 4)
        self.assertEqual(phases[10:14], ['arm-read'] * 4)
        self.assertEqual(phases[14:], ['completion'])
        for vm in self.model.vms[:4]:
            self.assertEqual((vm.action, vm.delay), ('Start', POLICIES[vm.name]))
            self.assertEqual((vm.state, vm.stop_action), ('Running', 'Save'))
        self.assertEqual(self.model.vms[4], self.original[4])


if __name__ == '__main__':
    unittest.main(verbosity=2)
