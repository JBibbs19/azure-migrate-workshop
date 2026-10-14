#!/usr/bin/env python3
"""One-time, root-private backup of affected files and service running/enablement state."""
import argparse
import json
import os
import shutil
import stat
import subprocess
from pathlib import Path

APP_PATHS = ('/etc/hosts', '/etc/systemd/system/contoso-app.service',
             '/etc/systemd/system/lab-traffic.service', '/etc/lab-traffic.env',
             '/opt/contoso-app/lab-traffic.js')
APP_SERVICES = ('contoso-app.service', 'lab-traffic.service', 'tomcat10.service')
PROXY_PATHS = ('/etc/hosts', '/etc/nginx/conf.d/lab-order-desk.conf')


def state(unit, operation):
    completed = subprocess.run(['systemctl', operation, unit], capture_output=True, text=True, check=False)
    return (completed.stdout.strip() or 'not-found').splitlines()[0]


def save(folder, proxy=False):
    folder = Path(folder)
    if folder.exists():
        if not (folder / 'complete').is_file():
            raise RuntimeError('Incomplete snapshot exists; inspect it, do not overwrite it.')
        print('Keeping original rollback snapshot.')
        return
    folder.mkdir(mode=0o700, parents=True)
    os.chmod(folder, 0o700)
    records = []
    for index, name in enumerate(PROXY_PATHS if proxy else APP_PATHS):
        path = Path(name)
        record = {'path': name, 'exists': path.exists() or path.is_symlink()}
        if record['exists']:
            metadata = path.lstat()
            if not stat.S_ISREG(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode):
                raise RuntimeError('Refusing backup of a non-file lab path: ' + name)
            record.update(uid=metadata.st_uid, gid=metadata.st_gid, mode=stat.S_IMODE(metadata.st_mode))
            if path.is_symlink():
                record['symlink'] = os.readlink(path)
            else:
                record['copy'] = 'file-' + str(index)
                shutil.copy2(path, folder / record['copy'])
        records.append(record)
    units = [] if proxy else APP_SERVICES
    services = [{'unit': unit, 'enabled': state(unit, 'is-enabled'), 'active': state(unit, 'is-active')} for unit in units]
    (folder / 'manifest.json').write_text(json.dumps({'paths': records, 'services': services}, indent=2) + '\n')
    (folder / 'complete').write_text('Original snapshot; never reset on installer reruns.\n')


def restore_files(folder):
    folder = Path(folder)
    if not (folder / 'complete').is_file():
        raise RuntimeError('No complete rollback snapshot.')
    manifest = json.loads((folder / 'manifest.json').read_text())
    for record in manifest['paths']:
        path = Path(record['path'])
        if path.is_symlink():
            path.unlink()
        if not record['exists']:
            if path.exists():
                path.unlink()
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        if 'symlink' in record:
            if path.exists():
                path.unlink()
            path.symlink_to(record['symlink'])
            os.lchown(path, record['uid'], record['gid'])
        else:
            shutil.copyfile(folder / record['copy'], path)
            os.chmod(path, record['mode'])
            os.chown(path, record['uid'], record['gid'])


def restore_services(folder):
    manifest = json.loads((Path(folder) / 'manifest.json').read_text())
    for service in manifest['services']:
        unit, enabled = service['unit'], service['enabled']
        if state(unit, 'is-enabled') == 'not-found':
            continue
        subprocess.run(['systemctl', 'unmask', unit], check=True, stdout=subprocess.DEVNULL)
        if enabled in ('enabled', 'enabled-runtime'):
            arguments = ['systemctl', 'enable']
            if enabled == 'enabled-runtime':
                arguments.append('--runtime')
            subprocess.run(arguments + [unit], check=True, stdout=subprocess.DEVNULL)
        elif enabled == 'masked' or enabled == 'masked-runtime':
            subprocess.run(['systemctl', 'disable', unit], check=True, stdout=subprocess.DEVNULL)
            arguments = ['systemctl', 'mask']
            if enabled == 'masked-runtime':
                arguments.append('--runtime')
            subprocess.run(arguments + [unit], check=True, stdout=subprocess.DEVNULL)
        elif enabled in ('disabled', 'not-found'):
            subprocess.run(['systemctl', 'disable', unit], check=True, stdout=subprocess.DEVNULL)
        if service['active'] == 'active':
            subprocess.run(['systemctl', 'start', unit], check=True)
        else:
            subprocess.run(['systemctl', 'stop', unit], check=True)
        if service['active'] == 'active' and state(unit, 'is-active') != 'active':
            raise RuntimeError('Original active service did not restart: ' + unit)
        if enabled in ('enabled', 'disabled', 'masked', 'enabled-runtime', 'masked-runtime') and state(unit, 'is-enabled') != enabled:
            raise RuntimeError('Original service enablement was not restored: ' + unit)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=('save', 'restore-files', 'restore-services', 'show'))
    parser.add_argument('folder')
    parser.add_argument('--proxy', action='store_true')
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise SystemExit('Run with sudo.')
    if args.action == 'save':
        save(args.folder, args.proxy)
    elif args.action == 'restore-files':
        restore_files(args.folder)
    elif args.action == 'restore-services':
        restore_services(args.folder)
    else:
        print((Path(args.folder) / 'manifest.json').read_text())
