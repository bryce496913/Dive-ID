"""Fails CI when the bundled photo reference index is stale.

The index (DiveID/Resources/IdentificationPacks/<pack>/PhotoIndex.bin) is built on a Mac by
Tools/PhotoIndex from the pack's approved bundled photos. Whenever the species file or any
photo changes, it must be rebuilt:

    swift run -c release photo-index

This check recomputes every digest from the repository's files and compares them with the
sidecar (Data/PhotoIndex/<pack>.json) and the index header. It does not recompute feature
prints (that needs Apple Vision), so it runs on Linux.
"""
import hashlib
import json
import struct
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PACKS = ROOT / "DiveID/Resources/IdentificationPacks"
SIDECARS = ROOT / "Data/PhotoIndex"
REBUILD = "Photo index is stale: run `swift run -c release photo-index` and commit the result."


def fnv1a64_hex(data):
    value = 0xCBF29CE484222325
    for byte in data:
        value ^= byte
        value = (value * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return f"{value:016x}"


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def read_header(data):
    """(format, revision, dimension, count, catalogue version) from PhotoIndex.bin."""
    if data[:4] != b"DIPX":
        raise ValueError("not a photo index")
    form, revision, dimension, count = struct.unpack_from("<IIII", data, 4)
    (length,) = struct.unpack_from("<H", data, 20)
    return form, revision, dimension, count, data[22:22 + length].decode()


def problems(pack_directory, sidecar_path, pack_id):
    """Every way the index disagrees with the repository; empty when it is current."""
    pack_directory, sidecar_path = Path(pack_directory), Path(sidecar_path)
    index_path = pack_directory / "PhotoIndex.bin"
    if not index_path.is_file() or not sidecar_path.is_file():
        return [f"{index_path.name} or {sidecar_path.name} is missing"]
    sidecar = json.loads(sidecar_path.read_text())
    manifest = json.loads((pack_directory / "PackManifest.json").read_text())
    species_path = pack_directory / (manifest["speciesResourceName"] + ".json")
    species_data = species_path.read_bytes()
    found = []
    expected_version = f"{pack_id}-{fnv1a64_hex(species_data)}"
    if sidecar["catalogueContentVersion"] != expected_version:
        found.append(f"catalogue content version {sidecar['catalogueContentVersion']} != {expected_version} ({species_path.name} changed)")
    if sidecar["speciesFileSHA256"] != hashlib.sha256(species_data).hexdigest():
        found.append(f"{species_path.name} changed since the index was built")
    index_data = index_path.read_bytes()
    if sidecar["indexSHA256"] != hashlib.sha256(index_data).hexdigest():
        found.append("PhotoIndex.bin doesn't match its sidecar")
    _, revision, dimension, count, version = read_header(index_data)
    if (revision, dimension, count, version) != (sidecar["requestRevision"], sidecar["dimension"], sidecar["count"], sidecar["catalogueContentVersion"]):
        found.append("PhotoIndex.bin header doesn't match its sidecar")

    images = pack_directory / manifest["imageSubdirectory"]
    approved = {}
    for record in json.loads(species_data):
        image = record.get("bundledImage")
        if image:
            approved[(record["id"].upper(), image["fileName"])] = image.get("licenseName")
    indexed = {(entry["speciesID"].upper(), entry["fileName"]): entry for entry in sidecar["entries"]}
    for key in sorted(approved.keys() - indexed.keys()):
        found.append(f"approved photo {key[1]} (species {key[0]}) is not in the index")
    for key in sorted(indexed.keys() - approved.keys()):
        found.append(f"indexed photo {key[1]} (species {key[0]}) is no longer an approved bundled photo")
    for key in sorted(approved.keys() & indexed.keys()):
        entry, path = indexed[key], images / key[1]
        if not path.is_file():
            found.append(f"approved photo {key[1]} is missing")
        elif sha256(path) != entry["sha256"]:
            found.append(f"photo {key[1]} changed since the index was built")
        if entry["licence"] != approved[key]:
            found.append(f"photo {key[1]} licence changed")
    return found


class PhotoIndexIsCurrentTests(unittest.TestCase):
    def test_global_photo_index_is_current(self):
        found = problems(PACKS / "Global", SIDECARS / "Global.json", "global")
        self.assertEqual(found, [], REBUILD + "\n" + "\n".join(found[:20]))

    def test_the_check_notices_a_changed_species_file_and_photo(self):
        import shutil
        import tempfile
        with tempfile.TemporaryDirectory() as temporary:
            pack = Path(temporary) / "Global"
            (pack / "Images").mkdir(parents=True)
            source = PACKS / "Global"
            shutil.copy(source / "PackManifest.json", pack)
            shutil.copy(source / "PhotoIndex.bin", pack)
            records = json.loads((source / "Creatures.json").read_text())
            sidecar = json.loads((SIDECARS / "Global.json").read_text())
            first = sidecar["entries"][0]
            shutil.copy(source / "Images" / first["fileName"], pack / "Images")
            keep = [r for r in records if (r.get("bundledImage") or {}).get("fileName") == first["fileName"]]
            (pack / "Creatures.json").write_text(json.dumps(keep))
            (pack / "Images" / first["fileName"]).write_bytes(b"changed")
            sidecar_path = Path(temporary) / "Global.json"
            sidecar_path.write_text(json.dumps(sidecar))
            found = problems(pack, sidecar_path, "global")
            self.assertTrue(any("Creatures.json changed" in p for p in found), found)
            self.assertTrue(any(f"photo {first['fileName']} changed" in p for p in found), found)


if __name__ == "__main__":
    unittest.main()
