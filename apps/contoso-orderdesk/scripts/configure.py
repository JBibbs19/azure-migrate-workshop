#!/usr/bin/env python3
"""Build target-only Tomcat configuration. SQL password is never a CLI argument."""
import argparse
import getpass
import grp
import json
import os
import pwd
import shutil
import stat
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

BASE = Path('/var/lib/contoso-orderdesk')
GROUP = 'contoso-orderdesk'


def real_directory(path):
    for component in (*reversed(path.parents), path):
        if not stat.S_ISDIR(component.lstat().st_mode):
            raise RuntimeError('Configuration path must contain only real directories: ' + str(component))


def runtime_readable(path):
    if os.geteuid() == pwd.getpwnam(GROUP).pw_uid:
        readable = os.access(path, os.R_OK, effective_ids=True)
    else:
        readable = subprocess.run(['/usr/sbin/runuser', '--user', GROUP, '--', '/usr/bin/test', '-r', str(path)],
                                  check=False).returncode == 0
    if not readable:
        raise RuntimeError('Tomcat configuration is not readable by the runtime account: ' + str(path))


def tomcat_home_conf(home=Path('/usr/share/tomcat10')):
    """Fresh deployment only: expose the one public server XML, never private JNDI."""
    source = BASE / 'conf/server.xml'
    if not home.is_absolute() or not source.is_absolute() or '..' in (*home.parts, *source.parts):
        raise RuntimeError('Tomcat configuration paths must be absolute and normalized.')
    real_directory(source.parent)
    real_directory(home)
    source_metadata = source.lstat()
    if not stat.S_ISREG(source_metadata.st_mode) or not os.access(source, os.R_OK, effective_ids=True):
        raise RuntimeError('Canonical server.xml must be a readable regular file, not a link.')
    conf = home / 'conf'
    destination = conf / 'server.xml'
    if os.path.lexists(conf):
        real_directory(conf)
    if os.path.lexists(destination):
        if not destination.is_symlink() or os.readlink(destination) != str(source):
            raise RuntimeError('Refusing occupied Tomcat HOME server.xml; nothing was replaced.')
    else:
        if not os.path.lexists(conf):
            conf.mkdir(mode=0o755)
            os.chown(conf, 0, 0)
            os.chmod(conf, 0o755)
        destination.symlink_to(source)
    if (os.readlink(destination) != str(source) or destination.resolve(strict=True) != source or
            not os.path.samestat(destination.stat(), source_metadata)):
        raise RuntimeError('Tomcat HOME server.xml does not resolve to the canonical configuration.')
    runtime_readable(destination)
    print('Tomcat HOME server.xml alias verified locally; appliance discovery remains pending.')


def write_xml(path, element, private=False):
    ET.indent(element, space='  ')
    content = ET.tostring(element, encoding='utf-8', xml_declaration=True) + b'\n'
    # Ensure the credentials descriptor is protected even while it is first created.
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o640 if private else 0o644)
    with os.fdopen(fd, 'wb') as handle:
        handle.write(content)
    os.chmod(path, 0o640 if private else 0o644)
    os.chown(path, 0, grp.getgrnam(GROUP).gr_gid)


def server(port):
    root = ET.Element('Server', port='-1')
    ET.SubElement(root, 'Listener', className='org.apache.catalina.core.JreMemoryLeakPreventionListener')
    service = ET.SubElement(root, 'Service', name='Catalina')
    ET.SubElement(service, 'Connector', port=str(port), address='0.0.0.0', protocol='HTTP/1.1',
                  connectionTimeout='15000', maxThreads='25', minSpareThreads='3',
                  maxConnections='100', acceptCount='25', maxPostSize='4096', maxParameterCount='10',
                  maxSwallowSize='4096', URIEncoding='UTF-8', server='ContosoOrderDesk')
    engine = ET.SubElement(service, 'Engine', name='Catalina', defaultHost='localhost')
    host = ET.SubElement(engine, 'Host', name='localhost', appBase='webapps',
                         unpackWARs='false', autoDeploy='false', deployOnStartup='true')
    ET.SubElement(host, 'Valve', className='org.apache.catalina.valves.ErrorReportValve',
                  showReport='false', showServerInfo='false')
    write_xml(BASE / 'conf/server.xml', root)


