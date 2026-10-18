#!/usr/bin/env python3
"""Real filesystem alias checks. Run from a native filesystem, not an artifact FUSE mount.

Example: cd <owned-native-project> && python3 <checkout>/tests/test_tomcat_home_conf.py
Fixtures are uniquely owned children of cwd and are always removed. No Tomcat/services run.
Only root chown is intercepted for non-root tests; links, modes, inodes and reads are real.
"""
import ast
import contextlib
import hashlib
import importlib.util
import io
import os
from pathlib import Path
import pwd
import shutil
import stat
import subprocess
import sys
import unittest
from unittest import mock
import uuid
import zipfile

sys.dont_write_bytecode = True
APP = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('home_conf_configure', APP / 'scripts/configure.py')
configure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(configure)


class HomeConfFilesystemChecks(unittest.TestCase):
    def setUp(self):
        self.root = Path.cwd() / ('.tomcat-home-conf-fixture-' + uuid.uuid4().hex)
        self.root.mkdir(mode=0o755)
        self.addCleanup(shutil.rmtree, self.root)
        self.base = self.root / 'var/lib/contoso-orderdesk'
        self.home = self.root / 'usr/share/tomcat10'
        self.base.joinpath('conf/Catalina/localhost').mkdir(parents=True)
        self.home.mkdir(parents=True)
        self.source = self.base / 'conf/server.xml'
        self.source.write_bytes(b'<Server port="-1"><Service name="Catalina"/></Server>\n')
        self.source.chmod(0o644)
        self.private = self.base / 'conf/Catalina/localhost/ROOT.xml'
        self.private.write_bytes(b'<Context><!-- private test fixture --></Context>\n')
        self.private.chmod(0o640)
        self.stock = self.root / 'etc/tomcat10/server.xml'
        self.stock.parent.mkdir(parents=True)
        self.stock.write_bytes(b'untouched stock fixture\n')
        self.conf = self.home / 'conf'
        self.alias = self.conf / 'server.xml'
        self.addCleanup(mock.patch.stopall)
        mock.patch.object(configure, 'BASE', self.base).start()
        mock.patch.object(configure, 'GROUP', pwd.getpwuid(os.geteuid()).pw_name).start()
        if os.geteuid() != 0:
            self.chown = mock.patch.object(configure.os, 'chown').start()
        else:
            self.chown = None

    def invoke(self):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            configure.tomcat_home_conf(self.home)
        return output.getvalue()

    def snapshot(self):
        rows = {}
        for path in sorted(self.root.rglob('*')):
            metadata = path.lstat()
            content = os.readlink(path) if path.is_symlink() else (
                path.read_bytes() if os.access(path, os.R_OK, effective_ids=True) else '<unreadable>'
            ) if path.is_file() else None
            rows[path.relative_to(self.root).as_posix()] = (
                metadata.st_mode, metadata.st_uid, metadata.st_gid, metadata.st_ino, content)
        return rows

    def refuse_without_changes(self):
        before = self.snapshot()
        with self.assertRaises((RuntimeError, OSError)):
            self.invoke()
        self.assertEqual(self.snapshot(), before)
        if self.chown is not None:
            self.chown.assert_not_called()

    def assert_alias(self):
        self.assertTrue(self.alias.is_symlink())
        self.assertEqual(os.readlink(self.alias), str(self.source))
        self.assertEqual(self.alias.resolve(strict=True), self.source)
        self.assertTrue(os.path.samestat(self.alias.stat(), self.source.stat()))
        self.assertEqual((self.alias.stat().st_dev, self.alias.stat().st_ino),
                         (self.source.stat().st_dev, self.source.stat().st_ino))
        self.assertTrue(os.access(self.alias, os.R_OK, effective_ids=True))
        self.assertEqual(self.alias.read_bytes(), self.source.read_bytes())
        result = subprocess.run(['/usr/bin/test', '-r', str(self.alias)], check=False)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(stat.S_IMODE(self.private.stat().st_mode), 0o640)
        self.assertEqual(self.stock.read_bytes(), b'untouched stock fixture\n')
        self.assertEqual({p.name for p in self.conf.iterdir()}, {'server.xml'})

    def test_missing_conf_creates_single_alias_and_0755_directory(self):
        before = self.source.read_bytes()
        self.assertIn('discovery remains pending', self.invoke())
        self.assertEqual(stat.S_IMODE(self.conf.stat().st_mode), 0o755)
        if self.chown is not None:
            self.chown.assert_called_once_with(self.conf, 0, 0)
        else:
            self.assertEqual((self.conf.stat().st_uid, self.conf.stat().st_gid), (0, 0))
        self.assertEqual(self.source.read_bytes(), before)
        self.assert_alias()

    def test_existing_real_conf_preserves_unrelated_file_owner_and_mode(self):
        self.conf.mkdir(mode=0o711)
        unrelated = self.conf / 'unrelated.txt'
        unrelated.write_bytes(b'unchanged\n')
        unrelated.chmod(0o600)
        before = self.snapshot()
        self.invoke()
        after = self.snapshot()
        self.assertTrue(stat.S_ISLNK(after.pop('usr/share/tomcat10/conf/server.xml')[0]))
        self.assertEqual(before, after)
        if self.chown is not None:
            self.chown.assert_not_called()

    def test_exact_existing_alias_is_idempotent_without_metadata_changes(self):
        self.conf.mkdir()
        self.alias.symlink_to(self.source)
        before = self.snapshot()
        self.invoke()
        self.invoke()
        self.assertEqual(self.snapshot(), before)
        self.assert_alias()
        if self.chown is not None:
            self.chown.assert_not_called()

    def test_existing_regular_file_is_never_overwritten(self):
        self.conf.mkdir()
        self.alias.write_bytes(b'preserve occupied XML\n')
        self.refuse_without_changes()

    def test_existing_wrong_symlink_is_never_overwritten(self):
        self.conf.mkdir()
        self.alias.symlink_to(self.stock)
        self.refuse_without_changes()

    def test_existing_relative_link_to_same_source_is_not_exact(self):
        self.conf.mkdir()
        self.alias.symlink_to(os.path.relpath(self.source, self.conf))
        self.refuse_without_changes()

    def test_existing_dangling_symlink_is_never_overwritten(self):
        self.conf.mkdir()
        self.alias.symlink_to(self.root / 'absent.xml')
        self.refuse_without_changes()

    def test_existing_destination_directory_is_never_replaced(self):
        self.alias.mkdir(parents=True)
        self.refuse_without_changes()

    def test_existing_conf_file_is_refused(self):
        self.conf.write_bytes(b'not a directory\n')
        self.refuse_without_changes()

    def test_dangling_conf_symlink_is_refused(self):
        self.conf.symlink_to(self.root / 'absent-conf')
        self.refuse_without_changes()

    def test_real_target_conf_symlink_is_refused(self):
        self.conf.symlink_to(self.base / 'conf', target_is_directory=True)
        self.refuse_without_changes()

    def test_source_absent_is_refused_before_home_mutations(self):
        self.source.unlink()
        self.refuse_without_changes()

    def test_exact_alias_with_missing_source_is_refused_without_mutation(self):
        self.conf.mkdir()
        self.alias.symlink_to(self.source)
        self.source.unlink()
        self.refuse_without_changes()

    def test_source_symlink_even_to_regular_file_is_refused(self):
        self.source.unlink()
        self.source.symlink_to(self.stock)
        self.refuse_without_changes()

    def test_source_directory_is_refused(self):
        self.source.unlink()
        self.source.mkdir()
        self.refuse_without_changes()

    def test_unreadable_source_is_refused_before_home_mutations(self):
        if os.geteuid() == 0:
            self.skipTest('Root bypasses ordinary file read permission; run suite unprivileged too.')
        self.source.chmod(0o000)
        self.addCleanup(self.source.chmod, 0o644)
        self.refuse_without_changes()

    def test_home_parent_symlink_is_refused(self):
        self.home.rmdir()
        moved = self.root / 'other-home'
        moved.mkdir()
        self.home.symlink_to(moved, target_is_directory=True)
        self.refuse_without_changes()

    def test_home_parent_not_directory_is_refused(self):
        self.home.rmdir()
        self.home.write_bytes(b'not a directory\n')
        self.refuse_without_changes()

    def test_source_parent_symlink_is_refused(self):
        moved = self.base / 'moved-conf'
        self.source.parent.rename(moved)
        self.source.parent.symlink_to(moved, target_is_directory=True)
        self.refuse_without_changes()

    def test_link_creation_failure_propagates_without_force_overwrite(self):
        self.conf.mkdir()
        def concurrent_create(path, target):
            path.write_bytes(b'concurrent file must survive\n')
            os.symlink(target, path)
        with mock.patch.object(Path, 'symlink_to', concurrent_create):
            with self.assertRaises(FileExistsError):
                self.invoke()
        self.assertEqual(self.alias.read_bytes(), b'concurrent file must survive\n')
        self.assertFalse(self.alias.is_symlink())

    def test_runtime_readability_failure_is_not_reported_as_success(self):
        self.conf.mkdir()
        self.alias.symlink_to(self.source)
        before = self.snapshot()
        other = 'root' if os.geteuid() else 'nobody'
        with mock.patch.object(configure, 'GROUP', other), \
                mock.patch.object(configure.subprocess, 'run', return_value=mock.Mock(returncode=1)) as run:
            with self.assertRaisesRegex(RuntimeError, 'runtime account'):
                self.invoke()
        run.assert_called_once_with(['/usr/sbin/runuser', '--user', other, '--', '/usr/bin/test', '-r', str(self.alias)], check=False)
        self.assertEqual(self.snapshot(), before)


