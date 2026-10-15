import unittest
import json
import plistlib
import shutil
import tempfile
from pathlib import Path
from validate_device_release import ROOT, generate, validate_product, validate_settings


class DeviceReleaseSettingsTests(unittest.TestCase):
    def test_built_product_requires_matching_identity_platform_and_catalogues(self):
        settings = validate_settings(self.settings())
        settings.update(MARKETING_VERSION='0.5', CURRENT_PROJECT_VERSION='2')
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory)
            shutil.copytree(ROOT / 'DiveID/Resources/IdentificationPacks', app / 'IdentificationPacks')
            info = dict(CFBundleSupportedPlatforms=['iPhoneOS'], CFBundleIdentifier='test.app',
                        CFBundleShortVersionString='0.5', CFBundleVersion='2')
            (app / 'Info.plist').write_bytes(plistlib.dumps(info))
            self.assertEqual(validate_product(settings, app, generate())['build'], '2')
            for field, value in [('CFBundleSupportedPlatforms', ['iPhoneSimulator']),
                                 ('CFBundleIdentifier', 'other.app')]:
                (app / 'Info.plist').write_bytes(plistlib.dumps(dict(info, **{field: value})))
                with self.assertRaises(ValueError):
                    validate_product(settings, app, generate())
            (app / 'Info.plist').write_bytes(plistlib.dumps(info))
            path = app / 'IdentificationPacks/Caribbean/Creatures.json'
            records = json.loads(path.read_text()); records[0]['summary'] = 'Wrong build'
            path.write_text(json.dumps(records))
            with self.assertRaisesRegex(ValueError, 'differs from candidate'):
                validate_product(settings, app, generate())

    def settings(self, **changes):
        return [{'target': 'DiveID', 'buildSettings': dict(
            CONFIGURATION='Release', PLATFORM_NAME='iphoneos', DEVELOPMENT_TEAM='test-team',
            PRODUCT_BUNDLE_IDENTIFIER='test.app', **changes)}]

    def test_signed_release_settings_are_accepted(self):
        self.assertEqual(validate_settings(self.settings())['PLATFORM_NAME'], 'iphoneos')

    def test_debug_inherited_or_explicit_flags_are_rejected(self):
        for field, value in [('SWIFT_ACTIVE_COMPILATION_CONDITIONS', 'DEBUG'),
                             ('OTHER_SWIFT_FLAGS', '-DDEBUG'), ('OTHER_SWIFT_FLAGS', '-D DEBUG')]:
            with self.subTest(field=field, value=value), self.assertRaisesRegex(ValueError, 'DEBUG'):
                validate_settings(self.settings(**{field: value}))

    def test_simulator_debug_and_unsigned_products_are_rejected(self):
        for field, value in [('PLATFORM_NAME', 'iphonesimulator'), ('CONFIGURATION', 'Debug'),
                             ('CODE_SIGNING_ALLOWED', 'NO')]:
            entries = self.settings()
            entries[0]['buildSettings'][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate_settings(entries)
