import contextlib
import io
import os
import tempfile
import unittest

from check_internal_instrumentation import API_MARKERS, LITERAL_MARKERS, check, main

MACHO = b'\xcf\xfa\xed\xfe'


class InstrumentationCheckTests(unittest.TestCase):
    def app(self, directory, contents, name='DiveID', magic=MACHO):
        bundle = os.path.join(directory, 'DiveID.app')
        os.makedirs(bundle, exist_ok=True)
        with open(os.path.join(bundle, name), 'wb') as handle:
            handle.write(magic + contents)
        return bundle

    def all_literals(self):
        return b'\0'.join(marker.encode() for marker in LITERAL_MARKERS)

    def test_release_without_markers_passes_and_with_any_marker_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            clean = self.app(directory, b'release code only')
            check([clean], 'absent')
            for marker in LITERAL_MARKERS + API_MARKERS:
                with self.subTest(marker=marker):
                    dirty = self.app(directory, b'code ' + marker.encode() + b' more')
                    with self.assertRaises(ValueError):
                        check([dirty], 'absent')

    def test_internal_needs_every_literal_marker(self):
        with tempfile.TemporaryDirectory() as directory:
            check([self.app(directory, self.all_literals())], 'present')
            partial = self.app(directory, b'\0'.join(marker.encode() for marker in LITERAL_MARKERS[1:]))
            with self.assertRaises(ValueError):
                check([partial], 'present')

    def test_markers_in_any_binary_of_the_bundle_count(self):
        # Xcode Debug builds put the code in DiveID.debug.dylib beside a stub executable.
        with tempfile.TemporaryDirectory() as directory:
            self.app(directory, b'stub')
            bundle = self.app(directory, self.all_literals(), name='DiveID.debug.dylib')
            check([bundle], 'present')
            with self.assertRaises(ValueError):
                check([bundle], 'absent')

    def test_non_binary_resources_are_ignored(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle = self.app(directory, b'release code only')
            with open(os.path.join(bundle, 'notes.json'), 'wb') as handle:
                handle.write(self.all_literals())
            check([bundle], 'absent')

    def test_no_binaries_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                check([directory], 'absent')

    def test_main_exit_status(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle = self.app(directory, self.all_literals())
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(main(['--expect', 'present', bundle]), 0)
                self.assertEqual(main(['--expect', 'absent', bundle]), 1)


if __name__ == '__main__':
    unittest.main()
