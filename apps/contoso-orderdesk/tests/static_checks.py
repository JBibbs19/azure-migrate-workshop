#!/usr/bin/env python3
"""Static/stdlib checks only. Never execute install scripts or claim JVM/SQL tests."""
import ast
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import unittest
from unittest import mock
import xml.etree.ElementTree as ET
import zipfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / 'tests/.static-work'


def load(name):
    specification = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / (name + '.py'))
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


hosts = load('hosts')
configure = load('configure')
driver = load('driver_check')
traffic = load('traffic')


def balanced_java(text):
    # Lexical delimiter check is intentionally NOT a Java compiler/type checker.
    text = re.sub(r'<%@.*?%>', '', text, flags=re.S)
    text = text.replace('<%!', '').replace('<%', '').replace('%>', '')
    stripped = re.sub(r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|//[^\n]*|/\*.*?\*/', '', text, flags=re.S)
    stack = []
    pairs = {')': '(', ']': '[', '}': '{'}
    for character in stripped:
        if character in '([{':
            stack.append(character)
        elif character in pairs:
            if not stack or stack.pop() != pairs[character]:
                return False
    return not stack


class PackageChecks(unittest.TestCase):
    def test_python_syntax(self):
        for path in ROOT.rglob('*.py'):
            with self.subTest(path=path.name):
                ast.parse(path.read_text())

    def test_bash_syntax(self):
        for path in (ROOT / 'scripts').glob('*.sh'):
            with self.subTest(path=path.name):
                result = subprocess.run(['bash', '-n', str(path)], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_descriptor_routes(self):
        ns = {'j': 'https://jakarta.ee/xml/ns/jakartaee'}
        web = ROOT / 'src/main/webapp'
        root = ET.parse(web / 'WEB-INF/web.xml').getroot()
        self.assertEqual(root.get('version'), '6.0')
        self.assertEqual(root.find('j:display-name', ns).text, 'Contoso Order Desk')
        self.assertEqual({e.text for e in root.findall('j:servlet-mapping/j:url-pattern', ns)},
                         {'/', '/api/health', '/api/info', '/api/ready', '/api/orders'})
        self.assertEqual(root.find('j:resource-ref/j:res-ref-name', ns).text, 'jdbc/ContosoApp')
        self.assertEqual(root.find('j:resource-ref/j:res-type', ns).text, 'javax.sql.DataSource')
        for element in root.findall('j:servlet/j:jsp-file', ns) + root.findall('j:error-page/j:location', ns):
            self.assertTrue((web / element.text.lstrip('/')).is_file())

    def test_jsp_lexical_and_health_contract(self):
        web = ROOT / 'src/main/webapp'
        for path in list(web.rglob('*.jsp')) + list(web.rglob('*.jspf')):
            with self.subTest(path=path.name):
                self.assertTrue(balanced_java(path.read_text()))
                self.assertNotIn('javax.servlet', path.read_text())
        controller = (web / 'WEB-INF/views/controller.jsp').read_text()
        health = controller.split('if (path.equals("/api/health")) {', 1)[1].split('if (path.equals("/api/info"))', 1)[0]
        for field in ('healthy', 'OnPrem-Linux-App', 'timestamp', 'Contoso Order Desk'):
            self.assertIn(field, health)
        self.assertNotIn('database()', health)
        self.assertNotIn('getConnection', health)
        self.assertIn('response.setStatus(503)', controller)
        self.assertIn('recent = null; customerList = null;', controller)
        self.assertIn('sameOrigin(request)', controller)
        self.assertNotIn('e.printStackTrace', controller)
        self.assertNotIn('json(e.getMessage())', controller.split('catch (Exception e)', 1)[1])
        common = (web / 'WEB-INF/jspf/common.jspf').read_text()
        self.assertIn('jakarta.servlet.http.HttpServletRequest', common)
        self.assertIn('javax.sql.DataSource', common)
        self.assertIn('OUTPUT INSERTED.OrderID VALUES (?, ?, ?, ?)', common)
        self.assertIn('s.setNString(2, product)', common)
        self.assertIn('statement(c, "SELECT CustomerID FROM dbo.Customers WHERE CustomerID = ?")', common)
        self.assertNotRegex(common.upper(), r'CREATE\s+(TABLE|DATABASE)')
        self.assertIn('s.setQueryTimeout(5)', common)

    def test_war_contents_match_source_and_no_credentials(self):
        with zipfile.ZipFile(ROOT / 'dist/contoso-orderdesk.war') as archive:
            self.assertIsNone(archive.testzip())
            self.assertIn('META-INF/MANIFEST.MF', archive.namelist())
            self.assertNotIn('META-INF/context.xml', archive.namelist())
            self.assertFalse(any(name.endswith('.jar') for name in archive.namelist()))
            for name in archive.namelist():
                self.assertFalse(name.startswith('/') or '..' in Path(name).parts)
                if name.startswith('WEB-INF/'):
                    self.assertEqual(archive.read(name), (ROOT / 'src/main/webapp' / name).read_bytes())
                self.assertNotIn(b'password=', archive.read(name).lower())

    def test_private_jndi_and_bounded_pool(self):
        captured = {}
        def capture(path, element, private=False):
            captured.update(path=path, element=element, private=private)
        with mock.patch.object(configure, 'BASE', WORK), mock.patch.object(configure.sys.stdin, 'isatty', return_value=True), \
             mock.patch.object(configure.getpass, 'getpass', return_value='fictional<&\"fixture'), \
             mock.patch.object(configure, 'write_xml', side_effect=capture):
            configure.database(force=True)
        resource = captured['element'].find('Resource')
        self.assertTrue(captured['private'])
        self.assertEqual(resource.get('factory'), 'org.apache.tomcat.jdbc.pool.DataSourceFactory')
        self.assertEqual(resource.get('maxActive'), '4')
        self.assertEqual(resource.get('minIdle'), '1')
        self.assertEqual(resource.get('maxWait'), '5000')
        self.assertIn('onprem-sql:1433', resource.get('url'))
        self.assertNotIn('password', resource.get('url'))
        self.assertEqual(ET.fromstring(ET.tostring(captured['element'])).find('Resource').get('password'), 'fictional<&\"fixture')
        seed = WORK / 'initial-seed.json'
        fixture = 'fictional<&\"\'%;$`\\\\__USER__\nPY\n'
        seed.write_text(json.dumps(fixture))
        metadata = mock.Mock(st_uid=0, st_mode=stat.S_IFREG | 0o600)
        with mock.patch.object(Path, 'lstat', return_value=metadata), \
             mock.patch.object(configure, 'write_xml', side_effect=capture), \
             mock.patch.object(configure.getpass, 'getpass', side_effect=AssertionError('Initial deployment must not prompt')):
            configure.database(force=True, password_file=seed)
        self.assertEqual(captured['element'].find('Resource').get('password'), fixture)
        for uid, mode in ((1, 0o600), (0, 0o644)):
            metadata.st_uid = uid
            metadata.st_mode = stat.S_IFREG | mode
            with mock.patch.object(Path, 'lstat', return_value=metadata):
                with self.assertRaises(RuntimeError):
                    configure.database(force=True, password_file=seed)
        path = WORK / 'private.xml'
        with mock.patch.object(configure.grp, 'getgrnam', return_value=mock.Mock(gr_gid=0)), \
             mock.patch.object(configure.os, 'chown'), mock.patch.object(configure.os, 'chmod') as chmod:
            configure.write_xml(path, captured['element'], private=True)
        chmod.assert_called_once_with(path, 0o640)
        # The artifact filesystem does not persist chmod modes. Actual permissions are target checks.

    def test_target_connector_and_jvm_bounds(self):
        captured = {}
        with mock.patch.object(configure, 'write_xml', side_effect=lambda p, e: captured.update(xml=e)):
            configure.server(3001)
        connector = captured['xml'].find('Service/Connector')
        self.assertEqual(connector.get('port'), '3001')
        self.assertEqual(connector.get('maxPostSize'), '4096')
        self.assertEqual(connector.get('maxThreads'), '25')
        self.assertEqual(captured['xml'].get('port'), '-1')
        service = (ROOT / 'scripts/contoso-orderdesk.service.in').read_text()
        self.assertIn('-Xmx384m', service)
        self.assertIn('MaxMetaspaceSize=192m', service)
        self.assertIn('MemoryMax=900M', service)
        self.assertIn('User=contoso-orderdesk', service)
        self.assertNotIn('User=root', service)
        self.assertIn('CATALINA_HOME=/opt/tomcat', service)
        self.assertIn('CATALINA_BASE=/opt/tomcat', service)
        self.assertIn('ExecStart=/opt/tomcat/bin/catalina.sh run', service)
        self.assertIn('JAVA_HOME=__JAVA_HOME__', service)
        installer = (ROOT / 'scripts/install-fresh.sh').read_text()
        for value in ('VERSION_ID == 24.04', 'require_tomcat101', 'tomcat_dist.py', 'java-17-openjdk-'):
            self.assertIn(value, installer)
        for obsolete in ('tomcat9', '/etc/tomcat10', '/usr/share/tomcat10', 'home-conf', 'systemctl disable'):
            self.assertNotIn(obsolete, installer)
        self.assertEqual(configure.BASE, Path('/opt/tomcat'))

    def test_bounded_hosts_update(self):
        text = '127.0.0.1 localhost\n192.168.0.11 onprem-sql keep-this # note\n192.168.0.10 onprem-web\n# original\n'
        ips = ('10.1.0.11', '10.1.0.13', '10.1.0.12')
        result = hosts.replace_hosts(text, ips)
        self.assertIn('192.168.0.11\tkeep-this # note', result)
        self.assertIn('192.168.0.10 onprem-web', result)
        self.assertIn('127.0.0.1 localhost', result)
        self.assertEqual(result, hosts.replace_hosts(result, ips))
        self.assertEqual(result.count('onprem-sql'), 1)
        for invalid in ('8.8.8.8', '127.0.0.1', '0.0.0.0', '::1', '169.254.0.1'):
            with self.assertRaises(ValueError):
                hosts.address(invalid)
        with self.assertRaises(ValueError):
            hosts.replace_hosts(hosts.START + '\n', ips)
        with self.assertRaises(ValueError):
            hosts.replace_hosts(hosts.END + '\n' + hosts.START + '\n', ips)

    def test_driver_prerequisite_structural_validation(self):
        jar = WORK / 'mssql-jdbc-fixture.jre11.jar'
        with zipfile.ZipFile(jar, 'w') as archive:
            archive.writestr('com/microsoft/sqlserver/jdbc/SQLServerDriver.class', b'\xca\xfe\xba\xbe\x00\x00\x00\x37')
            archive.writestr('META-INF/MANIFEST.MF', 'Implementation-Version: test fixture\n')
        with contextlib.redirect_stdout(io.StringIO()):
            driver.inspect(jar)
        with self.assertRaises(ValueError):
            driver.inspect(WORK / 'wrong.jar')

    def test_traffic_only_calls_application(self):
        calls = []
        def fake_request(base, path, data=None):
            calls.append((base, path, data))
            if path == '/api/health':
                return {'app': 'Contoso Order Desk', 'status': 'healthy'}
            if data is None:
                return {'customers': [{'customerId': 7}]}
            return {'orderId': 100}
        with mock.patch.object(traffic, 'request', side_effect=fake_request), contextlib.redirect_stdout(io.StringIO()):
            traffic.cycle('http://onprem-nginx:8080')
        self.assertEqual([c[1] for c in calls], ['/api/health', '/api/orders', '/api/orders'])
        self.assertEqual(calls[-1][2]['customerId'], 7)
        self.assertNotIn('password', (ROOT / 'scripts/traffic.py').read_text().lower())

    def test_powershell_encoding_and_static_tokens(self):
        path = ROOT / 'scripts/Prepare-ContosoSql.ps1'
        raw = path.read_bytes()
        self.assertTrue(raw.startswith(b'\xef\xbb\xbf'))
        text = raw.decode('utf-8-sig')
        self.assertTrue(text.isascii(), 'Keep payload-safe ASCII even with the direct-launch BOM.')
        self.assertEqual(len(re.findall(r'^\s*.*= @\"\s*$', text, re.M)), len(re.findall(r'^\"@\s*$', text, re.M)))
        self.assertEqual(text.count("-Query @'"), len(re.findall(r"^'@", text, re.M)))
        self.assertNotRegex(text, r'\$[A-Za-z_][A-Za-z0-9_]*:')
        self.assertIn('Read-Host', text)
        self.assertIn('-AsSecureString', text)
        self.assertIn('-VMName \'OnPrem-SQL\'', text)
        self.assertIn('Restart-Service \'MSSQL$SQLEXPRESS\'', text)
        self.assertNotRegex(text.upper(), r'CREATE\s+(TABLE|DATABASE)')
        self.assertNotIn('enable-lab-traffic.ps1', text)

    def test_initial_runtime_package_provenance(self):
        target = ROOT / 'dist/runtime.zip'
        self.assertEqual(hashlib.sha256(target.read_bytes()).hexdigest(), (ROOT / 'dist/runtime.sha256').read_text().strip())
        with zipfile.ZipFile(target) as archive:
            self.assertIsNone(archive.testzip())
            for line in archive.read('RUNTIME-SHA256SUMS').decode().splitlines():
                digest, name = line.split('  ', 1)
                data = archive.read(name)
                self.assertEqual(hashlib.sha256(data).hexdigest(), digest)
                self.assertEqual(data, (ROOT / name).read_bytes())
            self.assertIn('scripts/install-fresh.sh', archive.namelist())
            self.assertIn('dist/contoso-orderdesk.war', archive.namelist())
            self.assertFalse(any(name.endswith(('.md', '.ps1', '.jar')) for name in archive.namelist()))
        fresh = (ROOT / 'scripts/install-fresh.sh').read_text()
        self.assertIn('--port 3000 --password-file "$SEED"', fresh)
        self.assertIn('--health-only', fresh)
        self.assertNotIn('apt-get', fresh)
        self.assertNotIn('npm', fresh)
        self.assertIn('--retry-max-time 600', fresh)
        self.assertIn('RUNTIME-SHA256SUMS', fresh)
        self.assertIn('chmod 0640', fresh)


if __name__ == '__main__':
    WORK.mkdir(exist_ok=False)
    try:
        unittest.main(verbosity=2)
    finally:
        shutil.rmtree(WORK)