def database(force=False, password_file=None):
    path = BASE / 'conf/Catalina/localhost/ROOT.xml'
    if path.exists() and not force:
        print('Keeping existing private JNDI credentials descriptor.')
        return
    if password_file is not None:
        seed = Path(password_file)
        metadata = seed.lstat()
        if not seed.is_file() or seed.is_symlink() or metadata.st_uid != 0 or metadata.st_mode & 0o077:
            raise RuntimeError('Unattended password seed must be a root-owned regular file, mode 0600 or stricter.')
        password = json.loads(seed.read_text())
        if not isinstance(password, str) or not password:
            raise RuntimeError('Unattended password seed is empty or invalid.')
    else:
        if not sys.stdin.isatty():
            raise RuntimeError('Use an interactive sudo session (ssh -t); credentials are prompted, never passed as arguments.')
        password = getpass.getpass('SQL labapp password (the same lab password; input hidden): ')
        confirm = getpass.getpass('Confirm SQL labapp password: ')
        if not password or password != confirm:
            raise RuntimeError('Passwords empty or do not match; no credentials file written.')
    context = ET.Element('Context')
    ET.SubElement(context, 'Resource', name='jdbc/ContosoApp', auth='Container',
                  type='javax.sql.DataSource', factory='org.apache.tomcat.jdbc.pool.DataSourceFactory',
                  driverClassName='com.microsoft.sqlserver.jdbc.SQLServerDriver',
                  url='jdbc:sqlserver://onprem-sql:1433;databaseName=ContosoApp;encrypt=true;trustServerCertificate=true;loginTimeout=5;socketTimeout=10000;applicationName=Contoso Order Desk',
                  username='labapp', password=password,
                  initialSize='1', minIdle='1', maxIdle='2', maxActive='4', maxWait='5000',
                  testOnBorrow='true', validationQuery='SELECT 1', validationQueryTimeout='3',
                  validationInterval='20000', timeBetweenEvictionRunsMillis='30000',
                  minEvictableIdleTimeMillis='600000', removeAbandoned='true', removeAbandonedTimeout='60',
                  logAbandoned='false', jmxEnabled='false', defaultAutoCommit='true')
    write_xml(path, context, private=True)
    print('Protected JNDI descriptor written (root/runtime group only).')


def initialise(bundle, port=3001, password_file=None):
    bundle = Path(bundle)
    for name in ('conf/Catalina/localhost', 'lib', 'webapps', 'logs', 'work', 'temp'):
        (BASE / name).mkdir(parents=True, exist_ok=True)
    server(port)
    global_web = Path('/etc/tomcat10/web.xml')
    if not global_web.is_file():
        raise RuntimeError('Ubuntu Tomcat default web.xml is missing; JSP runtime cannot be configured.')
    shutil.copyfile(global_web, BASE / 'conf/web.xml')
    (BASE / 'conf/catalina.properties').write_text(
        'common.loader="${catalina.base}/lib","${catalina.base}/lib/*.jar","${catalina.home}/lib","${catalina.home}/lib/*.jar"\n'
        'server.loader=\nshared.loader=\n')
    (BASE / 'conf/logging.properties').write_text(
        'handlers = java.util.logging.ConsoleHandler\n'
        '.handlers = java.util.logging.ConsoleHandler\n'
        '.level = INFO\njava.util.logging.ConsoleHandler.level = INFO\n'
        'java.util.logging.ConsoleHandler.formatter = java.util.logging.SimpleFormatter\n')
    shutil.copyfile(bundle / 'dist/contoso-orderdesk.war', BASE / 'webapps/ROOT.war')
    os.chmod(BASE / 'webapps/ROOT.war', 0o644)
    database(password_file=password_file)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=('init', 'port', 'db', 'traffic', 'home-conf'))
    parser.add_argument('--bundle')
    parser.add_argument('--password-file', help='Root-only JSON seed for initial provisioning; never supply a password argument.')
    parser.add_argument('--port', type=int, choices=(3000, 3001))
    parser.add_argument('--interval', type=int, default=30)
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise SystemExit('Run with sudo.')
    if args.action == 'init':
        initialise(args.bundle, args.port or 3001, args.password_file)
    elif args.action == 'port':
        server(args.port)
    elif args.action == 'db':
        database(force=True)
    elif args.action == 'home-conf':
        tomcat_home_conf()
    else:
        if not 20 <= args.interval <= 600:
            raise SystemExit('Traffic interval must be 20 to 600 seconds.')
        path = Path('/etc/contoso-orderdesk-traffic.json')
        path.write_text(json.dumps({'baseUrl': 'http://onprem-nginx:8080', 'intervalSeconds': args.interval}) + '\n')
        os.chmod(path, 0o644)
