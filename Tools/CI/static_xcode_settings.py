#!/usr/bin/env python3
"""Check the app target's configuration boundary from project.pbxproj, without Xcode.

GitHub CI no longer runs xcodebuild, so this reads the DiveID target's build settings
for each configuration straight from the project file (project level, then target
level, expanding $(inherited)) and applies validate_xcode_settings.validate_app:
Release defines neither DEBUG nor DIVEID_INTERNAL and is -O; Debug is DEBUG and -Onone;
Internal is DIVEID_INTERNAL, -O and installs under its own bundle identifier.

It only understands settings written in the project file. A value that would come from
an .xcconfig file or an Xcode default is treated as absent, so the check fails closed.
"""
import re
import sys
from pathlib import Path

from validate_xcode_settings import validate_app

ROOT = Path(__file__).resolve().parents[2]
PROJECT = ROOT / 'DiveID.xcodeproj/project.pbxproj'
CONFIGURATIONS = ('Debug', 'Release', 'Internal')
APP_TARGET = 'DiveID'

_LIST = re.compile(r'\t\t(\w+) /\* Build configuration list for (PBXProject|PBXNativeTarget) "([^"]+)" \*/ = \{'
                   r'.*?buildConfigurations = \((.*?)\);', re.S)
_CONFIG = re.compile(r'\t\t(\w+) /\* [^*]+ \*/ = \{\s*isa = XCBuildConfiguration;\s*'
                     r'(?:baseConfigurationReference = [^;]+;\s*)?buildSettings = \{(.*?)\n\t\t\t\};\s*name = ([^;]+);', re.S)
_SETTING = re.compile(r'^\t\t\t\t("?[\w.\[\]=*]+"?) = (\((?:.|\n)*?\)|"(?:[^"\\]|\\.)*"|[^;]*);', re.M)


def _value(raw):
    raw = raw.strip()
    if raw.startswith('('):
        return ' '.join(_value(item) for item in re.findall(r'"(?:[^"\\]|\\.)*"|[^,\s()]+', raw))
    if raw.startswith('"') and raw.endswith('"'):
        return raw[1:-1].replace('\\"', '"')
    return raw


def parse(text):
    """{owner: {configuration: {setting: value}}}; owner is '<project>' or a target name."""
    configs = {}
    for match in _CONFIG.finditer(text):
        settings = {key.strip('"'): _value(value) for key, value in _SETTING.findall(match.group(2))}
        configs[match.group(1)] = (match.group(3).strip().strip('"'), settings)
    owners = {}
    for match in _LIST.finditer(text):
        owner = '<project>' if match.group(2) == 'PBXProject' else match.group(3)
        ids = re.findall(r'(\w+) /\*', match.group(4))
        owners[owner] = {configs[i][0]: configs[i][1] for i in ids if i in configs}
    return owners


def resolve(owners, target, configuration):
    """Target settings over project settings; $(inherited) takes the project value."""
    project = owners.get('<project>', {}).get(configuration)
    settings = owners.get(target, {}).get(configuration)
    if project is None or settings is None:
        raise ValueError(f'{target}: no {configuration} configuration in the project file')
    resolved = {k: re.sub(r'\$\(inherited\)\s*', '', v).strip() for k, v in project.items()}
    for key, value in settings.items():
        inherited = resolved.get(key, '')
        resolved[key] = re.sub(r'\$\(inherited\)', inherited, value).strip()
    return resolved


def check(text):
    owners = parse(text)
    for configuration in CONFIGURATIONS:
        validate_app(resolve(owners, APP_TARGET, configuration), configuration)


if __name__ == '__main__':
    check(Path(sys.argv[1] if len(sys.argv) > 1 else PROJECT).read_text())
    print('Static project settings: Debug, Release and Internal app boundaries hold.')
