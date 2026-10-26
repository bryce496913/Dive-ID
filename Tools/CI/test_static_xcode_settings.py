import contextlib
import io
import re
import unittest

import static_xcode_settings as S


def release_block(text, owner_id):
    """The Release XCBuildConfiguration block for a configuration id."""
    return re.search(r'\t\t' + owner_id + r' /\* Release \*/ = \{.*?\n\t\t\};\n', text, re.S).group(0)


class StaticProjectSettingsTests(unittest.TestCase):
    def setUp(self):
        self.text = S.PROJECT.read_text()
        owners_lists = re.findall(r'\t\t\w+ /\* Build configuration list for (PBXProject|PBXNativeTarget) "([^"]+)" \*/ = \{'
                                  r'.*?buildConfigurations = \((.*?)\);', self.text, re.S)
        self.release_ids = {('<project>' if kind == 'PBXProject' else name): re.search(r'(\w+) /\* Release \*/', ids).group(1)
                            for kind, name, ids in owners_lists}

    def check(self, text):
        with contextlib.redirect_stdout(io.StringIO()):
            S.check(text)

    def edit_release(self, owner, transform):
        block = release_block(self.text, self.release_ids[owner])
        return self.text.replace(block, transform(block))

    def test_the_committed_project_holds_every_boundary(self):
        self.check(self.text)

    def test_debug_or_internal_flag_in_release_fails_at_project_or_target_level(self):
        for owner in ('<project>', 'DiveID'):
            for flag in ('DEBUG', 'DIVEID_INTERNAL'):
                text = self.edit_release(owner, lambda b: b.replace(
                    'buildSettings = {\n', f'buildSettings = {{\n\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited) {flag}";\n', 1))
                with self.subTest(owner=owner, flag=flag), self.assertRaises(ValueError):
                    self.check(text)

    def test_release_must_be_optimized(self):
        text = self.edit_release('<project>', lambda b: b.replace('SWIFT_OPTIMIZATION_LEVEL = "-O";', 'SWIFT_OPTIMIZATION_LEVEL = "-Onone";'))
        self.assertNotEqual(text, self.text, 'the project sets Release optimization explicitly')
        with self.assertRaises(ValueError):
            self.check(text)

    def test_inherited_expands_to_the_project_value_and_arrays_are_read(self):
        owners = S.parse(self.text)
        owners['<project>']['Release']['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'PROJECT_FLAG'
        owners['DiveID']['Release']['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = '$(inherited) APP_FLAG'
        self.assertEqual(S.resolve(owners, 'DiveID', 'Release')['SWIFT_ACTIVE_COMPILATION_CONDITIONS'], 'PROJECT_FLAG APP_FLAG')
        self.assertEqual(S._value('(\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t\tDEBUG,\n\t\t\t\t)'), '$(inherited) DEBUG')

    def test_a_missing_configuration_fails_closed(self):
        owners = S.parse(self.text)
        del owners['DiveID']['Internal']
        with self.assertRaises(ValueError):
            S.resolve(owners, 'DiveID', 'Internal')


if __name__ == '__main__':
    unittest.main()
