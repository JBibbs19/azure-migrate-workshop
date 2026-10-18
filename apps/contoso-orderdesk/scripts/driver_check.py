#!/usr/bin/env python3
"""Structural compatibility check, not a provenance/signature verification."""
import argparse
import hashlib
import struct
import zipfile
from pathlib import Path


def inspect(path):
    path = Path(path)
    if not path.name.startswith('mssql-jdbc-') or not path.name.endswith('.jre11.jar'):
        raise ValueError('Provide an official Microsoft mssql-jdbc-<version>.jre11.jar.')
    with zipfile.ZipFile(path) as jar:
        if jar.testzip() is not None:
            raise ValueError('JDBC JAR CRC check failed.')
        driver = jar.read('com/microsoft/sqlserver/jdbc/SQLServerDriver.class')
        magic, minor, major = struct.unpack('>IHH', driver[:8])
        if magic != 0xCAFEBABE or not 55 <= major <= 61:
            raise ValueError('Driver class is not compatible with the expected Java 11+ / Java 17 deployment.')
        manifest = jar.read('META-INF/MANIFEST.MF').decode('utf-8', errors='replace')
    print('JDBC file: ' + path.name)
    print('SHA256: ' + hashlib.sha256(path.read_bytes()).hexdigest())
    for line in manifest.splitlines():
        if line.startswith(('Implementation-Version:', 'Bundle-Version:')):
            print(line)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('jar')
    args = parser.parse_args()
    try:
        inspect(args.jar)
    except (ValueError, KeyError, OSError, zipfile.BadZipFile) as error:
        raise SystemExit('Invalid JDBC prerequisite: ' + str(error)) from None
