#!/usr/bin/env python3
"""Check that first-use instrumentation is in Debug/Internal app binaries and never in Release.

The instrumentation (signpost intervals, the Internal diagnostics row and the stored-index
delete/corrupt actions) is compiled only under `DEBUG || DIVEID_INTERNAL`. This scans the
Mach-O (or ELF) files of a built .app, or the given binaries, for strings that only the
instrumentation contains.

    check_internal_instrumentation.py --expect absent  path/to/Release-iphonesimulator/DiveID.app
    check_internal_instrumentation.py --expect present path/to/Internal-iphonesimulator/DiveID.app

`present` requires every string literal marker, which proves the scan can see them;
`absent` rejects those and the signpost API names too.
"""
import argparse
import os
import sys

# String literals compiled only with the instrumentation (all longer than 15 bytes, so
# Swift stores them as C strings rather than inline small strings).
LITERAL_MARKERS = [
    'com.brycecameron.DiveID.performance',
    'rebuilt after invalid store',
    'loaded from store',
    'Background preparation',
    'Query to first result',
    'Index load from store',
    'Delete stored index',
    'Corrupt stored index',
    'Internal search diagnostics',
]
# API names that optimized builds may inline away, so they are only checked for absence.
API_MARKERS = ['OSSignposter', 'os_signpost']

BINARY_MAGICS = (
    b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xfe\xed\xfa\xce',  # Mach-O
    b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca',  # universal
    b'\x7fELF',
)


def is_binary(path):
    try:
        with open(path, 'rb') as handle:
            return handle.read(4) in BINARY_MAGICS
    except OSError:
        return False


def binaries(path):
    if os.path.isfile(path):
        return [path] if is_binary(path) else []
    found = []
    for root, _, files in os.walk(path):
        for name in sorted(files):
            candidate = os.path.join(root, name)
            if not os.path.islink(candidate) and is_binary(candidate):
                found.append(candidate)
    return found


def markers_in(paths, markers):
    """The markers found in any of the binaries."""
    found = set()
    for path in paths:
        with open(path, 'rb') as handle:
            data = handle.read()
        found.update(marker for marker in markers if marker.encode() in data)
    return [marker for marker in markers if marker in found]


def check(paths, expect):
    files = [binary for path in paths for binary in binaries(path)]
    if not files:
        raise ValueError(f'no Mach-O or ELF binaries found in {paths}')
    if expect == 'present':
        found = markers_in(files, LITERAL_MARKERS)
        missing = [marker for marker in LITERAL_MARKERS if marker not in found]
        if missing:
            raise ValueError(f'instrumentation expected but missing: {missing}')
    else:
        found = markers_in(files, LITERAL_MARKERS + API_MARKERS)
        if found:
            raise ValueError(f'instrumentation must not be in this build, found: {found}')
    return files


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--expect', choices=('present', 'absent'), required=True)
    parser.add_argument('paths', nargs='+')
    args = parser.parse_args(argv)
    try:
        files = check(args.paths, args.expect)
    except ValueError as error:
        print(f'FAIL: {error}', file=sys.stderr)
        return 1
    print(f'OK: instrumentation {args.expect} in {len(files)} binaries: {files}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
