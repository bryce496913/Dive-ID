"""Keeps README counts in step with the pack manifests and the committed evaluation reports."""
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
README = ROOT / 'README.md'
PACKS = ROOT / 'DiveID/Resources/IdentificationPacks'
REGIONS = ROOT / 'DiveID/Core/Catalog/Regions'
SECTION = '## Current catalogue and availability'
V05_REPORT = ROOT / 'Reports/V05DevelopmentEvaluation.json'
GLOBAL_REPORT = ROOT / 'Reports/GlobalPackEvaluation.json'
PRODUCTION_ENGINE = 'production-bm25-50-biological'
REGION_ROWS = {'caribbean': 'Caribbean', 'tropical-pacific': 'Tropical Pacific (Experimental)'}

# README column -> manifest field.
COLUMNS = {
    'Version': 'packVersion',
    'Bundled records': 'includedRecordCount',
    'Human-reviewed': 'humanReviewedRecordCount',
    'Publication-eligible': 'publicationEligibleRecordCount',
}


def number(text):
    return int(text.replace(',', '').strip())


def cells(line):
    return [cell.strip() for cell in line.strip().strip('|').split('|')]


def catalogue_section(readme):
    start = readme.index(SECTION) + len(SECTION)
    end = readme.find('\n## ', start)
    return readme[start:] if end == -1 else readme[start:end]


def catalogue_table(section):
    """Rows of the first table whose header starts with 'Pack', keyed by pack name."""
    lines = section.splitlines()
    for index, line in enumerate(lines):
        if line.startswith('|') and cells(line)[0] == 'Pack':
            header = cells(line)
            rows = {}
            for row in lines[index + 2:]:
                if not row.startswith('|'):
                    break
                values = cells(row)
                rows[values[0]] = dict(zip(header, values))
            return header, rows
    raise AssertionError(f'No catalogue table under "{SECTION}" in README.md')


def manifests():
    return {
        path.parent.name: json.loads(path.read_text())
        for path in sorted(PACKS.glob('*/PackManifest.json'))
    }


def release_gated_directories():
    """Pack directories whose region definition sets `availableInRelease: false`."""
    gated = set()
    for path in sorted(REGIONS.glob('*.swift')):
        source = path.read_text()
        directory = re.search(r'resourceDirectory:\s*"([^"]+)"', source)
        if directory and re.search(r'availableInRelease:\s*false', source):
            gated.add(directory.group(1))
    return gated


def mismatches(readme, packs, release_gated=frozenset()):
    """`packs` maps pack directory to manifest; `release_gated` names directories Release never loads."""
    section = catalogue_section(readme)
    header, rows = catalogue_table(section)
    problems = [f'README table lacks column "{column}"' for column in COLUMNS if column not in header]
    if problems:
        return problems
    by_name = {manifest['displayName']: manifest for manifest in packs.values()}
    for name in sorted(set(by_name) - set(rows)):
        problems.append(f'README table has no row for pack "{name}"')
    for name in sorted(set(rows) - set(by_name)):
        problems.append(f'README table row "{name}" matches no PackManifest.json displayName')
    for name in sorted(set(rows) & set(by_name)):
        manifest = by_name[name]
        for column, field in COLUMNS.items():
            if number(rows[name][column]) != manifest[field]:
                problems.append(f'{name} "{column}": README {rows[name][column]}, '
                                f'manifest {field} {manifest[field]}')
        if manifest['includedRecordCount'] != manifest['speciesCount']:
            problems.append(f'{name} manifest: includedRecordCount {manifest["includedRecordCount"]} '
                            f'!= speciesCount {manifest["speciesCount"]}')

    release = re.search(r'\*\*Release\*\* exposes ([\d,]+) records?', section)
    debug = re.search(r'\*\*Debug\*\* permits all ([\d,]+) development records', section)
    eligible = sum(manifest['publicationEligibleRecordCount']
                   for directory, manifest in packs.items() if directory not in release_gated)
    included = sum(manifest['includedRecordCount'] for manifest in packs.values())
    if not release:
        problems.append('README lacks the "**Release** exposes N records" line')
    elif number(release.group(1)) != eligible:
        problems.append(f'README Release exposes {release.group(1)}, manifests allow {eligible} '
                        'publication-eligible records')
    if not debug:
        problems.append('README lacks the "**Debug** permits all N development records" line')
    elif number(debug.group(1)) != included:
        problems.append(f'README Debug permits {debug.group(1)}, manifests include {included} records')
    return problems


def fraction(hits, total):
    return f'{hits}/{total}'


def v05_summary(counts):
    """The README's wording of one V05 group's counts."""
    return (f'candidate recall {fraction(counts["candidateRecallHits"], counts["positiveDenominator"])}, '
            f'top1 {fraction(counts["top1"], counts["positiveDenominator"])}, '
            f'top3 {fraction(counts["top3"], counts["positiveDenominator"])}, '
            f'top10 {fraction(counts["top10"], counts["positiveDenominator"])}, '
            f'no-match {fraction(counts["correctNoMatch"], counts["noMatchDenominator"])}, '
            f'region conflicts {fraction(counts["correctRegionConflicts"], counts["regionConflictDenominator"])}, '
            f'confidence {fraction(counts["confidenceCompliant"], counts["confidenceDenominator"])}')


