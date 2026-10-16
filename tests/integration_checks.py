#!/usr/bin/env python3
"""Stdlib/static composition checks; never executes PowerShell, installs or cloud operations."""
import ast
import base64
import gzip
import hashlib
import io
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import unittest
import uuid
import zipfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'apps/contoso-orderdesk'
HOST = (ROOT / 'scripts/host/configure-host.ps1').read_text(encoding='utf-8-sig')
DEPLOY = (ROOT / 'scripts/deploy-lab.ps1').read_text(encoding='utf-8-sig')
TRAFFIC = (ROOT / 'scripts/enable-lab-traffic.ps1').read_text(encoding='utf-8-sig')


def template(text, values):
    return re.sub(r'__[A-Z][A-Z0-9_]*__', lambda match: values[match.group()], text)


def fragment(name):
    match = re.search(r'\$' + re.escape(name) + r" = @'\n(.*?)\n'@", HOST, re.S)
    if match is None:
        raise AssertionError('Missing host fragment: ' + name)
    return match.group(1)


def shell_blocks(yaml):
    blocks, current = [], None
    for line in yaml.splitlines():
        if line.startswith('  - '):
            if current is not None:
                blocks.append('\n'.join(current) + '\n')
            current = [] if line == '  - |' else [line[4:]]
        elif current is not None and line.startswith('    '):
            current.append(line[4:])
        elif line.strip():
            raise AssertionError('Unexpected generated runcmd indentation')
    if current is not None:
        blocks.append('\n'.join(current) + '\n')
    return blocks


def composed_host():
    runtime = (APP / 'dist/runtime.zip').read_bytes()
    content = HOST.replace('# LAB_HEALTH_HELPERS', (ROOT / 'scripts/health.ps1').read_text(encoding='utf-8-sig'))
    content = content.replace('__LAB_TRAFFIC_PAYLOAD__', base64.b64encode(gzip.compress(TRAFFIC.encode(), mtime=0)).decode())
    content = content.replace('__TOMCAT_RUNTIME_PAYLOAD__', base64.b64encode(runtime).decode())
    return content.replace('__TOMCAT_RUNTIME_SHA256__', hashlib.sha256(runtime).hexdigest())


