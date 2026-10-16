#!/usr/bin/env python3
"""Fail on any new frozen-case failure or degraded recall/rank/abstention metric."""
import argparse
import json
from pathlib import Path


def compare(before, after):
    if before['fixtureSHA256'] != after['fixtureSHA256'] or before['suiteID'] != after['suiteID']:
        raise ValueError('Evaluation fixture identity changed')
    old={(g['access'],g['requestedEngine']):g for g in before['groups']}
    new={(g['access'],g['requestedEngine']):g for g in after['groups']}
    if len(old)!=len(before['groups']) or len(new)!=len(after['groups']) or old.keys()!=new.keys():
        raise ValueError('Missing or duplicate evaluation engine/access groups')
    failures=[]
    for key,a in old.items():
        b=new[key]
        old_cases={c['id']:c for c in a['cases']};new_cases={c['id']:c for c in b['cases']}
        if len(old_cases)!=len(a['cases']) or len(new_cases)!=len(b['cases']) or old_cases.keys()!=new_cases.keys():raise ValueError('Missing/duplicate evaluation cases')
        for cid,c in old_cases.items():
            d=new_cases[cid]
            if set(d['failures'])-set(c['failures']):failures.append([*key,cid,'new_failure'])
            if c['candidateRecalled'] and not d['candidateRecalled']:failures.append([*key,cid,'candidate_recall'])
            if c['displayedRank'] is not None and (d['displayedRank'] is None or d['displayedRank']>c['displayedRank']):failures.append([*key,cid,'displayed_rank'])
            if c['coverageBlocked']!=d['coverageBlocked']:failures.append([*key,cid,'coverage_changed'])
            if c['actualEngine']!=d['actualEngine']:failures.append([*key,cid,'engine_changed'])
        for metric in ('candidateRecallHits','top1','top3','top10','correctNoMatch','correctRegionConflicts','ambiguousAccepted','confidenceCompliant'):
            if b['counts'][metric]<a['counts'][metric]:failures.append([*key,metric,'metric_decreased'])
        for metric in ('eligibleCases','positiveDenominator','noMatchDenominator','regionConflictDenominator','ambiguousDenominator','confidenceDenominator'):
            if b['counts'][metric]!=a['counts'][metric]:failures.append([*key,metric,'denominator_changed'])
        if b['counts']['falsePositives']>a['counts']['falsePositives']:failures.append([*key,'falsePositives','increased'])
    return failures

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('before',type=Path);parser.add_argument('after',type=Path)
    args=parser.parse_args();failures=compare(json.loads(args.before.read_text()),json.loads(args.after.read_text()))
    print(json.dumps({'additionalRegressions':failures},indent=2))
    raise SystemExit(bool(failures))
