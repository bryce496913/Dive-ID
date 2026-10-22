#!/usr/bin/env python3
"""Fail CI on unresolved/colliding test products or lost compilation conditions.

Also checks the app target's configuration boundary:
- Debug defines DEBUG and not DIVEID_INTERNAL.
- Release defines neither DEBUG nor DIVEID_INTERNAL.
- Internal defines DIVEID_INTERNAL, never DEBUG, is optimized (-O) and installs
  under its own bundle identifier, so it can never replace or pose as Release.
"""
import json
import sys

RELEASE_BUNDLE_ID = 'com.brycecameron.DiveID'
INTERNAL_BUNDLE_ID = RELEASE_BUNDLE_ID + '.internal'


def _conditions(settings):
    conditions = settings.get('SWIFT_ACTIVE_COMPILATION_CONDITIONS', '')
    return conditions.split() if isinstance(conditions, str) else list(conditions)


def validate_app(settings, configuration):
    conditions = _conditions(settings)
    optimization = settings.get('SWIFT_OPTIMIZATION_LEVEL')
    bundle_id = settings.get('PRODUCT_BUNDLE_IDENTIFIER')
    display_name = settings.get('DIVEID_DISPLAY_NAME')
    print(f'{configuration} DiveID conditions={conditions} SWIFT_OPTIMIZATION_LEVEL={optimization} '
          f'bundle={bundle_id} displayName={display_name!r}', flush=True)
    if not display_name:
        raise ValueError('DiveID: DIVEID_DISPLAY_NAME (Info.plist CFBundleDisplayName) is empty')
    has_debug, has_internal = 'DEBUG' in conditions, 'DIVEID_INTERNAL' in conditions
    if configuration == 'Debug':
        if not has_debug or has_internal:
            raise ValueError('DiveID Debug must define DEBUG and not DIVEID_INTERNAL')
    elif configuration == 'Release':
        if has_debug or has_internal:
            raise ValueError('DiveID Release must define neither DEBUG nor DIVEID_INTERNAL')
        if bundle_id != RELEASE_BUNDLE_ID:
            raise ValueError(f'DiveID Release bundle identifier must be {RELEASE_BUNDLE_ID}')
    elif configuration == 'Internal':
        if has_debug or not has_internal:
            raise ValueError('DiveID Internal must define DIVEID_INTERNAL and not DEBUG')
        if optimization != '-O':
            raise ValueError(f'DiveID Internal must be optimized with -O, got {optimization!r}')
        if bundle_id != INTERNAL_BUNDLE_ID:
            raise ValueError(f'DiveID Internal bundle identifier must be {INTERNAL_BUNDLE_ID}')
    else:
        raise ValueError(f'Unknown configuration {configuration!r}')


def validate(entries, configuration):
    by_target = {entry['target']: entry['buildSettings'] for entry in entries}
    validate_app(by_target['DiveID'], configuration)
    outputs = set()
    for target in ('DiveIDTests', 'DiveIDUITests'):
        settings = by_target[target]
        expected = {
            'PRODUCT_NAME': target,
            'PRODUCT_MODULE_NAME': target,
            'FULL_PRODUCT_NAME': target + '.xctest',
            'EXECUTABLE_NAME': target,
        }
        for key, value in expected.items():
            actual = settings.get(key)
            print(f'{configuration} {target} {key}={actual}', flush=True)
            if actual != value:
                raise ValueError(f'{target}: {key} expected {value!r}, got {actual!r}')
        output = settings['TARGET_BUILD_DIR'] + '/' + settings['FULL_PRODUCT_NAME']
        if output in outputs:
            raise ValueError(f'Colliding test output: {output}')
        outputs.add(output)
        conditions = _conditions(settings)
        print(f'{configuration} {target} conditions={conditions} output={output}', flush=True)
        if configuration == 'Debug' and 'DEBUG' not in conditions:
            raise ValueError(f'{target}: inherited DEBUG condition missing')
        if configuration != 'Debug' and 'DEBUG' in conditions:
            raise ValueError(f'{target}: DEBUG must not be defined in {configuration}')
        if target == 'DiveIDTests' and 'DIVEID_XCODE_HOSTED_TEST' not in conditions:
            raise ValueError('Hosted unit-test compilation condition missing')


if __name__ == '__main__':
    with open(sys.argv[1]) as handle:
        validate(json.load(handle), sys.argv[2])