class IntegrationChecks(unittest.TestCase):
    def test_complete_local_checkout_and_payload(self):
        for path in ('build.py', 'src/main/webapp/WEB-INF/web.xml', 'src/main/webapp/WEB-INF/jspf/common.jspf',
                     'dist/contoso-orderdesk.war', 'dist/runtime.zip', 'dist/runtime.sha256',
                     'scripts/install-fresh.sh', 'scripts/configure.py', 'scripts/driver_check.py'):
            self.assertTrue((APP / path).is_file(), path)
        for value in ("'apps/contoso-orderdesk'", "'dist/runtime.zip'", 'Get-FileHash -LiteralPath $runtimePath', 'Parser]::ParseInput($content'):
            self.assertIn(value, DEPLOY)
        self.assertLess(DEPLOY.index('$hostScript = Read-LabHostConfiguration'), DEPLOY.index('Set-AzVMRunCommand -ResourceGroupName'))
        for marker in ('# LAB_HEALTH_HELPERS', '__LAB_TRAFFIC_PAYLOAD__', '__TOMCAT_RUNTIME_PAYLOAD__', '__TOMCAT_RUNTIME_SHA256__'):
            self.assertEqual(HOST.count(marker), 1)
            self.assertNotIn(marker, composed_host())
        for value in ('https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img',
                      'https://cloud-images.ubuntu.com/noble/current/SHA256SUMS', 'Ubuntu2404-cloudimg.img',
                      'Ubuntu2404-Base.vhdx', 'LAB_BUILD|ubuntu2404-tomcat101-v1', '$labResuming -and -not $matchingBuild'):
            self.assertIn(value, HOST)
        self.assertNotIn('jammy/current', HOST)
        self.assertNotIn('Ubuntu2204', HOST)
        self.assertLess(HOST.index('Get-FileHash $ubuntuQcow2 -Algorithm SHA256'), HOST.index("-Stage 'Convert Ubuntu image'"))
        self.assertLess(HOST.index('$labBuildMarker ='), HOST.index('Remove-VM -Name $VMName'))
        checksum_pattern = re.search(r"\$hashLine = .*?\$_ -match '([^']+)'", HOST).group(1)
        digest = 'a' * 64
        self.assertIsNotNone(re.fullmatch(checksum_pattern, digest + ' *noble-server-cloudimg-amd64.img'))
        for invalid in ('noble-server-cloudimg-amd64Ximg', 'jammy-server-cloudimg-amd64.img', 'noble-server-cloudimg-arm64.img'):
            self.assertIsNone(re.fullmatch(checksum_pattern, digest + ' *' + invalid))
        self.assertIn('-ProtectedParameter $protected', DEPLOY)
        self.assertIn('AdminPassword', DEPLOY.split('$protected =', 1)[1].split('Set-AzVMRunCommand -ResourceGroupName', 1)[0])

    def test_runtime_zip_guards_and_source(self):
        path = APP / 'dist/runtime.zip'
        self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), (APP / 'dist/runtime.sha256').read_text().strip())
        with zipfile.ZipFile(path) as archive:
            self.assertIsNone(archive.testzip())
            names = set()
            for line in archive.read('RUNTIME-SHA256SUMS').decode().splitlines():
                digest, name = line.split('  ', 1)
                names.add(name)
                self.assertEqual(hashlib.sha256(archive.read(name)).hexdigest(), digest)
                self.assertEqual(archive.read(name), (APP / name).read_bytes())
            self.assertEqual(set(archive.namelist()), names | {'RUNTIME-SHA256SUMS'})
            self.assertFalse(any(name.endswith(('.md', '.ps1', '.jar')) for name in names))
            self.assertFalse(any(name.startswith('/') or '..' in Path(name).parts for name in names))
        self.assertIn('source.read_bytes()).hexdigest()', HOST)
        self.assertIn('archive.testzip()', HOST)
        self.assertIn('sha256sum --check --quiet RUNTIME-SHA256SUMS', (APP / 'scripts/install-fresh.sh').read_text())

    def test_cloud_init_composition_special_passwords(self):
        fixtures = ["fictional<&\"'%;$`\\__USER____RUNTIME_SHA__", 'fictional\nPY\n\"@\n${not_code}', 'fictional\u00e9\u6f22&|<>;']
        raw_runtime = (APP / 'dist/runtime.zip').read_bytes()
        digest = hashlib.sha256(raw_runtime).hexdigest()
        for number, password in enumerate(fixtures):
            with self.subTest(fixture=number):
                seed = base64.b64encode(json.dumps(password, ensure_ascii=False).encode()).decode()
                files = template(fragment('tomcatWriteFilesYaml'), {'__RUNTIME__': base64.b64encode(raw_runtime).decode(), '__SQL_SEED__': seed})
                commands = template(fragment('tomcatRunCmdYaml'), {'__RUNTIME_SHA__': digest})
                user_data = template(fragment('userData'), {'__PASSWORD__': json.dumps(password, ensure_ascii=False),
                    '__USER__': 'fixtureuser', '__PKGYAML__': '  - tomcat10\n  - openjdk-17-jre-headless',
                    '__WRITEFILES__': files, '__RUNYAML__': commands})
                quoted = re.search(r'^      password: (.*)$', user_data, re.M).group(1)
                self.assertEqual(json.loads(quoted), password)
                self.assertEqual(json.loads(base64.b64decode(seed)), password)
                self.assertEqual(files.count("permissions: '0600'"), 2)
                self.assertNotIn(password, commands)
                block = shell_blocks(commands)[0]
                result = subprocess.run(['bash', '-n'], input=block, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                ast.parse(block.split("python3 - <<'PY'\n", 1)[1].split('\nPY\n', 1)[0])
        self.assertIn('MatchEvaluator', HOST)
        self.assertIn("'__WRITEFILES__' = $ExtraWriteFilesYaml", HOST)

    def test_sql_ordering_schema_and_marker_policy(self):
        fresh = (APP / 'scripts/install-fresh.sh').read_text()
        for value in ('--port 3000 --password-file "$SEED"', '--health-only'):
            self.assertIn(value, fresh)
        self.assertNotIn(' --write', fresh)
        for value in ('-ArgumentList $guestAdminPwd -ScriptBlock', 'param([string]$LabPassword)', '-Name LoginMode -Value 2',
                      'CREATE LOGIN [labapp]', 'db_datareader ADD MEMBER [labapp]', 'db_datawriter ADD MEMBER [labapp]'):
            self.assertIn(value, HOST)
        self.assertIn('$LabPassword.Replace("\'", "\'\'")', HOST)
        self.assertLess(HOST.index('$loginQuery = @"'), HOST.index("Write-Log 'Validating sample applications..."))
        start = HOST.index("if (-not $healthy) { throw")
        self.assertLess(start, HOST.index('setup-complete.json', start))
        assertions = HOST.split('function Assert-LabSourceWorkloads', 1)[1].split('$vhdPath', 1)[0]
        for value in ('api/health', 'api/info', 'api/ready', 'api/orders', '$orders.customerCount -lt 1', '$orders.count -lt 1', 'Contoso Order Desk', '192.168.0.12:8080/api/ready'):
            self.assertIn(value, assertions)
        baseline = json.loads((ROOT / 'tests/baseline-manifest.json').read_text())
        self.assertEqual(hashlib.sha256(re.search(r'\$createTables = (.*)', HOST).group(1).encode()).hexdigest(), baseline['sql_seed_statement_sha256'])
        step = (ROOT / 'scripts/migrate-step5-cutover.ps1').read_text(encoding='utf-8-sig')
        self.assertNotIn('dbo.Products', step)
        for value in ('LAB_SQL_DATA_OK', '$stdout -cnotmatch', "$workloadStatus = 'SQL DATA NOT VERIFIED'"):
            self.assertIn(value, step)

    def test_no_node_execution_and_preserved_disable_dependencies(self):
        for content in (HOST, TRAFFIC, (APP / 'scripts/install-fresh.sh').read_text()):
            self.assertNotRegex(content, r'\b(?:npm|nodejs|setup_24|/usr/bin/node|lab-traffic\.js)\b')
        disabled = TRAFFIC.split('if ($Disable) {', 1)[1].split("Write-Step 'Adding hosts", 1)[0]
        for forbidden in ('DROP LOGIN', 'DROP USER', 'removeSqlLogin', 'nginxRemovePayload', 'lab-order-desk.conf'):
            self.assertNotIn(forbidden, disabled)
        self.assertNotIn('DROP LOGIN', TRAFFIC)
        for value in ('traffic.sh off', 'traffic.sh on __INTERVAL__', "FromBase64String('__PASSWORD_B64__')", '$builder.Password = $sqlPassword',
                      "GetEnvironmentVariable(''LAB_SSH_PASSWORD'',''Process'')", "Read-Host 'Linux guest username supplied at deployment'"):
            self.assertIn(value, TRAFFIC)
        self.assertNotIn('echo %LAB_SSH_PASSWORD%', TRAFFIC)
        self.assertNotIn('SQL_PASSWORD', (APP / 'scripts/traffic.py').read_text())
        self.assertIn('http://onprem-nginx:8080', (APP / 'scripts/configure.py').read_text())

    def test_nginx_proxy_and_embedded_shell_syntax(self):
        nginx = fragment('nginxRunCmdYaml')
        for value in ('listen 8080;', 'proxy_pass http://onprem-app:3000;', 'proxy_set_header Host $http_host;', 'TD SYNNEX | Linux Web', '192.168.0.13 onprem-app'):
            self.assertIn(value, nginx)
        for name in ('nginxRunCmdYaml', 'tomcatRunCmdYaml', 'hyperVIntegration', 'networkPrepare'):
            for block in shell_blocks(fragment(name)):
                result = subprocess.run(['bash', '-n'], input=block, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, name + ': ' + result.stderr)
        for name in ('nginxPayload', 'appPayload', 'appRemovePayload'):
            script = re.search(r'\$' + name + r" = @'\n(.*?)\n'@", TRAFFIC, re.S).group(1)
            result = subprocess.run(['bash', '-n'], input=script, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
        for path in APP.rglob('*.sh'):
            result = subprocess.run(['bash', '-n', str(path)], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_local_driver_route_and_bounded_download(self):
        for value in ('[bool]$TomcatJdbcJar -ne [bool]$TomcatJdbcSha256', 'Get-FileHash -LiteralPath $TomcatJdbcJar', "'mssql-jdbc-13.6.0.jre11.jar'", 'ZipArchiveMode]::Update'):
            self.assertIn(value, DEPLOY)
        fresh = (APP / 'scripts/install-fresh.sh').read_text()
        for value in ("--proto '=https'", '--connect-timeout 15', '--max-time 180', '--retry 3', '--retry-max-time 600', 'driver_check.py', '/mssql-jdbc/13.6.0.jre11/', 'sha256sum --check --quiet SHA256SUMS'):
            self.assertIn(value, fresh)
        buffer = io.BytesIO((APP / 'dist/runtime.zip').read_bytes())
        fixture = b'fictional structural placeholder; not distributed'
        with zipfile.ZipFile(buffer, 'a') as archive:
            archive.writestr('jdbc/mssql-jdbc-13.6.0.jre11.jar', fixture)
            archive.writestr('jdbc/SHA256SUMS', hashlib.sha256(fixture).hexdigest() + '  mssql-jdbc-13.6.0.jre11.jar\n')
        with zipfile.ZipFile(buffer) as archive:
            self.assertIsNone(archive.testzip())
            digest, filename = archive.read('jdbc/SHA256SUMS').decode().strip().split('  ', 1)
            self.assertEqual(hashlib.sha256(archive.read('jdbc/' + filename)).hexdigest(), digest)

    def test_discovery_security_and_nonroot_bounds(self):
        service = (APP / 'scripts/contoso-orderdesk.service.in').read_text()
        for value in ('User=contoso-orderdesk', 'Group=contoso-orderdesk', '-Xmx384m', 'MemoryMax=900M', 'UMask=0022'):
            self.assertIn(value, service)
        validator = (APP / 'scripts/validate.sh').read_text()
        for value in ('/usr/share/tomcat10 "$BASE"', 'sudo -n netstat -ntp', 'sudo -n ls', '640:root:contoso-orderdesk'):
            self.assertIn(value, validator)
        self.assertIn('NOPASSWD:ALL', HOST)
        self.assertIn('chmod 0640 "$BASE/conf/Catalina/localhost/ROOT.xml"', (APP / 'scripts/install-fresh.sh').read_text())
        self.assertNotIn('password=', service.lower())

    def test_topology_and_appliance_preserved(self):
        for name, address, memory, method in (('Web',10,4096,'Windows'),('SQL',11,4096,'Windows'),('Linux-Web',12,2048,'Linux'),('Linux-App',13,2048,'Linux')):
            self.assertRegex(HOST, r'Create-' + method + r'GuestVM\s+-VMName "OnPrem-' + name + r'" -IPAddress "192.168.0.' + str(address) + r'" -MemoryMB ' + str(memory) + r' -CPUs 2')
        for value in ('[int]$DiskGB = 30', '-VHDType Fixed', '-DynamicMemoryEnabled $false', 'linkid=2191848'):
            self.assertIn(value, HOST)
        for name in ('migrate-step3a-agentless.ps1', 'migrate-step3b-agent-based.ps1'):
            self.assertFalse((ROOT / 'scripts' / name).exists(), name)
        step3 = (ROOT / 'scripts/migrate-step3-replicate.ps1').read_text(encoding='utf-8-sig')
        groups = re.search(r'\$LabWorkloadGroups = @\{\n(.*?)\n\}', step3, re.S).group(1)
        self.assertEqual({name: re.findall(r'"([^"]+)"', values)
                          for name, values in re.findall(r'(\w+)\s*=\s*@\(([^)]+)\)', groups)},
                         {'Agentless': ['OnPrem-Web', 'OnPrem-Linux-Web'],
                          'AgentBased': ['OnPrem-SQL', 'OnPrem-Linux-App']})
        for value in ("'Agent-based' { return 'AgentBased' }", 'Resolve-LabReplicationWorkload $Workload',
                      'if ($Workload -ne "All")', '$selected -contains $_.DisplayName',
                      '$targetSnapshot = Get-LabRegionQuotaSnapshot -Location $Location',
                      '$targetRetail = Get-LabRetailSnapshot -Location $Location',
                      '$targetCandidates = @(Get-LabSizingCandidates -Skus $targetSnapshot.Skus -Usage $targetSnapshot.Usage -Location $Location)',
                      '$targetSizing = Get-LabCostTargetPlan -Candidates $targetCandidates -Usage $targetSnapshot.Usage -Retail $targetRetail -Location $Location',
                      '$Location = Resolve-LabTargetNetworkLocation -Value $Location -ResourceGroupName $TargetResourceGroup',
                      'if ($targetSelection.SelectionComplete -and $choice.Count -eq 1) { $configuration.TargetVMSize = $choice[0].Name }',
                      '[hashtable]$TargetVmSizes',
                      '$targetSelection = Select-LabTargetVmSizes -Snapshot $targetSnapshot',
                      "-MappingSupplied:($PSBoundParameters.ContainsKey('TargetVmSizes'))",
                      '[Blocked] Target VM selection unresolved',
                      "Path = 'Portal'; CanWrite = $false", "-SourceMachineType 'HyperV'",
                      'MODULE COVERAGE', 'Module 2, sections 5-7', 'Module 3, sections 8-9',
                      'Step 4 and Step 5 remain separate', 'Replication writes submitted: 0.',
                      'Replication readiness: NOT VERIFIED', "throw '[backend-contract]"):
            self.assertIn(value, step3)
        self.assertEqual(re.findall(r'(?m)^\s*TargetVMSize\s*=\s*([^\n]+)', step3), ['$null'] * 4)
        self.assertNotIn('TargetVmProfile', step3)
        self.assertNotIn('Get-LabTargetVmSizes', step3)
        workloads = step3.split('function Get-LabSizingWorkloads {', 1)[1].split('\n}', 1)[0]
        self.assertEqual(re.findall(r"DisplayName = '([^']+)'; OSType = '([^']+)'; MinimumMemoryGB = (\d+)", workloads),
                         [('OnPrem-Web', 'Windows', '4'), ('OnPrem-SQL', 'Windows', '8'),
                          ('OnPrem-Linux-Web', 'Linux', '2'), ('OnPrem-Linux-App', 'Linux', '2')])
        candidates = step3.split('function Get-LabSizingCandidates {', 1)[1].split('\n}', 1)[0]
        self.assertIn('$cores -ne 2', candidates)
        plan = step3.split('function Get-LabCostTargetPlan {', 1)[1].split('\n}', 1)[0]
        for value in ('$regional.Remaining -lt 8', '$vmCount.Remaining -lt 4',
                      '$used[$option.Family] += 2', '$used[$option.Family] -gt $quota.Remaining',
                      'Complete = ($issues.Count -eq 0 -and $selected.Count -eq 4)'):
            self.assertIn(value, plan)
        region = step3.split('function Resolve-LabTargetNetworkLocation {', 1)[1].split('\n}', 1)[0]
        self.assertIn('Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $name -ErrorAction Stop', region)
        self.assertIn('$actual = [string]$network.Location', region)
        self.assertIn('return $actual', region)
        for command in ('New-AzMigrateServerReplication', 'Get-AzMigrateServerReplication',
                        'New-AzRecoveryServicesAsrReplicationProtectedItem'):
            self.assertNotRegex(step3, r'(?m)^\s*(?:\$\w+\s*=\s*)?' + command + r'\b')
        for command in ('Start-AzMigrateTestMigration', 'Start-AzMigrateServerMigration', 'Stop-AzVM', 'Invoke-LabStage'):
            self.assertNotIn(command, step3)
        for stage, filename, module2, module3 in (
                (4, 'migrate-step4-test-migrate.ps1', 'Module 2 section 8', 'Module 3 section 10'),
                (5, 'migrate-step5-cutover.ps1', 'Module 2 section 9', 'Module 3 section 11')):
            text = (ROOT / 'scripts' / filename).read_text(encoding='utf-8-sig')
            help_text = text.split('#>', 1)[0]
            for value in ('MODULE COVERAGE', 'Manual guidance only, not automated completion', module2, module3):
                self.assertIn(value, help_text)
            guard = text.split('# BEGIN HYPERV MANUAL HANDOFF GUARD\n', 1)[1].split('# END HYPERV MANUAL HANDOFF GUARD', 1)[0]
            self.assertIn('$manualHandoff = Get-LabHyperVManualHandoff -Workload $Workload -Stage ' + str(stage), guard)
            self.assertEqual(guard.strip().splitlines()[-1],
                             "throw '[ManualActionRequired] Step " + str(stage) +
                             " Hyper-V portal action is required; no automatic stage completion or source shutdown occurred.'")
            self.assertLess(text.index('# BEGIN HYPERV MANUAL HANDOFF GUARD'), text.index('\n$context = Get-LabAzContext'))
            self.assertNotRegex(guard, r'\b(?:Get|New|Set|Start|Stop|Invoke|Remove|Connect|Import)-Az[A-Za-z]+\b')
            self.assertIn("Status = 'ManualActionRequired'; CanAutomate = $false", text)
            self.assertIn('UnspecifiedOrInvalid = @()', text)
            self.assertNotIn('$TargetVmProfile', text)
        for module, sections in (('Module-2-Agentless-Migration.md', ('## 5.', '## 6.', '## 7.', '## 8.', '## 9.')),
                                 ('Module-3-Agent-Based-Migration.md', ('## 8.', '## 9.', '## 10.', '## 11.'))):
            guidance = (ROOT / 'docs' / module).read_text()
            for section in sections:
                self.assertIn(section, guidance)
            self.assertIn('In the portal,', guidance)
            self.assertIn('**Replicate**', guidance)
            self.assertIn('**Yes, with Hyper-V**', guidance)
            self.assertNotRegex(guidance, r'\bmigrate-step[345](?:a|b)?-[\w-]+\.ps1\b')

    def test_powershell_encoding_here_strings_and_early_calls(self):
        for path in ROOT.rglob('*.ps1'):
            with self.subTest(file=path.relative_to(ROOT)):
                raw = path.read_bytes()
                text = raw.decode('utf-8-sig')
                self.assertTrue(text.isascii() or raw.startswith(b'\xef\xbb\xbf'))
                active = None
                for line in text.splitlines():
                    if active:
                        if line.startswith(active + '@'):
                            active = None
                    else:
                        match = re.search(r'@([\'\"])\s*$', line)
                        if match:
                            active = match.group(1)
                self.assertIsNone(active, 'Unterminated lexical here-string; not a PS parser test.')
        self.assertTrue(HOST.isascii())
        for text, function, call in ((DEPLOY, 'Read-LabHostConfiguration', '$hostScript = Read-LabHostConfiguration'), (HOST, 'Expand-LabTextTemplate', '$tomcatWriteFilesYaml = Expand-LabTextTemplate'), (TRAFFIC, 'Initialize-LabSshAskpass', '$script:LabAskpass = Initialize-LabSshAskpass')):
            self.assertLess(text.index('function ' + function), text.index(call))
        self.assertIn('Parser]::ParseInput($traffic', DEPLOY)
        self.assertIn('Parser]::ParseFile', (ROOT / 'scripts/check-lab-scripts.ps1').read_text(encoding='utf-8-sig'))

    def test_appliance_zip_filename_and_extraction_do_not_change_hash(self):
        work_root = ROOT / '.static-work'
        made_root = not work_root.exists()
        work = work_root / ('appliance-hash-' + uuid.uuid4().hex)
        work.mkdir(parents=True)
        try:
            original = work / 'original.zip'
            with zipfile.ZipFile(original, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
                archive.writestr('disk.vhd', b'fictional fixture, not a Microsoft image')
            digest = hashlib.sha256(original.read_bytes()).hexdigest()
            renamed = original.rename(work / 'renamed.zip')
            copied = work / 'copied.zip'
            shutil.copyfile(renamed, copied)
            self.assertEqual(hashlib.sha256(renamed.read_bytes()).hexdigest(), digest)
            self.assertEqual(hashlib.sha256(copied.read_bytes()).hexdigest(), digest)
            with zipfile.ZipFile(renamed) as archive:
                archive.extractall(work / 'extracted')
            (work / 'extracted/disk.vhd').write_bytes(b'fictional disk bytes after writes')
            self.assertEqual(hashlib.sha256(renamed.read_bytes()).hexdigest(), digest)
            changed = work / 'changed.zip'
            with zipfile.ZipFile(changed, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
                archive.writestr('different-name.vhd', b'fictional fixture, not a Microsoft image')
            self.assertNotEqual(hashlib.sha256(changed.read_bytes()).hexdigest(), digest)
        finally:
            shutil.rmtree(work)
            if made_root:
                work_root.rmdir()

    def test_appliance_docs_stop_before_extract_and_no_expansion(self):
        doc = (ROOT / 'docs/Module-1-Discovery.md').read_text()
        section = doc.split('### 2.1 ', 1)[1].split('### 2.2 ', 1)[0]
        for forbidden in ('Select-Object -First 1', 'Resize-VHD', 'Resize-Partition', 'New-VM -Name', 'HyperVHost\\labadmin'):
            self.assertNotIn(forbidden, doc)
        self.assertLess(section.index('Get-FileHash -LiteralPath $archive -Algorithm SHA256'),
                        section.index('If they differ, stop: do not extract, import, or bypass verification.'))
        self.assertLess(section.index('If they differ, stop: do not extract, import, or bypass verification.'),
                        section.index('Only after the hash matches, extract'))
        for value in ('File Explorer', 'actual full filename', 'Copy the virtual machine (create a new unique ID)',
                      'Generation 1 appliance', 'eight virtual processors', '16 GB static memory',
                      'ApplianceStore', 'Do not resize the disk, expand its partition, or rebuild the VM',
                      '192.168.0.20'):
            self.assertIn(value, doc)
        self.assertIn('roughly 80 GB', doc)
        self.assertNotIn('published VHD arrives at about 40 GB', (ROOT / 'docs/Module-0-Setup.md').read_text())

    def test_appliance_deployment_fresh_hash_not_cached_success(self):
        block = DEPLOY.split('# Rehash the actual ZIP:', 1)[1].split('} else {\n        Write-Host "Download', 1)[0]
        for value in ('Get-FileHash -LiteralPath $item.FullName', 'RecordedSha256=$recorded', 'Bytes=$item.Length',
                      '$full.StartsWith($prefix', '$stagedHash -eq $ApplianceVhdSha256.ToUpperInvariant()',
                      'Historical record: MISMATCH', 'Fresh ZIP comparison against the supplied hash: MISMATCH'):
            self.assertIn(value, block)
        self.assertNotIn('Source', block)
        stage = HOST.split("$zip = Join-Path $Root 'MigrateAppl.zip'", 1)[1].split('-ArgumentList $applianceRoot', 1)[0]
        self.assertNotIn('ALREADY_PRESENT', stage)
        self.assertIn('Get-FileHash -LiteralPath $recordedZip', stage)
        self.assertLess(stage.index('if ($ExpectedSha256 -and $hash -ne'), stage.index('Expand-Archive -LiteralPath'))
        self.assertNotIn('Remove-Item -LiteralPath $zip', stage)
        self.assertIn('ExtractionFiles = $extractionFiles', stage)
        self.assertIn("$IncludeApplianceVhd = 'No'", DEPLOY)
        self.assertIn("Read-Host 'Yes or No [No]'", DEPLOY)

    def test_appliance_worker_strict_selection_extraction_and_copy_import(self):
        step = (ROOT / 'scripts/migrate-step2-discover-assess.ps1').read_text(encoding='utf-8-sig')
        worker = step.split("    $worker = @'", 1)[1].split("\n'@", 1)[0]
        imported = step.split("    $importScript = @'", 1)[1].split("\n'@", 1)[0]
        for forbidden in ('Resize-VHD', 'Resize-Partition', "'SKIP'", 'New-VM -Name'):
            self.assertNotIn(forbidden, step)
        for forbidden in ('Select-Object -First 1', 'Remove-Item -LiteralPath $extracted', 'Remove-Item -LiteralPath $archive'):
            self.assertNotIn(forbidden, worker + imported)
        self.assertIn('$candidates.Count -gt 1', worker)
        self.assertIn('Get-StoreFile ([string]$record.Archive)', worker)
        self.assertLess(worker.index('if ($actual -ne $Sha256.ToUpperInvariant())'), worker.index('ExtractToDirectory'))
        self.assertIn('$record.ExtractionFiles', worker)
        self.assertIn('Get-VM | Get-VMHardDiskDrive', worker)
        for value in ('Compare-VM -Path $configs[0].FullName -Copy -GenerateNewId', '-VhdDestinationPath $diskPath',
                      '-VirtualMachinePath $vmPath', '-SnapshotFilePath $checkpointPath', '-SmartPagingFilePath $pagingPath',
                      'Import-VM -CompatibilityReport $report', 'Rename-VM -VM $vm -NewName $vmName',
                      '$copyBytes + 10GB', '$disk.Size -lt 80GB', 'DHCP reservation conflict'):
            self.assertIn(value, imported)
        self.assertLess(imported.index('Rename-VM'), imported.index('Start-VM'))
        self.assertLess(imported.index('StaticMacAddress'), imported.index('Start-VM'))
        self.assertNotIn('Remove-Item', imported)
        self.assertIn('source ZIP/extracted bytes are NOT verified', step)

    def test_baseline_exact_diff_manifest(self):
        manifest = json.loads((ROOT / 'tests/baseline-manifest.json').read_text())
        omitted_names = {'scripts/check-lab-scripts.092426.txt',
                         'scripts/migrate-step3a-agentless.ps1', 'scripts/migrate-step3b-agent-based.ps1'}
        self.assertEqual({name for name, entry in manifest['baseline_files'].items() if entry['status'] == 'omitted'},
                         omitted_names)
        self.assertEqual(manifest['baseline_file_count'], 24)
        current_baseline_files = set()
        for name, entry in manifest['baseline_files'].items():
            self.assertRegex(entry['baseline_sha256'], r'^[0-9a-f]{64}$')
            current_name = entry.get('current_path', name)
            path = ROOT / current_name
            if entry['status'] == 'renamed':
                self.assertEqual((name, current_name), ('CHANGES.md', 'VersionNotes.md'))
                self.assertFalse((ROOT / name).exists())
            else:
                self.assertNotIn('current_path', entry, name)
            if entry['status'] == 'omitted':
                self.assertIn(name, omitted_names)
                self.assertFalse(path.exists())
                self.assertIsNone(entry['current_sha256'])
                self.assertIsInstance(entry.get('reason'), str)
                self.assertTrue(entry['reason'].strip())
            else:
                self.assertNotIn(current_name, current_baseline_files)
                current_baseline_files.add(current_name)
                actual = hashlib.sha256(path.read_bytes()).hexdigest()
                self.assertEqual(actual, entry['current_sha256'], name)
                if entry['status'] != 'renamed':
                    self.assertEqual(actual == entry['baseline_sha256'], entry['status'] == 'unchanged', name)
        self.assertEqual(len(manifest['baseline_files']), manifest['baseline_file_count'])
        actual_files = {path.relative_to(ROOT).as_posix() for path in ROOT.rglob('*') if path.is_file()
                        and not any(part in ('__pycache__', '.static-work') for part in path.relative_to(ROOT).parts)}
        self.assertEqual(actual_files - current_baseline_files, set(manifest['added_files']))
        self.assertEqual(manifest['baseline_files']['scripts/health.ps1']['status'], 'unchanged')
        self.assertEqual(hashlib.sha256((ROOT / 'docs/Module-4-ASR-Comparison.md').read_bytes()).hexdigest(),
                         '09b51fb54fa022f0c64fe0a6b4766c742f0f4c2a7891995aa0b5029afe065bbf')
        previous = manifest['previous_revision_files']
        self.assertEqual(manifest['previous_revision_file_count'], 60)
        self.assertEqual({entry.get('current_path', name) for name, entry in previous.items()
                          if entry['status'] != 'omitted'}, actual_files)
        self.assertEqual({name for name, entry in previous.items() if entry['status'] == 'omitted'},
                         omitted_names - {'scripts/check-lab-scripts.092426.txt'})
        for name, entry in previous.items():
            current_name = entry.get('current_path', name)
            if entry['status'] == 'renamed':
                self.assertEqual((name, current_name), ('CHANGES.md', 'VersionNotes.md'))
                self.assertFalse((ROOT / name).exists())
            else:
                self.assertNotIn('current_path', entry, name)
            if entry['status'] == 'omitted':
                self.assertIn(name, omitted_names)
                self.assertFalse((ROOT / current_name).exists())
                self.assertIsNone(entry['current_sha256'])
                self.assertIsInstance(entry.get('reason'), str)
                self.assertTrue(entry['reason'].strip())
                continue
            if name in ('SHA256SUMS', 'tests/baseline-manifest.json'):
                self.assertIsNone(entry['current_sha256'])
                continue
            actual = hashlib.sha256((ROOT / current_name).read_bytes()).hexdigest()
            self.assertEqual(actual, entry['current_sha256'], name)
            if entry['status'] != 'renamed':
                self.assertEqual(actual == entry['previous_sha256'], entry['status'] == 'unchanged', name)

    def test_document_links_and_no_personal_workspace_pointers(self):
        for path in ROOT.rglob('*.md'):
            text = path.read_text()
            self.assertNotRegex(text, r'(?i)/mnt/(?:workspace|data)|LAB_BASELINE_DIR|personal account override|resume in the same')
            self.assertNotIn('Fresh baseline provisioning remains Node', text)
            for link in re.findall(r'(?<!!)\[[^\]]*\]\(([^\s)]+)\)', text):
                target = link.split('#', 1)[0]
                if not target or '://' in target or target.startswith('mailto:') or target.startswith('<'):
                    continue
                self.assertTrue((path.parent / target).exists(), str(path.relative_to(ROOT)) + ': ' + target)


if __name__ == '__main__':
    unittest.main(verbosity=2)
