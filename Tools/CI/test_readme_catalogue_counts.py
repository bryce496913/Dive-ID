"""Keeps the README catalogue table and exposure lines in step with the pack manifests."""
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
README = ROOT / 'README.md'
PACKS = ROOT / 'DiveID/Resources/IdentificationPacks'
REGIONS = ROOT / 'DiveID/Core/Catalog/Regions'
SECTION = '## Current catalogue and availability'

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


class RepositoryReadmeTests(unittest.TestCase):
    def test_readme_counts_match_pack_manifests(self):
        packs = manifests()
        self.assertTrue(packs, f'No PackManifest.json under {PACKS}')
        gated = release_gated_directories()
        self.assertIn('Global', gated, 'Expected GlobalRegion.swift to keep Global out of Release')
        problems = mismatches(README.read_text(), packs, gated)
        self.assertEqual(problems, [], 'README.md disagrees with the pack manifests:\n' + '\n'.join(problems))


if __name__ == '__main__':
    unittest.main()
