#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Reproduce pinned firmware with Python's zstandard or the Windows tar tool."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--assets', type=Path, help='copy an existing verified asset directory')
    parser.add_argument('--offline', action='store_true')
    args = parser.parse_args()
    output = ROOT / 'build' / 'assets'
    output.mkdir(parents=True, exist_ok=True)
    if args.assets:
        for entry in json.loads((ROOT / 'assets.json').read_text()):
            shutil.copy2(args.assets / entry['Name'], output / entry['Name'])
        license_path = args.assets / 'NVIDIA-LICENSE'
        if not license_path.is_file():
            raise ValueError('asset directory requires NVIDIA-LICENSE')
        shutil.copy2(license_path, output / 'NVIDIA-LICENSE')
    else:
        firmware_tools = ROOT / 'vendor' / 'ada-firmware-tools'
        fetch = load('fetch', firmware_tools / 'fetch_artifacts.py')
        manifest = json.loads(fetch.MANIFEST.read_text())
        cache = ROOT / 'build' / 'inputs'
        source, package = [fetch.fetch(entry, cache, args.offline) for entry in fetch.inputs(manifest)]
        unpacked = ROOT / 'build' / 'nvidia-source'
        unpacked.mkdir(parents=True, exist_ok=True)
        with tarfile.open(source) as archive:
            archive.extractall(unpacked, filter='data')
        sources = list(unpacked.glob('*/src/nvidia/generated/g_bindata_kgspGetBinArchiveBooterLoadUcode_GA102.c'))
        if len(sources) != 1:
            raise ValueError('pinned NVIDIA source layout not found')
        # Use the upstream command line for its geometry/hash checks.
        import sys
        for chip in ('ga102', 'ad102'):
            subprocess.run([sys.executable, str(firmware_tools / 'extract_boot_assets.py'),
                            str(sources[0].parents[3]), str(output), '--chip', chip], check=True)
        generated = load('generate', firmware_tools / 'generate_v67.py')
        # Windows tar.exe supports zstd packages. Extract only the three named files.
        package_out = ROOT / 'build' / 'nvidia-package'
        package_out.mkdir(parents=True, exist_ok=True)
        names = [generated.FIRMWARE_PREFIX + 'gsp_ga10x.bin', manifest['source_artifacts'][2]['notice']['path'], '.PKGINFO']
        subprocess.run(['tar', '-xf', str(package), '-C', str(package_out), *names], check=True)
        metadata = (package_out / '.PKGINFO').read_text()
        if 'pkgver = 610.43.03-1' not in metadata:
            raise ValueError('package version mismatch')
        shutil.copy2(package_out / names[0], output / 'gsp_ga10x.bin')
        license_path = package_out / names[1]
        if hashlib.sha256(license_path.read_bytes()).hexdigest() != manifest['source_artifacts'][2]['notice']['sha256']:
            raise ValueError('NVIDIA license mismatch')
        shutil.copy2(license_path, output / 'NVIDIA-LICENSE')
        (output / 'v67-ga102-610.43.03.bin').write_bytes(generated.build_payload())
        (output / generated.AD102_PAYLOAD_NAME).write_bytes(generated.build_ad102_payload())
    for entry in json.loads((ROOT / 'assets.json').read_text()):
        path = output / entry['Name']
        if path.stat().st_size != entry['Bytes'] or hashlib.sha256(path.read_bytes()).hexdigest() != entry['Sha256']:
            raise ValueError(f'asset verification failed: {path.name}')
        print(f'verified {path.name}')


if __name__ == '__main__':
    main()
