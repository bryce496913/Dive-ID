#!/usr/bin/env python3
"""Fail CI on unresolved/colliding test products or lost compilation conditions."""
import json
import sys


def validate(entries, configuration):
    by_target = {entry['target']: entry['buildSettings'] for entry in entries}
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
        conditions = settings.get('SWIFT_ACTIVE_COMPILATION_CONDITIONS', '')
        if isinstance(conditions, str):
            conditions = conditions.split()
        print(f'{configuration} {target} conditions={conditions} output={output}', flush=True)
        if configuration == 'Debug' and 'DEBUG' not in conditions:
            raise ValueError(f'{target}: inherited DEBUG condition missing')
        if target == 'DiveIDTests' and 'DIVEID_XCODE_HOSTED_TEST' not in conditions:
            raise ValueError('Hosted unit-test compilation condition missing')


if __name__ == '__main__':
    with open(sys.argv[1]) as handle:
        validate(json.load(handle), sys.argv[2])
