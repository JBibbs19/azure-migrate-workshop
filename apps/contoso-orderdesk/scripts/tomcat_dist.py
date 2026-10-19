#!/usr/bin/env python3
"""Fresh-only pinned Apache distribution acquisition; publisher checksum, not PGP verification."""
import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import tarfile
import zipfile

VERSION = '10.1.61'
TOP = 'apache-tomcat-' + VERSION
ARCHIVE = TOP + '.tar.gz'
SOURCES = (
    'https://archive.apache.org/dist/tomcat/tomcat-10/v' + VERSION + '/bin/',
    'https://downloads.apache.org/tomcat/tomcat-10/v' + VERSION + '/bin/',
)
MAX_DOWNLOAD = 32 * 1024 * 1024
MAX_MEMBERS = 20000
MAX_FILE = 64 * 1024 * 1024
MAX_EXPANDED = 256 * 1024 * 1024
FACTORY = 'org/apache/tomcat/jdbc/pool/DataSourceFactory.class'
REQUIRED = ('LICENSE', 'NOTICE', 'bin/catalina.sh', 'bin/bootstrap.jar', 'bin/tomcat-juli.jar',
            'conf/server.xml', 'conf/web.xml', 'conf/context.xml', 'conf/catalina.properties',
            'lib/catalina.jar', 'lib/tomcat-jdbc.jar', 'lib/jasper.jar')


def real_directories(path):
    if not path.is_absolute() or '..' in path.parts:
        raise ValueError('Destination must be an absolute normalized path.')
    for component in (*reversed(path.parents), path):
        if not stat.S_ISDIR(component.lstat().st_mode):
            raise ValueError('Only real directories are permitted: ' + str(component))


def absent_destination(destination):
    real_directories(destination.parent)
    if os.path.lexists(destination):
        raise FileExistsError('Fresh Tomcat destination is occupied; refusing overwrite: ' + str(destination))


def parse_checksum(data):
    if not 128 <= len(data) <= 1024:
        raise ValueError('Publisher SHA512 response size is invalid.')
    text = data.decode('ascii').strip()
    filename = re.escape(ARCHIVE)
    match = re.fullmatch(r'([0-9a-fA-F]{128})(?:[ \t]+\*?' + filename + r')?', text)
    if match:
        return match.group(1).lower()
    match = re.fullmatch(r'SHA512 \(' + filename + r'\) = ([0-9a-fA-F]{128})', text)
    if match:
        return match.group(1).lower()
    raise ValueError('Publisher SHA512 must be exactly 128 hex digits for the pinned archive filename.')


def download(url, destination, limit):
    if not url.startswith(SOURCES) or not url.endswith((ARCHIVE, ARCHIVE + '.sha512')):
        raise ValueError('Only the pinned official HTTPS publisher coordinates are allowed.')
    result = subprocess.run([
        'curl', '--proto', '=https', '--proto-redir', '=https', '--tlsv1.2',
        '--location', '--max-redirs', '3', '--fail', '--silent', '--show-error',
        '--connect-timeout', '15', '--max-time', '180', '--retry', '2',
        '--retry-delay', '5', '--retry-max-time', '360', '--max-filesize', str(limit),
        '--output', str(destination), url,
    ], timeout=550, check=False)
    if result.returncode or not destination.is_file() or destination.stat().st_size > limit:
        destination.unlink(missing_ok=True)
        raise RuntimeError('Bounded pinned publisher download failed: ' + url)


def inspect_jars(read):
    with zipfile.ZipFile(io.BytesIO(read('lib/tomcat-jdbc.jar'))) as jar:
        if jar.testzip() is not None or FACTORY not in jar.namelist():
            raise ValueError('Standalone Tomcat distribution lacks the exact JDBC pool DataSourceFactory class.')
    with zipfile.ZipFile(io.BytesIO(read('lib/catalina.jar'))) as jar:
        if jar.testzip() is not None:
            raise ValueError('Tomcat catalina.jar CRC failure.')
        info = jar.read('org/apache/catalina/util/ServerInfo.properties').decode('iso-8859-1')
        if not re.search(r'^server.info=Apache Tomcat/' + re.escape(VERSION) + r'\s*$', info, re.M):
            raise ValueError('Tomcat runtime version does not match the pinned distribution.')


def validated_members(archive):
    members = {}
    total = 0
    for member in archive:
        if len(members) >= MAX_MEMBERS:
            raise ValueError('Tomcat archive member limit exceeded.')
        raw = member.name[:-1] if member.isdir() and member.name.endswith('/') else member.name
        parts = PurePosixPath(raw).parts
        if (not raw or '\\' in raw or any(ord(c) < 32 or ord(c) == 127 for c in raw) or raw.startswith('/') or
                any(part in ('', '.', '..') for part in raw.split('/')) or
                not parts or parts[0] != TOP or '/'.join(parts) != raw):
            raise ValueError('Unsafe or unexpected Tomcat archive path: ' + member.name)
        if raw in members or not (member.isdir() or member.isreg()):
            raise ValueError('Duplicate path or unsupported archive type (including all links): ' + raw)
        if (member.size < 0 or member.size > MAX_FILE or (member.isdir() and member.size != 0) or
                getattr(member, 'sparse', None)):
            raise ValueError('Invalid or excessive Tomcat archive member size/type.')
        total += member.size
        if total > MAX_EXPANDED:
            raise ValueError('Tomcat expanded archive size limit exceeded.')
        members[raw] = member
    for raw, member in members.items():
        for parent in PurePosixPath(raw).parents:
            if str(parent) in members and not members[str(parent)].isdir():
                raise ValueError('Tomcat archive file/directory collision.')
    for name in REQUIRED:
        member = members.get(TOP + '/' + name)
        if member is None or not member.isreg():
            raise ValueError('Required standalone distribution file missing: ' + name)
    inspect_jars(lambda name: archive.extractfile(members[TOP + '/' + name]).read())
    return members


