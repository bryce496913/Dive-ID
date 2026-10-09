#!/usr/bin/env python3
"""Run frozen v0.5 cases through Swift application-service tests, retaining failures."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--version', choices=['1', '2'], default='2')
    parser.add_argument('--swift', default='swift')
    parser.add_argument('--configuration', choices=['debug', 'release'], default='debug')
    parser.add_argument('--output', type=Path, default=ROOT / 'Reports/V05DevelopmentEvaluation.json')
    parser.add_argument('--log', type=Path, default=ROOT / 'Reports/V05DevelopmentEvaluation.log')
    args = parser.parse_args()
    fixture = ROOT / f'DiveIDTests/Fixtures/V05Development.v{args.version}.json'
    contract = json.loads((ROOT / f'Data/Evaluation/V05Protocol.v{args.version}.json').read_text())
    actual = hashlib.sha256(fixture.read_bytes()).hexdigest()
    if actual != contract['fixtureSHA256']:
        raise SystemExit('Fixture differs from frozen protocol; create a new version, do not retune this fixture.')
    args.output = args.output.resolve(); args.log = args.log.resolve()
    args.output.parent.mkdir(parents=True, exist_ok=True); args.log.parent.mkdir(parents=True, exist_ok=True)
    # Never mistake a report from an earlier run for evidence of a failed build.
    if args.output.exists(): args.output.unlink()
    env = dict(os.environ, DIVEID_V05_REPORT=str(args.output), DIVEID_V05_VERSION=args.version)
    command = [args.swift, 'test', '-c', args.configuration, '--jobs', '4', '--filter', 'V05DevelopmentEvaluationTests']
    with args.log.open('w') as log:
        completed = subprocess.run(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
    if not args.output.exists():
        print(f'No evaluation report produced; inspect {args.log}', file=sys.stderr)
        return completed.returncode or 1
    report = json.loads(args.output.read_text())
    for group in report['groups']:
        print(group['access'], group['requestedEngine'], json.dumps(group['counts'], sort_keys=True))
    print(f'Full results: {args.output}; log: {args.log}; exit: {completed.returncode}')
    return completed.returncode

if __name__ == '__main__':
    sys.exit(main())
