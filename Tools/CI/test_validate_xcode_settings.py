import contextlib
import io
import unittest
from validate_xcode_settings import validate

APP = {
    'Debug': {'SWIFT_ACTIVE_COMPILATION_CONDITIONS': 'DEBUG', 'SWIFT_OPTIMIZATION_LEVEL': '-Onone',
              'PRODUCT_BUNDLE_IDENTIFIER': 'com.brycecameron.DiveID', 'DIVEID_DISPLAY_NAME': 'Dive ID'},
    'Release': {'SWIFT_ACTIVE_COMPILATION_CONDITIONS': '', 'SWIFT_OPTIMIZATION_LEVEL': '-O',
                'PRODUCT_BUNDLE_IDENTIFIER': 'com.brycecameron.DiveID', 'DIVEID_DISPLAY_NAME': 'Dive ID'},
    'Internal': {'SWIFT_ACTIVE_COMPILATION_CONDITIONS': 'DIVEID_INTERNAL', 'SWIFT_OPTIMIZATION_LEVEL': '-O',
                 'PRODUCT_BUNDLE_IDENTIFIER': 'com.brycecameron.DiveID.internal',
                 'DIVEID_DISPLAY_NAME': 'Dive ID Internal'},
}


class ResolvedSettingsTests(unittest.TestCase):
    def entries(self, configuration='Debug'):
        tests = [{'target': target, 'buildSettings': {
            'PRODUCT_NAME': target, 'PRODUCT_MODULE_NAME': target,
            'FULL_PRODUCT_NAME': target + '.xctest', 'EXECUTABLE_NAME': target,
            'TARGET_BUILD_DIR': '/products',
            'SWIFT_ACTIVE_COMPILATION_CONDITIONS': (
                ('DEBUG ' if configuration == 'Debug' else '') +
                ('DIVEID_XCODE_HOSTED_TEST' if target == 'DiveIDTests' else '')),
        }} for target in ('DiveIDTests', 'DiveIDUITests')]
        return [{'target': 'DiveID', 'buildSettings': dict(APP[configuration])}] + tests

    def check(self, entries, configuration='Debug'):
        with contextlib.redirect_stdout(io.StringIO()):
            validate(entries, configuration)

    def test_debug_release_and_internal(self):
        for config in ('Debug', 'Release', 'Internal'):
            self.check(self.entries(config), config)

    def test_historical_empty_names_fail(self):
        for key in ('PRODUCT_NAME', 'PRODUCT_MODULE_NAME', 'EXECUTABLE_NAME'):
            entries = self.entries()
            entries[1]['buildSettings'][key] = ''
            with self.assertRaises(ValueError):
                self.check(entries)

    def test_missing_target_fails(self):
        with self.assertRaises(KeyError):
            self.check(self.entries()[:2])
        with self.assertRaises(KeyError):
            self.check(self.entries()[1:])

    def test_lost_conditions_fail(self):
        for conditions in ('DEBUG', 'DIVEID_XCODE_HOSTED_TEST'):
            entries = self.entries()
            entries[1]['buildSettings']['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = conditions
            with self.assertRaises(ValueError):
                self.check(entries)

    def test_duplicate_module_fails(self):
        entries = self.entries()
        entries[2]['buildSettings']['PRODUCT_MODULE_NAME'] = 'DiveIDTests'
        with self.assertRaises(ValueError):
            self.check(entries)

    def app_fails(self, configuration, **changes):
        entries = self.entries(configuration)
        entries[0]['buildSettings'].update(changes)
        with self.assertRaises(ValueError):
            self.check(entries, configuration)

    def test_release_never_defines_debug_or_internal(self):
        for conditions in ('DEBUG', 'DIVEID_INTERNAL', 'DEBUG DIVEID_INTERNAL'):
            self.app_fails('Release', SWIFT_ACTIVE_COMPILATION_CONDITIONS=conditions)

    def test_release_keeps_its_bundle_identifier(self):
        self.app_fails('Release', PRODUCT_BUNDLE_IDENTIFIER='com.brycecameron.DiveID.internal')

    def test_internal_never_defines_debug(self):
        for conditions in ('DEBUG DIVEID_INTERNAL', 'DEBUG', ''):
            self.app_fails('Internal', SWIFT_ACTIVE_COMPILATION_CONDITIONS=conditions)

    def test_internal_is_optimized(self):
        for level in ('-Onone', '-Osize', None):
            self.app_fails('Internal', SWIFT_OPTIMIZATION_LEVEL=level)

    def test_internal_installs_separately_from_release(self):
        self.app_fails('Internal', PRODUCT_BUNDLE_IDENTIFIER='com.brycecameron.DiveID')

    def test_debug_is_unoptimized(self):
        for level in ('-O', '-Osize', None):
            self.app_fails('Debug', SWIFT_OPTIMIZATION_LEVEL=level)

    def test_release_is_optimized(self):
        for level in ('-Onone', '-Osize', None):
            self.app_fails('Release', SWIFT_OPTIMIZATION_LEVEL=level)

    def test_debug_never_defines_internal(self):
        self.app_fails('Debug', SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG DIVEID_INTERNAL')

    def test_empty_display_name_fails(self):
        for config in ('Debug', 'Release', 'Internal'):
            self.app_fails(config, DIVEID_DISPLAY_NAME='')

    def test_test_targets_never_define_debug_outside_debug(self):
        for config in ('Release', 'Internal'):
            entries = self.entries(config)
            entries[2]['buildSettings']['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG'
            with self.assertRaises(ValueError):
                self.check(entries, config)

    def test_unknown_configuration_fails(self):
        entries = self.entries('Release')
        with self.assertRaises(ValueError):
            self.check(entries, 'Profile')