def bounded_tar(archive_path):
    expanded = io.BytesIO()
    try:
        with gzip.open(archive_path, 'rb') as source:
            while True:
                block = source.read(1024 * 1024)
                if not block:
                    break
                if expanded.tell() + len(block) > MAX_EXPANDED:
                    raise ValueError('Tomcat total uncompressed tar size limit exceeded (including metadata).')
                expanded.write(block)
        expanded.seek(0)
        return expanded
    except Exception:
        expanded.close()
        raise


def extract_verified(archive_path, checksum, destination):
    absent_destination(destination)
    metadata = archive_path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > MAX_DOWNLOAD:
        raise ValueError('Tomcat download is not a bounded regular archive file.')
    if not re.fullmatch('[0-9a-f]{128}', checksum):
        raise ValueError('Invalid expected publisher SHA512.')
    if hashlib.sha512(archive_path.read_bytes()).hexdigest() != checksum:
        raise ValueError('Pinned Tomcat publisher SHA512 mismatch; no extraction performed.')
    with bounded_tar(archive_path) as expanded, tarfile.open(fileobj=expanded, mode='r:') as archive:
        members = validated_members(archive)
        # Validate every member before creating the new tree; never follow or restore archive links/owners/modes.
        destination.mkdir(mode=0o755)
        for raw, member in sorted(members.items()):
            relative = PurePosixPath(raw).relative_to(TOP)
            if not relative.parts or (relative.parts[0] == 'webapps' and len(relative.parts) > 1):
                continue
            target = destination.joinpath(*relative.parts)
            target.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
            if member.isdir():
                target.mkdir(exist_ok=True, mode=0o755)
            else:
                with archive.extractfile(member) as source, target.open('xb') as output:
                    shutil.copyfileobj(source, output, length=1024 * 1024)
                target.chmod(0o755 if relative.parts[0] == 'bin' and target.suffix == '.sh' else 0o644)
        for name in ('webapps', 'logs', 'work', 'temp'):
            (destination / name).mkdir(exist_ok=True, mode=0o755)
        for path in (destination, *destination.rglob('*')):
            if path.is_dir():
                path.chmod(0o755)
        verify_layout(destination)


def verify_layout(destination):
    real_directories(destination)
    for name in REQUIRED:
        path = destination / name
        real_directories(path.parent)
        if not stat.S_ISREG(path.lstat().st_mode):
            raise ValueError('Required Tomcat runtime path must be a regular file: ' + str(path))
    inspect_jars(lambda name: (destination / name).read_bytes())
    if not os.access(destination / 'bin/catalina.sh', os.X_OK):
        raise ValueError('Tomcat launch script is not executable.')


def acquire(destination, staging, receipt):
    absent_destination(destination)
    real_directories(staging.parent)
    real_directories(receipt.parent)
    if os.path.lexists(receipt):
        raise FileExistsError('Fresh publisher receipt path is occupied; refusing overwrite.')
    staging.mkdir(mode=0o700, exist_ok=False)
    checksum = None
    checksum_url = None
    try:
        for base in SOURCES:
            try:
                download(base + ARCHIVE + '.sha512', staging / 'publisher.sha512', 1024)
                checksum = parse_checksum((staging / 'publisher.sha512').read_bytes())
                checksum_url = base + ARCHIVE + '.sha512'
                break
            except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired):
                continue
        if checksum is None:
            raise RuntimeError('Pinned official publisher SHA512 unavailable/invalid; fresh install stopped before extraction.')
        for base in SOURCES:
            try:
                download(base + ARCHIVE, staging / ARCHIVE, MAX_DOWNLOAD)
            except (OSError, RuntimeError, subprocess.TimeoutExpired):
                continue
            # A checksum mismatch is terminal, not a reason to trust a different checksum or release.
            extract_verified(staging / ARCHIVE, checksum, destination)
            with receipt.open('x', encoding='utf-8') as output:
                json.dump({'version': VERSION, 'archiveUrl': base + ARCHIVE, 'sha512Url': checksum_url,
                           'publisherSha512': checksum,
                           'assurance': 'Official publisher SHA512 retrieved over HTTPS; no independent PGP verification.'},
                          output, indent=2)
                output.write('\n')
            receipt.chmod(0o644)
            print('Pinned Apache Tomcat ' + VERSION + ' publisher SHA512 verified; standalone layout installed.')
            return
        raise RuntimeError('Pinned Apache distribution unavailable from official same-version sources; fresh install stopped.')
    finally:
        shutil.rmtree(staging)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('install', 'verify'))
    parser.add_argument('--destination', type=Path, default=Path('/opt/tomcat'))
    parser.add_argument('--staging', type=Path)
    parser.add_argument('--receipt', type=Path)
    args = parser.parse_args()
    if args.action == 'verify':
        verify_layout(args.destination)
    else:
        if os.geteuid() != 0 or args.staging is None or args.receipt is None:
            parser.error('Fresh installation requires root and explicit owned staging/receipt paths.')
        acquire(args.destination, args.staging, args.receipt)