class HomeConfSourceContracts(unittest.TestCase):
    def test_fresh_only_placement_and_unchanged_private_permissions(self):
        fresh = (APP / 'scripts/install-fresh.sh').read_text()
        command = 'python3 "$ROOT/scripts/configure.py" home-conf'
        self.assertEqual(fresh.count(command), 1)
        self.assertLess(fresh.index('init --bundle "$ROOT" --port 3000'), fresh.index(command))
        for permission in ('chmod 0640 "$BASE/conf/Catalina/localhost/ROOT.xml"',
                           'chmod 0755 "$BASE"', 'chmod 0755 "$BASE/logs" "$BASE/work" "$BASE/temp"'):
            self.assertLess(fresh.index(permission), fresh.index(command))
        self.assertLess(fresh.index(command), fresh.index('systemctl enable --now contoso-orderdesk.service'))
        for name in ('install.sh', 'snapshot.py', 'rollback.sh', 'switch.sh'):
            self.assertNotIn('home-conf', (APP / 'scripts' / name).read_text())
        helper = ast.get_source_segment((APP / 'scripts/configure.py').read_text(),
            next(n for n in ast.parse((APP / 'scripts/configure.py').read_text()).body
                 if isinstance(n, ast.FunctionDef) and n.name == 'tomcat_home_conf'))
        for forbidden in ('ROOT.xml', '/etc/tomcat10/server.xml', 'chmod -R', 'copy', 'systemctl'):
            self.assertNotIn(forbidden, helper)
        self.assertNotIn('azmig', helper)
        self.assertIn('destination.symlink_to(source)', helper)
        self.assertIn('os.path.samestat', helper)

    def test_runtime_contains_current_helper_and_fresh_script_and_no_extra_config(self):
        runtime = APP / 'dist/runtime.zip'
        self.assertEqual(hashlib.sha256(runtime.read_bytes()).hexdigest(),
                         (APP / 'dist/runtime.sha256').read_text().strip())
        with zipfile.ZipFile(runtime) as archive:
            self.assertIsNone(archive.testzip())
            for name in ('scripts/configure.py', 'scripts/install-fresh.sh', 'dist/contoso-orderdesk.war'):
                self.assertEqual(archive.read(name), (APP / name).read_bytes())
            self.assertIn(b'def tomcat_home_conf(', archive.read('scripts/configure.py'))
            self.assertIn(b'configure.py" home-conf', archive.read('scripts/install-fresh.sh'))
            self.assertFalse(any(name.endswith('.xml') or 'ROOT.xml' in name for name in archive.namelist()))
            for line in archive.read('RUNTIME-SHA256SUMS').decode().splitlines():
                digest, name = line.split('  ', 1)
                self.assertEqual(hashlib.sha256(archive.read(name)).hexdigest(), digest)
                self.assertEqual(archive.read(name), (APP / name).read_bytes())


if __name__ == '__main__':
    unittest.main(verbosity=2)