def evaluation_mismatches(readme, v05, global_report):
    """Phrases the README must contain, derived from the committed evaluation reports."""
    text = ' '.join(readme.split())
    problems = []

    def expect(phrase, source):
        if phrase not in text:
            problems.append(f'README lacks "{phrase}" ({source})')

    groups = {(group['access'], group['requestedEngine']): group for group in v05['groups']}
    development = groups[('experimentalDevelopment', PRODUCTION_ENGINE)]
    publication = groups[('publication', PRODUCTION_ENGINE)]
    expect(v05_summary(development['counts']), 'V05 development, production engine')
    expect(v05_summary(publication['counts']), 'V05 publication, production engine')
    v05_passes = all(gate['status'] in ('passed', 'not-evaluated')
                     for group in (development, publication) for gate in group['gates'])
    if v05_passes != ('passes every gate on the regional packs' in text):
        problems.append('README "passes every gate on the regional packs" disagrees with V05 gate statuses')
    _, rows = catalogue_table(catalogue_section(readme))
    for region, row in REGION_ROWS.items():
        tally = development['byRegion'][region]
        cell = (f'{"pass" if v05_passes else "fail"} '
                f'({fraction(tally["top10"], tally["positiveDenominator"])})')
        if row not in rows or not next(iter(reversed(rows[row].values()))).startswith(cell):
            problems.append(f'README catalogue row "{row}" should report "{cell}"')

    written = next(group for group in global_report['groups'] if group['variant'] == 'global-as-written')
    counts = written['counts']
    expect(' '.join(['| As written |'] + [
        fraction(counts[key]['hits'], counts[key]['total']) + ' |'
        for key in ('candidateRecall', 'top1', 'top3', 'top10', 'noMatchCorrect', 'confidenceCompliant')]),
        'Global as written')
    expect(f'Global, {written["packSize"]:,} records', 'Global pack size')
    expect(f'opt-in ({fraction(counts["top10"]["hits"], counts["top10"]["total"])};', 'Global top10')
    misses = sorted(case['id'] for case in written['cases'] if case['kind'] == 'identification'
                    and not (case['rank'] and case['rank'] <= 10))
    for case_id in misses:
        expect(f'`{case_id}`', 'Global top-ten miss')
    return problems


TABLE = """## Current catalogue and availability

| Pack | Version | Bundled records | Human-reviewed | Publication-eligible | Gates |
| --- | ---: | ---: | ---: | ---: | --- |
| Alpha | 2 | 10 | 1 | 1 | pass |
| Beta (Experimental) | 3 | 1,200 | 0 | 0 | pass |

- **Release** exposes 1 record.
- **Debug** permits all 1,210 development records.

## Next section
"""


def manifest(name, version, included, reviewed, eligible):
    return {'displayName': name, 'packVersion': version, 'speciesCount': included,
            'includedRecordCount': included, 'humanReviewedRecordCount': reviewed,
            'publicationEligibleRecordCount': eligible}


class SyntheticReadmeTests(unittest.TestCase):
    def packs(self):
        return {'Alpha': manifest('Alpha', 2, 10, 1, 1),
                'Beta': manifest('Beta (Experimental)', 3, 1200, 0, 0)}

    def test_matching_readme_passes(self):
        self.assertEqual(mismatches(TABLE, self.packs()), [])

    def test_stale_record_count_fails(self):
        packs = self.packs()
        packs['Beta'].update(speciesCount=1208, includedRecordCount=1208)
        problems = mismatches(TABLE, packs)
        self.assertIn('Beta (Experimental) "Bundled records": README 1,200, '
                      'manifest includedRecordCount 1208', problems)
        self.assertIn('README Debug permits 1,210, manifests include 1218 records', problems)

    def test_stale_approval_counts_fail(self):
        packs = self.packs()
        packs['Alpha'].update(humanReviewedRecordCount=2, publicationEligibleRecordCount=2)
        problems = mismatches(TABLE, packs)
        self.assertIn('Alpha "Human-reviewed": README 1, manifest humanReviewedRecordCount 2', problems)
        self.assertIn('Alpha "Publication-eligible": README 1, '
                      'manifest publicationEligibleRecordCount 2', problems)
        self.assertIn('README Release exposes 1, manifests allow 2 publication-eligible records', problems)

    def test_missing_and_unknown_packs_fail(self):
        packs = self.packs()
        packs['Gamma'] = manifest('Gamma', 1, 5, 0, 0)
        packs['Beta']['displayName'] = 'Beta'
        problems = mismatches(TABLE, packs)
        self.assertIn('README table has no row for pack "Gamma"', problems)
        self.assertIn('README table row "Beta (Experimental)" matches no PackManifest.json displayName',
                      problems)

    def test_release_gated_pack_approvals_are_not_exposed(self):
        packs = self.packs()
        packs['Beta'].update(humanReviewedRecordCount=5, publicationEligibleRecordCount=5)
        problems = mismatches(TABLE, packs, release_gated={'Beta'})
        self.assertNotIn('README Release exposes 1, manifests allow 6 publication-eligible records', problems)
        self.assertFalse([problem for problem in problems if problem.startswith('README Release')])

    def test_missing_exposure_lines_fail(self):
        readme = TABLE.replace('- **Release** exposes 1 record.\n', '')
        self.assertIn('README lacks the "**Release** exposes N records" line',
                      mismatches(readme, self.packs()))


