#!/usr/bin/env python3
"""Package the complete checkout with deterministic ZIP entries and SHA256 guards."""
import argparse
import hashlib
from pathlib import Path
import stat
import zipfile

ROOT = Path(__file__).resolve().parent


def files():
    return sorted(path for path in ROOT.rglob('*') if path.is_file() and path != ROOT / 'SHA256SUMS'
                  and not any(part in ('__pycache__', '.static-work', '.git') for part in path.relative_to(ROOT).parts)
                  and path.suffix != '.pyc')


def checksums():
    (ROOT / 'SHA256SUMS').write_text(''.join(hashlib.sha256(path.read_bytes()).hexdigest() + '  '
        + path.relative_to(ROOT).as_posix() + '\n' for path in files()))


def delivery(destination):
    target = Path(destination).resolve()
    if target == ROOT or ROOT in target.parents:
        raise ValueError('Place the delivery ZIP outside the checkout.')
    target.parent.mkdir(parents=True, exist_ok=True)
    checksums()
    with zipfile.ZipFile(target, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for path in files() + [ROOT / 'SHA256SUMS']:
            info = zipfile.ZipInfo(path.relative_to(ROOT).as_posix(), (1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = (stat.S_IFREG | (0o755 if path.suffix == '.sh' else 0o644)) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, path.read_bytes())
    with zipfile.ZipFile(target) as archive:
        if archive.testzip() is not None:
            raise RuntimeError('Delivery ZIP CRC failure')
        for line in archive.read('SHA256SUMS').decode().splitlines():
            digest, name = line.split('  ', 1)
            if hashlib.sha256(archive.read(name)).hexdigest() != digest:
                raise RuntimeError('Delivery checksum mismatch: ' + name)
    print('Complete checkout ZIP CRC/per-file SHA256 verified.')
    print('ZIP SHA256: ' + hashlib.sha256(target.read_bytes()).hexdigest())


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=('checksums', 'zip'))
    parser.add_argument('--output')
    args = parser.parse_args()
    if args.action == 'checksums':
        checksums()
    elif not args.output:
        parser.error('--output is required')
    else:
        delivery(args.output)
