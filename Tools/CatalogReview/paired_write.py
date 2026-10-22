"""Replace a pack's Creatures.json and PackManifest.json as one unit.

Both payloads are staged beside the targets first. The targets are then moved aside,
the staged files moved in, and on any failure every target is restored to its original
bytes (or removed if it did not exist). Shared by every catalogue writer.
"""
from __future__ import annotations

import os
import tempfile
from pathlib import Path


def replace_file_pair(targets, payloads, prefix=".catalog-review-"):
    """targets: two Paths in the same directory; payloads: their new bytes."""
    targets = tuple(Path(t) for t in targets)
    with tempfile.TemporaryDirectory(prefix=prefix, dir=targets[0].parent) as temporary:
        stage = Path(temporary)
        staged = tuple(stage / target.name for target in targets)
        for path, payload in zip(staged, payloads):
            path.write_bytes(payload)
        backups = tuple(stage / (target.name + ".bak") for target in targets)
        moved_backups = []
        installed = []
        try:
            for target, backup in zip(targets, backups):
                if target.exists():
                    os.replace(target, backup)
                    moved_backups.append((target, backup))
            for source, target in zip(staged, targets):
                os.replace(source, target)
                installed.append(target)
        except BaseException:
            for target in reversed(installed):
                if target.exists():
                    target.unlink()
            for target, backup in reversed(moved_backups):
                if backup.exists():
                    os.replace(backup, target)
            raise
