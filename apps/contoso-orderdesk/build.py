#!/usr/bin/env python3
"""Reproducible JSP WAR and delivery ZIP using Python standard library only."""
import argparse
import hashlib
import stat
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def zip_entry(archive, name, data, executable=False):
    info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    info.create_system = 3
    info.external_attr = (stat.S_IFREG | (0o755 if executable else 0o644)) << 16
    info.compress_type = zipfile.ZIP_DEFLATED
    archive.writestr(info, data)


def package_files():
    return sorted(path for path in ROOT.rglob('*') if path.is_file() and
                  not any(part in ('__pycache__', '.static-work') for part in path.relative_to(ROOT).parts) and
                  (path.suffix not in ('.pyc', '.zip') or path.relative_to(ROOT).as_posix() == 'dist/runtime.zip') and
                  path.name != 'SHA256SUMS')


def build_war():
    target = ROOT / 'dist/contoso-orderdesk.war'
    webapp = ROOT / 'src/main/webapp'
    with zipfile.ZipFile(target, 'w') as archive:
        zip_entry(archive, 'META-INF/MANIFEST.MF',
                  b'Manifest-Version: 1.0\r\nImplementation-Title: Contoso Order Desk\r\nImplementation-Version: 1.0.0\r\n\r\n')
        for path in sorted(webapp.rglob('*')):
            if path.is_file():
                zip_entry(archive, path.relative_to(webapp).as_posix(), path.read_bytes())
    with zipfile.ZipFile(target) as archive:
        if archive.testzip() is not None:
            raise RuntimeError('WAR integrity check failed')
    print('Built dist/contoso-orderdesk.war (JSP compilation happens on Tomcat, not here).')


def build_runtime():
    selected = ['check.py', 'common.sh', 'configure.py', 'driver_check.py', 'hosts.py',
                'install-fresh.sh', 'contoso-orderdesk.service.in', 'contoso-orderdesk-traffic.service',
                'traffic.py', 'traffic.sh', 'repoint.sh', 'validate.sh']
    files = {'dist/contoso-orderdesk.war': (ROOT / 'dist/contoso-orderdesk.war').read_bytes()}
    files.update({'scripts/' + name: (ROOT / 'scripts' / name).read_bytes() for name in selected})
    sums = ''.join(hashlib.sha256(data).hexdigest() + '  ' + name + '\n' for name, data in sorted(files.items()))
    target = ROOT / 'dist/runtime.zip'
    with zipfile.ZipFile(target, 'w') as archive:
        for name, data in sorted(files.items()):
            zip_entry(archive, name, data, name.endswith('.sh'))
        zip_entry(archive, 'RUNTIME-SHA256SUMS', sums.encode())
    with zipfile.ZipFile(target) as archive:
        if archive.testzip() is not None:
            raise RuntimeError('Runtime ZIP CRC failure')
    (ROOT / 'dist/runtime.sha256').write_text(hashlib.sha256(target.read_bytes()).hexdigest() + '\n')
    print('Built dist/runtime.zip with WAR and minimal target scripts; no docs, secrets or driver.')


def checksums():
    lines = [hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + path.relative_to(ROOT).as_posix()
             for path in package_files()]
    (ROOT / 'SHA256SUMS').write_text('\n'.join(lines) + '\n')


def delivery_zip(destination):
    destination = Path(destination).resolve()
    if ROOT in destination.parents:
        raise ValueError('Place delivery ZIP beside the package, not inside it.')
    destination.parent.mkdir(parents=True, exist_ok=True)
    checksums()
    with zipfile.ZipFile(destination, 'w') as archive:
        for path in package_files() + [ROOT / 'SHA256SUMS']:
            zip_entry(archive, path.relative_to(ROOT).as_posix(), path.read_bytes(), path.suffix == '.sh')
    with zipfile.ZipFile(destination) as archive:
        if archive.testzip() is not None:
            raise RuntimeError('Delivery archive integrity check failed')
        for line in archive.read('SHA256SUMS').decode().splitlines():
            expected, name = line.split('  ', 1)
            if hashlib.sha256(archive.read(name)).hexdigest() != expected:
                raise RuntimeError('Delivery checksum mismatch: ' + name)
    print('Verified delivery ZIP: ' + str(destination))
    print('ZIP SHA256: ' + hashlib.sha256(destination.read_bytes()).hexdigest())


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=('war', 'runtime', 'checksums', 'zip'))
    parser.add_argument('--output')
    args = parser.parse_args()
    if args.action == 'war':
        build_war()
    elif args.action == 'runtime':
        build_runtime()
    elif args.action == 'checksums':
        checksums()
    elif not args.output:
        parser.error('--output is required for zip')
    else:
        delivery_zip(args.output)
