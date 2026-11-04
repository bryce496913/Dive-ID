"""The retired Caribbean and Tropical Pacific packs are test fixtures, never shipped.

Runs without Xcode. It checks the app's resource tree (what both the Xcode app target and
the SwiftPM `DiveID` target copy), the SwiftPM manifest and the Xcode project. A built
device product is checked by validate_device_release.py.
"""
import re
import unittest
from pathlib import Path

from validate_device_release import RETIRED_PACKS, retired_packs_in

ROOT = Path(__file__).resolve().parents[2]
APP_PACKS = ROOT / 'DiveID/Resources/IdentificationPacks'
FIXTURE_PACKS = ROOT / 'DiveIDTests/Fixtures/IdentificationPacks'


class RetiredPacksTests(unittest.TestCase):
    def test_no_retired_pack_file_is_in_the_app_resources(self):
        self.assertEqual(retired_packs_in(APP_PACKS), [])
        for name in RETIRED_PACKS:
            self.assertFalse((APP_PACKS / name).exists(), f'{name} is back in the app resources')

    def test_the_retired_packs_are_test_fixtures(self):
        for name in RETIRED_PACKS:
            self.assertTrue((FIXTURE_PACKS / name / 'Creatures.json').is_file(), name)
            self.assertTrue((FIXTURE_PACKS / name / 'PackManifest.json').is_file(), name)

    def test_swiftpm_ships_only_the_app_resources(self):
        manifest = (ROOT / 'Package.swift').read_text()
        library = manifest[manifest.index('name: "DiveID"'):manifest.index('.testTarget(')]
        self.assertEqual(re.findall(r'\.copy\("([^"]+)"\)', library), ['Resources/IdentificationPacks'])

    def test_xcode_app_target_does_not_copy_test_fixtures(self):
        project = (ROOT / 'DiveID.xcodeproj/project.pbxproj').read_text()
        app_group = project[project.index('/* DiveID */ = {\n\t\t\tisa = PBXFileSystemSynchronizedRootGroup'):]
        app_group = app_group[:app_group.index('};')]
        self.assertIn('path = DiveID;', app_group)
        self.assertNotIn('DiveIDTests', app_group)

    def test_xcode_test_target_lists_every_fixture_pack_file_as_an_exception(self):
        # Xcode copies test resources flat, so the packs' same-named files (Creatures.json,
        # PackManifest.json, images) would collide; tests read them from the source tree.
        project = (ROOT / 'DiveID.xcodeproj/project.pbxproj').read_text()
        exceptions = project[project.index('Exceptions for "DiveIDTests" folder'):]
        exceptions = exceptions[:exceptions.index('target = ')]
        listed = set(re.findall(r'Fixtures/IdentificationPacks/[^,\n"]+', exceptions))
        on_disk = {str(path.relative_to(ROOT / 'DiveIDTests')) for path in FIXTURE_PACKS.rglob('*')
                   if path.is_file() and path.name != '.DS_Store'}
        self.assertEqual(on_disk - listed, set(), 'add these to the DiveIDTests exceptions in project.pbxproj')

    def test_the_check_finds_a_retired_pack(self):
        import shutil
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            shutil.copytree(FIXTURE_PACKS / 'TropicalPacific', Path(directory) / 'TropicalPacific')
            self.assertEqual(retired_packs_in(directory), ['TropicalPacific/Creatures.json', 'TropicalPacific/PackManifest.json'])


if __name__ == '__main__':
    unittest.main()
