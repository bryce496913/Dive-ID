import contextlib
import io
import unittest
from validate_xcode_settings import validate


class ResolvedSettingsTests(unittest.TestCase):
    def entries(self, configuration='Debug'):
        return [{'target': target, 'buildSettings': {
            'PRODUCT_NAME': target, 'PRODUCT_MODULE_NAME': target,
            'FULL_PRODUCT_NAME': target + '.xctest', 'EXECUTABLE_NAME': target,
            'TARGET_BUILD_DIR': '/products',
            'SWIFT_ACTIVE_COMPILATION_CONDITIONS': (
                ('DEBUG ' if configuration == 'Debug' else '') +
                ('DIVEID_XCODE_HOSTED_TEST' if target == 'DiveIDTests' else '')),
        }} for target in ('DiveIDTests', 'DiveIDUITests')]

    def check(self, entries, configuration='Debug'):
        with contextlib.redirect_stdout(io.StringIO()):
            validate(entries, configuration)

    def test_debug_and_release(self):
        for config in ('Debug', 'Release'):
            self.check(self.entries(config), config)

    def test_historical_empty_names_fail(self):
        for key in ('PRODUCT_NAME', 'PRODUCT_MODULE_NAME', 'EXECUTABLE_NAME'):
            entries = self.entries()
            entries[0]['buildSettings'][key] = ''
            with self.assertRaises(ValueError):
                self.check(entries)

    def test_missing_target_fails(self):
        with self.assertRaises(KeyError):
            self.check(self.entries()[:1])

    def test_lost_conditions_fail(self):
        for conditions in ('DEBUG', 'DIVEID_XCODE_HOSTED_TEST'):
            entries = self.entries()
            entries[0]['buildSettings']['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = conditions
            with self.assertRaises(ValueError):
                self.check(entries)

    def test_duplicate_module_fails(self):
        entries = self.entries()
        entries[1]['buildSettings']['PRODUCT_MODULE_NAME'] = 'DiveIDTests'
        with self.assertRaises(ValueError):
            self.check(entries)
