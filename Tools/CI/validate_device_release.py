#!/usr/bin/env python3
"""Check a built device product; never claim installation or physical execution."""
import argparse
import json
import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Tools/CatalogReview'))
from publication_expectations import generate


def validate_settings(entries):
    settings = next(entry['buildSettings'] for entry in entries if entry['target'] == 'DiveID')
    for key, expected in [('CONFIGURATION', 'Release'), ('PLATFORM_NAME', 'iphoneos')]:
        if settings.get(key) != expected:
            raise ValueError(f'{key} must be {expected}')
    flags = ' '.join(str(settings.get(key, '')) for key in
                     ('SWIFT_ACTIVE_COMPILATION_CONDITIONS', 'OTHER_SWIFT_FLAGS',
                      'GCC_PREPROCESSOR_DEFINITIONS', 'OTHER_CFLAGS'))
    if re.search(r'(?<![A-Za-z0-9_])(?:-D\s*)?DEBUG\b', flags):
        raise ValueError('Release must not define DEBUG')
    if settings.get('CODE_SIGNING_ALLOWED') == 'NO' or not settings.get('DEVELOPMENT_TEAM'):
        raise ValueError('A signed physical-device product is required')
    if not settings.get('PRODUCT_BUNDLE_IDENTIFIER'):
        raise ValueError('Missing resolved app bundle identifier')
    return settings


def validate_product(settings, app, expected, root=ROOT):
    with (app / 'Info.plist').open('rb') as handle:
        info = plistlib.load(handle)
    if info.get('CFBundleSupportedPlatforms') != ['iPhoneOS']:
        raise ValueError('Not a physical iPhoneOS product')
    for field, setting in [('CFBundleIdentifier', 'PRODUCT_BUNDLE_IDENTIFIER'),
                           ('CFBundleShortVersionString', 'MARKETING_VERSION'),
                           ('CFBundleVersion', 'CURRENT_PROJECT_VERSION')]:
        if str(info.get(field)) != str(settings.get(setting)):
            raise ValueError(f'Built {field} differs from resolved {setting}')
    counts = {}
    for region, directory in [('caribbean', 'Caribbean'), ('tropical-pacific', 'TropicalPacific')]:
        relative = Path('IdentificationPacks') / directory
        for filename in ('Creatures.json', 'PackManifest.json'):
            built = json.loads((app / relative / filename).read_text())
            source = json.loads((root / 'DiveID/Resources' / relative / filename).read_text())
            if built != source:
                raise ValueError(f'Packaged {directory}/{filename} differs from candidate')
        records = json.loads((app / relative / 'Creatures.json').read_text())
        ids = sorted(r['id'] for r in records if r['review']['status'] == 'verified' and r['categories'])
        if ids != expected[region]:
            raise ValueError(f'{region}: eligible IDs differ from valid approvals')
        counts[region] = {'bundled': len(records), 'publicationEligibleIDs': ids}
    return {'bundleIdentifier': info['CFBundleIdentifier'], 'version': info['CFBundleShortVersionString'],
            'build': info['CFBundleVersion'], 'packagedCatalogues': counts,
            'evidenceScope': 'Built device product only; installation, runtime access and engine remain unobserved'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--settings', type=Path, required=True)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    settings = validate_settings(json.loads(args.settings.read_text()))
    report = validate_product(settings, args.app, generate())
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
