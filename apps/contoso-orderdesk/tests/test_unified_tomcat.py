#!/usr/bin/env python3
"""Offline native-filesystem tests with synthetic publisher archives and mocked downloads.

Run from an owned native project directory; no packages, network, guest or service is used.
Modes, links, archive paths and file content are real; root ownership is explicitly modeled.
The synthetic JDBC class is not a compiled Java class and is never claimed as runtime proof.
"""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import pwd
import shutil
import stat
import subprocess
import sys
import tarfile
import unittest
from unittest import mock
import uuid
import xml.etree.ElementTree as ET
import zipfile

sys.dont_write_bytecode = True
APP = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location('unified_' + name, APP / 'scripts' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


dist = load('tomcat_dist')
configure = load('configure')


def jar(entries):
    output = io.BytesIO()
    with zipfile.ZipFile(output, 'w') as archive:
        for name, data in entries.items():
            archive.writestr(name, data)
    return output.getvalue()


def distribution():
    files = {name: b'synthetic publisher fixture\n' for name in dist.REQUIRED}
    files['bin/catalina.sh'] = b'#!/bin/sh\nexit 0\n'
    files['conf/web.xml'] = b'<web-app><!-- unchanged publisher defaults fixture --></web-app>\n'
    files['conf/server.xml'] = b'<Server port="8005"/>\n'
    files['lib/tomcat-jdbc.jar'] = jar({dist.FACTORY: b'not executable; synthetic class fixture'})
    files['lib/catalina.jar'] = jar({'org/apache/catalina/util/ServerInfo.properties':
                                    ('server.info=Apache Tomcat/' + dist.VERSION + '\n').encode()})
    for app in ('ROOT', 'docs', 'examples', 'manager', 'host-manager'):
        files['webapps/' + app + '/index.html'] = b'publisher app fixture must not deploy'
    return files


class NativeFixtures(unittest.TestCase):
    def setUp(self):
        self.root = Path.cwd() / ('.unified-tomcat-fixture-' + uuid.uuid4().hex)
        self.root.mkdir(mode=0o755)
        self.addCleanup(shutil.rmtree, self.root)
        self.destination = self.root / 'tomcat'
        self.archive = self.root / dist.ARCHIVE
        self.files = distribution()

    def archive_fixture(self, files=None, extra=()):
        with tarfile.open(self.archive, 'w:gz') as archive:
            top = tarfile.TarInfo(dist.TOP)
            top.type = tarfile.DIRTYPE
            top.mode = 0o777
            archive.addfile(top)
            for name, data in (self.files if files is None else files).items():
                member = tarfile.TarInfo(dist.TOP + '/' + name)
                member.size = len(data)
                member.mode = 0o777  # Untrusted permissions must not be restored.
                archive.addfile(member, io.BytesIO(data))
            for member, data in extra:
                archive.addfile(member, io.BytesIO(data) if data is not None else None)
        return hashlib.sha512(self.archive.read_bytes()).hexdigest()

    def install(self, digest=None):
        dist.extract_verified(self.archive, digest or self.archive_fixture(), self.destination)

    def test_real_tree_strips_one_top_and_omits_all_bundled_apps(self):
        self.install()
        self.assertFalse(self.destination.is_symlink())
        self.assertFalse((self.destination / dist.TOP).exists())
        self.assertEqual(list((self.destination / 'webapps').iterdir()), [])
        for name in dist.REQUIRED:
            path = self.destination / name
            self.assertTrue(stat.S_ISREG(path.lstat().st_mode))
            self.assertEqual(path.read_bytes(), self.files[name])
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o755 if name == 'bin/catalina.sh' else 0o644)
        for path in (self.destination, *self.destination.rglob('*')):
            self.assertFalse(path.is_symlink())
            if path.is_dir():
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o755)
        dist.verify_layout(self.destination)

    def test_sha512_mismatch_prevents_any_extraction(self):
        self.archive_fixture()
        with self.assertRaisesRegex(ValueError, 'SHA512 mismatch'):
            self.install('0' * 128)
        self.assertFalse(self.destination.exists())

    def test_invalid_expected_digest_prevents_any_extraction(self):
        self.archive_fixture()
        for value in ('', 'a' * 127, 'G' * 128, 'A' * 128):
            with self.subTest(value=value[:8]), self.assertRaises(ValueError):
                dist.extract_verified(self.archive, value, self.destination)
        self.assertFalse(self.destination.exists())

    def test_bad_archive_and_nonregular_download_fail_closed(self):
        self.archive.write_bytes(b'not a tarball')
        with self.assertRaises((tarfile.TarError, OSError)):
            self.install(hashlib.sha512(self.archive.read_bytes()).hexdigest())
        self.assertFalse(self.destination.exists())
        self.archive.unlink()
        target = self.root / 'real-archive'
        target.write_bytes(b'fixture')
        self.archive.symlink_to(target)
        with self.assertRaises(ValueError):
            dist.extract_verified(self.archive, '0' * 128, self.destination)
        self.assertFalse(self.destination.exists())

    def test_unsafe_normalized_paths_rejected_before_tree_creation(self):
        for name in ('/escaped', '../escaped', dist.TOP + '/../escaped', dist.TOP + '/a/./b',
                     dist.TOP + '/a//b', dist.TOP + '\\escaped', 'wrong-top/file', dist.TOP + '/bad\nname'):
            member = tarfile.TarInfo(name)
            member.size = 1
            digest = self.archive_fixture(extra=((member, b'x'),))
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.install(digest)
            self.assertFalse(self.destination.exists())
        self.assertFalse((self.root / 'escaped').exists())

    def test_all_link_and_special_types_rejected(self):
        for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.FIFOTYPE, tarfile.CHRTYPE, tarfile.BLKTYPE):
            member = tarfile.TarInfo(dist.TOP + '/unsafe')
            member.type = kind
            member.linkname = '../../outside'
            digest = self.archive_fixture(extra=((member, None),))
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                self.install(digest)
            self.assertFalse(self.destination.exists())

    def test_duplicate_and_file_directory_collisions_rejected(self):
        duplicate = tarfile.TarInfo(dist.TOP + '/LICENSE')
        duplicate.size = 1
        for extra in (((duplicate, b'x'),),):
            with self.assertRaises(ValueError):
                self.install(self.archive_fixture(extra=extra))
        files = {**self.files, 'collision': b'file', 'collision/child': b'child'}
        with self.assertRaisesRegex(ValueError, 'collision'):
            self.install(self.archive_fixture(files))
        self.assertFalse(self.destination.exists())

    def test_compressed_expanded_member_and_count_bounds(self):
        digest = self.archive_fixture()
        for setting in ('MAX_DOWNLOAD', 'MAX_EXPANDED', 'MAX_FILE', 'MAX_MEMBERS'):
            with self.subTest(setting=setting), mock.patch.object(dist, setting, 1), self.assertRaises(ValueError):
                self.install(digest)
            self.assertFalse(self.destination.exists())

    def test_missing_required_file_or_exact_pool_class_is_rejected(self):
        for missing in ('LICENSE', 'conf/server.xml', 'conf/web.xml', 'bin/catalina.sh'):
            files = {k: v for k, v in self.files.items() if k != missing}
            with self.subTest(missing=missing), self.assertRaises(ValueError):
                self.install(self.archive_fixture(files))
            self.assertFalse(self.destination.exists())
        files = {**self.files, 'lib/tomcat-jdbc.jar': jar({'not/' + dist.FACTORY: b'fixture'})}
        with self.assertRaisesRegex(ValueError, 'DataSourceFactory'):
            self.install(self.archive_fixture(files))
        self.assertFalse(self.destination.exists())

    def test_runtime_jar_version_must_match_exact_pin(self):
        files = {**self.files, 'lib/catalina.jar': jar({'org/apache/catalina/util/ServerInfo.properties':
                                                     b'server.info=Apache Tomcat/10.1.60\n'})}
        with self.assertRaisesRegex(ValueError, 'version'):
            self.install(self.archive_fixture(files))
        self.assertFalse(self.destination.exists())

    def test_existing_regular_file_directory_and_links_never_overwritten(self):
        digest = self.archive_fixture()
        self.destination.write_bytes(b'existing file')
        with self.assertRaises(FileExistsError):
            self.install(digest)
        self.assertEqual(self.destination.read_bytes(), b'existing file')
        self.destination.unlink()
        self.destination.mkdir()
        marker = self.destination / 'preserve'
        marker.write_bytes(b'existing directory')
        with self.assertRaises(FileExistsError):
            self.install(digest)
        self.assertEqual(marker.read_bytes(), b'existing directory')
        shutil.rmtree(self.destination)
        for target in (self.root / 'absent', self.root):
            self.destination.symlink_to(target)
            with self.assertRaises(FileExistsError):
                self.install(digest)
            self.assertEqual(os.readlink(self.destination), str(target))
            self.destination.unlink()

    def test_symlinked_parent_and_relative_destinations_refused(self):
        digest = self.archive_fixture()
        parent = self.root / 'alias-parent'
        parent.symlink_to(self.root)
        for destination in (parent / 'new-tree', Path('relative-tree')):
            with self.subTest(destination=destination), self.assertRaises(ValueError):
                dist.extract_verified(self.archive, digest, destination)
        self.assertFalse((self.root / 'new-tree').exists())

    def test_verify_refuses_symlinked_home_server_and_default_web(self):
        self.install()
        for name in ('conf/server.xml', 'conf/web.xml'):
            target = self.destination / name
            data = target.read_bytes()
            moved = target.with_name(target.name + '.real')
            target.rename(moved)
            target.symlink_to(moved)
            with self.assertRaises(ValueError):
                dist.verify_layout(self.destination)
            target.unlink()
            moved.rename(target)
            self.assertEqual(target.read_bytes(), data)

    def test_configure_initialises_actual_default_web_root_war_private_jndi_and_port(self):
        self.install()
        bundle = self.root / 'support'
        (bundle / 'dist').mkdir(parents=True)
        war = (APP / 'dist/contoso-orderdesk.war').read_bytes()
        (bundle / 'dist/contoso-orderdesk.war').write_bytes(war)
        account = pwd.getpwuid(os.geteuid())
        with mock.patch.object(configure, 'BASE', self.destination), \
             mock.patch.object(configure, 'GROUP', account.pw_name), \
             mock.patch.object(configure.os, 'chown') as ownership, \
             mock.patch.object(configure.sys.stdin, 'isatty', return_value=True), \
             mock.patch.object(configure.getpass, 'getpass', return_value='fictional<&"fixture'), \
             contextlib.redirect_stdout(io.StringIO()):
            configure.initialise(bundle)
        self.assertTrue(ownership.called, 'Root/runtime ownership writes are mocked, not claimed as applied.')
        server = self.destination / 'conf/server.xml'
        self.assertTrue(stat.S_ISREG(server.lstat().st_mode))
        tree = ET.parse(server).getroot()
        self.assertEqual(tree.find('Service/Connector').get('port'), '3000')
        self.assertEqual(tree.find('Service/Engine/Host').get('unpackWARs'), 'false')
        self.assertEqual((self.destination / 'conf/web.xml').read_bytes(), self.files['conf/web.xml'])
        private = self.destination / 'conf/Catalina/localhost/ROOT.xml'
        self.assertEqual(stat.S_IMODE(private.stat().st_mode), 0o640)
        resource = ET.parse(private).getroot().find('Resource')
        self.assertEqual(resource.get('password'), 'fictional<&"fixture')
        self.assertIn('onprem-sql:1433;databaseName=ContosoApp;', resource.get('url'))
        self.assertEqual(resource.get('factory'), 'org.apache.tomcat.jdbc.pool.DataSourceFactory')
        self.assertEqual(resource.get('maxActive'), '4')
        self.assertEqual(resource.get('maxWait'), '5000')
        self.assertEqual({p.name for p in (self.destination / 'webapps').iterdir()}, {'ROOT.war'})
        self.assertEqual((self.destination / 'webapps/ROOT.war').read_bytes(), war)
        loader = (self.destination / 'conf/catalina.properties').read_text()
        self.assertNotIn('catalina.home', loader)
        self.assertNotIn('fictional', loader)
        self.assertFalse(server.is_symlink())

    def test_layout_guard_uses_real_modes_and_rejects_public_secrets_extra_apps_and_links(self):
        self.install()
        bundle = self.root / 'support'
        (bundle / 'dist').mkdir(parents=True)
        (bundle / 'dist/contoso-orderdesk.war').write_bytes((APP / 'dist/contoso-orderdesk.war').read_bytes())
        account = pwd.getpwuid(os.geteuid())
        original_lstat = Path.lstat
        def modeled_root_owner(path, *args, **kwargs):
            metadata = original_lstat(path, *args, **kwargs)
            if path == self.destination or self.destination in path.parents:
                values = list(metadata)
                if path.relative_to(self.destination).as_posix() not in ('logs', 'work', 'temp'):
                    values[4] = 0  # Ownership only is modeled; file types/modes and permission reads stay real.
                return os.stat_result(values)
            return metadata
        with mock.patch.object(configure, 'BASE', self.destination), \
             mock.patch.object(configure, 'GROUP', account.pw_name), \
             mock.patch.object(configure.os, 'chown'), \
             mock.patch.object(configure.sys.stdin, 'isatty', return_value=True), \
             mock.patch.object(configure.getpass, 'getpass', return_value='fictional fixture'), \
             contextlib.redirect_stdout(io.StringIO()):
            configure.initialise(bundle)
            (self.destination / 'lib/mssql-jdbc.jre11.jar').write_bytes(b'fixture; not a driver runtime')
            with mock.patch.object(Path, 'lstat', modeled_root_owner):
                configure.validate_layout()
                private = self.destination / 'conf/Catalina/localhost/ROOT.xml'
                private.chmod(0o644)
                with self.assertRaises(RuntimeError):
                    configure.validate_layout()
                private.chmod(0o640)
                extra = self.destination / 'webapps/ROOT'
                extra.mkdir()
                with self.assertRaises(RuntimeError):
                    configure.validate_layout()
                extra.rmdir()
                server = self.destination / 'conf/server.xml'
                moved = server.with_suffix('.real')
                server.rename(moved)
                server.symlink_to(moved)
                with self.assertRaises(RuntimeError):
                    configure.validate_layout()
                server.unlink()
                moved.rename(server)
                configure.validate_layout()

    def test_configuration_writer_refuses_symlink_without_overwrite(self):
        target = self.root / 'private.xml'
        original = self.root / 'original'
        original.write_bytes(b'preserve')
        target.symlink_to(original)
        with self.assertRaises(RuntimeError):
            configure.write_xml(target, ET.Element('Context'), private=True)
        self.assertEqual(original.read_bytes(), b'preserve')

    def test_download_is_https_bounded_and_does_not_run_in_offline_test(self):
        target = self.root / 'download'
        def fake_run(command, **kwargs):
            self.assertIn('--max-filesize', command)
            self.assertIn('--max-redirs', command)
            self.assertEqual(command[command.index('--proto') + 1], '=https')
            self.assertEqual(command[command.index('--proto-redir') + 1], '=https')
            self.assertEqual(kwargs['timeout'], 550)
            Path(command[command.index('--output') + 1]).write_bytes(b'bounded fixture')
            return mock.Mock(returncode=0)
        with mock.patch.object(dist.subprocess, 'run', side_effect=fake_run) as run:
            dist.download(dist.SOURCES[0] + dist.ARCHIVE, target, 1024)
        run.assert_called_once()
        for url in ('http://archive.apache.org/' + dist.ARCHIVE, 'https://example.invalid/' + dist.ARCHIVE):
            with self.assertRaises(ValueError):
                dist.download(url, target, 1024)

    def test_oversized_download_is_removed(self):
        target = self.root / 'download'
        target.write_bytes(b'oversized fixture')
        with mock.patch.object(dist.subprocess, 'run', return_value=mock.Mock(returncode=0)), \
                self.assertRaises(RuntimeError):
            dist.download(dist.SOURCES[0] + dist.ARCHIVE, target, 1)
        self.assertFalse(target.exists())

    def acquire_fixture(self, failures=(), corrupt=False):
        digest = self.archive_fixture()
        data = self.archive.read_bytes()
        calls = []
        def fetch(url, destination, limit):
            calls.append(url)
            if url in failures:
                raise RuntimeError('Synthetic blocked publisher route')
            destination.write_bytes((digest + '  ' + dist.ARCHIVE + '\n').encode()
                                    if url.endswith('.sha512') else (b'corrupt fixture' if corrupt else data))
        receipt = self.root / 'receipt.json'
        staging = self.root / 'owned-download'
        with mock.patch.object(dist, 'download', side_effect=fetch), contextlib.redirect_stdout(io.StringIO()):
            dist.acquire(self.destination, staging, receipt)
        self.assertFalse(staging.exists())
        return calls, json.loads(receipt.read_text()), digest

    def test_same_version_fallback_retains_one_publisher_digest_and_receipt(self):
        first = dist.SOURCES[0] + dist.ARCHIVE
        calls, receipt, digest = self.acquire_fixture(failures=(first,))
        self.assertEqual(calls, [first + '.sha512', first, dist.SOURCES[1] + dist.ARCHIVE])
        self.assertEqual(receipt['publisherSha512'], digest)
        self.assertEqual(receipt['version'], '10.1.61')
        self.assertIn('no independent PGP', receipt['assurance'])
        self.assertEqual(receipt['sha512Url'], first + '.sha512')
        self.assertEqual(receipt['archiveUrl'], dist.SOURCES[1] + dist.ARCHIVE)

    def test_unavailable_checksum_leaves_no_tree_and_removes_owned_downloads(self):
        staging = self.root / 'owned-download'
        with mock.patch.object(dist, 'download', side_effect=RuntimeError('synthetic unavailable')) as download, \
                self.assertRaisesRegex(RuntimeError, 'SHA512 unavailable'):
            dist.acquire(self.destination, staging, self.root / 'receipt.json')
        self.assertEqual(download.call_count, 2)
        self.assertFalse(self.destination.exists())
        self.assertFalse(staging.exists())

    def test_checksum_mismatch_is_terminal_and_never_tries_other_digest_or_archive(self):
        self.archive_fixture()
        digest = hashlib.sha512(self.archive.read_bytes()).hexdigest()
        calls = []
        def fetch(url, destination, limit):
            calls.append(url)
            destination.write_bytes(digest.encode() if url.endswith('.sha512') else b'corrupt fixture')
        staging = self.root / 'owned-download'
        with mock.patch.object(dist, 'download', side_effect=fetch), self.assertRaisesRegex(ValueError, 'SHA512 mismatch'):
            dist.acquire(self.destination, staging, self.root / 'receipt.json')
        self.assertEqual(len(calls), 2)
        self.assertFalse(self.destination.exists())
        self.assertFalse(staging.exists())

    def test_acquisition_refuses_occupied_destination_receipt_or_staging_before_download(self):
        staging = self.root / 'download'
        receipt = self.root / 'receipt.json'
        for occupied in (self.destination, receipt, staging):
            occupied.write_bytes(b'preserve')
            with mock.patch.object(dist, 'download') as fetch, self.assertRaises((FileExistsError, ValueError)):
                dist.acquire(self.destination, staging, receipt)
            fetch.assert_not_called()
            self.assertEqual(occupied.read_bytes(), b'preserve')
            occupied.unlink()