def v05_group(access, top10):
    counts = {'candidateRecallHits': 4, 'positiveDenominator': 4, 'top1': 3, 'top3': 4, 'top10': top10,
              'correctNoMatch': 3, 'noMatchDenominator': 3, 'correctRegionConflicts': 2,
              'regionConflictDenominator': 2, 'confidenceCompliant': 10, 'confidenceDenominator': 10}
    status = 'passed' if top10 == 4 else 'failed'
    return {'access': access, 'requestedEngine': PRODUCTION_ENGINE, 'counts': counts,
            'byRegion': {'caribbean': {'top10': top10, 'positiveDenominator': 4},
                         'tropical-pacific': {'top10': 1, 'positiveDenominator': 1}},
            'gates': [{'metric': 'top10', 'status': status}]}


def global_group():
    hits = {'candidateRecall': 2, 'top1': 1, 'top3': 1, 'top10': 1, 'noMatchCorrect': 1, 'confidenceCompliant': 3}
    totals = {'noMatchCorrect': 1, 'confidenceCompliant': 3}
    return {'groups': [{'variant': 'global-as-written', 'packSize': 1200,
                        'counts': {key: {'hits': value, 'total': totals.get(key, 2)} for key, value in hits.items()},
                        'cases': [{'id': 'case-a', 'kind': 'identification', 'rank': 1},
                                  {'id': 'case-b', 'kind': 'identification', 'rank': None},
                                  {'id': 'case-c', 'kind': 'noMatch', 'rank': None}]}]}


EVALUATION = """## Current catalogue and availability

| Pack | Version | Bundled records | Human-reviewed | Publication-eligible | Gates |
| --- | ---: | ---: | ---: | ---: | --- |
| Caribbean | 3 | 8 | 2 | 2 | pass (4/4) |
| Tropical Pacific (Experimental) | 3 | 1000 | 0 | 0 | pass (1/1) |
| Global (Experimental) | 3 | 1200 | 0 | 0 | pass, opt-in (1/2; one miss) |

| Global, 1,200 records | Recall | First | Top three | Top ten | No-match | Confidence |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| As written | 2/2 | 1/2 | 1/2 | 1/2 | 1/1 | 3/3 |

`case-b` misses the top ten.

## Checks

The evaluation passes every gate on the regional packs:
- candidate recall 4/4, top1 3/4, top3 4/4, top10 4/4, no-match 3/3,
  region conflicts 2/2, confidence 10/10.
"""


class SyntheticEvaluationTests(unittest.TestCase):
    def reports(self, top10=4):
        return {'groups': [v05_group('experimentalDevelopment', top10), v05_group('publication', top10)]}, global_group()

    def test_matching_readme_passes(self):
        self.assertEqual(evaluation_mismatches(EVALUATION, *self.reports()), [])

    def test_stale_v05_result_fails(self):
        problems = evaluation_mismatches(EVALUATION, *self.reports(top10=3))
        self.assertIn('README "passes every gate on the regional packs" disagrees with V05 gate statuses', problems)
        self.assertIn('README catalogue row "Caribbean" should report "fail (3/4)"', problems)
        self.assertTrue(any('top10 3/4' in problem for problem in problems), problems)

    def test_stale_global_result_and_missing_miss_fail(self):
        v05, global_report = self.reports()
        written = global_report['groups'][0]
        written['counts']['top10']['hits'] = 2
        written['cases'].append({'id': 'case-d', 'kind': 'identification', 'rank': 11})
        problems = evaluation_mismatches(EVALUATION, v05, global_report)
        self.assertIn('README lacks "opt-in (2/2;" (Global top10)', problems)
        self.assertIn('README lacks "`case-d`" (Global top-ten miss)', problems)


class RepositoryReadmeTests(unittest.TestCase):
    def test_readme_matches_evaluation_reports(self):
        problems = evaluation_mismatches(README.read_text(), json.loads(V05_REPORT.read_text()),
                                         json.loads(GLOBAL_REPORT.read_text()))
        self.assertEqual(problems, [], 'README.md disagrees with the evaluation reports:\n' + '\n'.join(problems))

    def test_readme_counts_match_pack_manifests(self):
        packs = manifests()
        self.assertTrue(packs, f'No PackManifest.json under {PACKS}')
        gated = release_gated_directories()
        self.assertIn('Global', gated, 'Expected GlobalRegion.swift to keep Global out of Release')
        problems = mismatches(README.read_text(), packs, gated)
        self.assertEqual(problems, [], 'README.md disagrees with the pack manifests:\n' + '\n'.join(problems))


if __name__ == '__main__':
    unittest.main()