class SourceContracts(unittest.TestCase):
    def test_publisher_checksum_parser(self):
        digest = 'ab' * 64
        for text in (digest, digest.upper() + '\n', digest + '  ' + dist.ARCHIVE + '\n',
                     digest + ' *' + dist.ARCHIVE, 'SHA512 (' + dist.ARCHIVE + ') = ' + digest):
            self.assertEqual(dist.parse_checksum(text.encode()), digest)
        for text in ('0' * 127, 'g' * 128, digest + '  other.tar.gz', digest + '  ../' + dist.ARCHIVE,
                     digest + '\n' + digest, '<html>' + digest, digest + ' trailing', 'x' * 1025):
            with self.subTest(text=text[:20]), self.assertRaises(ValueError):
                dist.parse_checksum(text.encode())

    def test_unified_service_java_launch_hardening_and_fresh_only_installer(self):
        service = (APP / 'scripts/contoso-orderdesk.service.in').read_text()
        for expected in ('User=contoso-orderdesk', 'Group=contoso-orderdesk', 'JAVA_HOME=__JAVA_HOME__',
                         'CATALINA_HOME=/opt/tomcat', 'CATALINA_BASE=/opt/tomcat',
                         'CATALINA_TMPDIR=/opt/tomcat/temp', 'WorkingDirectory=/opt/tomcat',
                         'ExecStart=/opt/tomcat/bin/catalina.sh run', 'tomcat_dist.py verify --destination /opt/tomcat',
                         'ReadWritePaths=/opt/tomcat/work /opt/tomcat/logs /opt/tomcat/temp',
                         'NoNewPrivileges=true', 'ProtectSystem=strict', 'ProtectHome=true',
                         '-Xmx384m', 'MaxMetaspaceSize=192m', 'MemoryMax=900M', 'TasksMax=150'):
            self.assertIn(expected, service)
        fresh = (APP / 'scripts/install-fresh.sh').read_text()
        self.assertLess(fresh.index('Initial deployment paths are occupied'), fresh.index('tomcat_dist.py" install'))
        self.assertLess(fresh.index('tomcat_dist.py" install'), fresh.index('init --bundle'))
        self.assertLess(fresh.index('configure.py" layout'), fresh.index('systemctl enable --now'))
        self.assertIn('chown -R root:root "$BASE"', fresh)
        self.assertIn('chown contoso-orderdesk:contoso-orderdesk "$BASE/logs" "$BASE/work" "$BASE/temp"', fresh)
        self.assertIn('chmod 0640 "$BASE/conf/Catalina/localhost/ROOT.xml"', fresh)
        self.assertNotIn('chmod -R 755', fresh)
        for filename in ('common.sh', 'configure.py', 'install-fresh.sh', 'validate.sh', 'contoso-orderdesk.service.in'):
            text = (APP / 'scripts' / filename).read_text()
            for old in ('/usr/share/tomcat10', '/etc/tomcat10', '/var/lib/contoso-orderdesk', 'home-conf'):
                self.assertNotIn(old, text)
        for filename in ('install.sh', 'snapshot.py', 'switch.sh', 'rollback.sh', 'proxy.sh'):
            self.assertFalse((APP / 'scripts' / filename).exists())

    def test_host_prerequisites_final_java_readiness_and_embedding_contract(self):
        workshop = APP.parents[1]
        host = (workshop / 'scripts/host/configure-host.ps1').read_text(encoding='utf-8-sig')
        app_line = next(line for line in host.splitlines() if line.startswith('Create-LinuxGuestVM') and 'OnPrem-Linux-App' in line)
        self.assertIn('@("openjdk-17-jre-headless", "ca-certificates")', app_line)
        self.assertNotIn('"tomcat10"', app_line)
        self.assertIn("javaVersion -notmatch '^17(?:\\.|$)'", host)
        self.assertIn('LAB_BUILD|ubuntu2404-tomcat101-unified-v1', host)
        self.assertEqual(host.count('__TOMCAT_RUNTIME_PAYLOAD__'), 1)
        self.assertEqual(host.count('__TOMCAT_RUNTIME_SHA256__'), 1)
        deploy = (workshop / 'scripts/deploy-lab.ps1').read_text(encoding='utf-8-sig')
        self.assertIn("'dist/runtime.zip'", deploy)
        self.assertIn("'dist/runtime.sha256'", deploy)
        self.assertIn('Get-FileHash -LiteralPath $runtimePath -Algorithm SHA256', deploy)

    def test_minimal_runtime_exact_source_checksums_and_no_binary_distribution(self):
        target = APP / 'dist/runtime.zip'
        self.assertEqual(hashlib.sha256(target.read_bytes()).hexdigest(), (APP / 'dist/runtime.sha256').read_text().strip())
        with zipfile.ZipFile(target) as archive:
            self.assertIsNone(archive.testzip())
            self.assertIn('scripts/tomcat_dist.py', archive.namelist())
            self.assertLess(target.stat().st_size, 100000)
            self.assertFalse(any(name.endswith(('.jar', '.tar.gz', '.md')) for name in archive.namelist()))
            for line in archive.read('RUNTIME-SHA256SUMS').decode().splitlines():
                digest, name = line.split('  ', 1)
                self.assertEqual(hashlib.sha256(archive.read(name)).hexdigest(), digest)
                self.assertEqual(archive.read(name), (APP / name).read_bytes())
            self.assertNotIn(b'home-conf', archive.read('scripts/configure.py'))
            embedded = (APP.parents[1] / 'scripts/host/configure-host.ps1').read_text(encoding='utf-8-sig')
            embedded = embedded.replace('__TOMCAT_RUNTIME_PAYLOAD__', __import__('base64').b64encode(target.read_bytes()).decode())
            embedded = embedded.replace('__TOMCAT_RUNTIME_SHA256__', hashlib.sha256(target.read_bytes()).hexdigest())
            self.assertNotIn('__TOMCAT_RUNTIME_', embedded)


if __name__ == '__main__':
    unittest.main(verbosity=2)
