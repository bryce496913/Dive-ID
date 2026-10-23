#!/usr/bin/env bash
# Rebuild the FishBase/SeaLifeBase draft records on a machine that can reach the pinned
# release (Source Cooperative S3) and PyPI. This is the only step that needs network
# access or pyarrow; publishing, review batches and tests run anywhere afterwards.
#
#   ./Tools/FishBaseIntake/rebuild_drafts.sh
#
# 1. creates a throwaway virtual environment outside the repository, with pyarrow;
# 2. downloads and verifies the pinned tables (fetch.py; ~76 MB, git-ignored cache);
# 3. builds the drafts offline from that cache (build.py);
# 4. runs the FishBaseIntake unit tests, and exits nonzero (after listing the changed
#    files) if they fail.
# It does not publish packs, record approvals, commit or push.
set -euo pipefail

cd "$(dirname "$0")/../.."
REPO="$PWD"
VENV="${TMPDIR:-/tmp}/diveid-fishbase-venv"

echo "== Python: $(python3 --version)"
python3 -m venv "$VENV"
"$VENV/bin/python" -m pip install --quiet --upgrade pip
"$VENV/bin/python" -m pip install --quiet -r Tools/FishBaseIntake/requirements.txt

echo "== Download and verify the pinned FishBase/SeaLifeBase tables"
"$VENV/bin/python" Tools/FishBaseIntake/fetch.py

echo "== Build the draft records (offline, from the verified cache)"
"$VENV/bin/python" Tools/FishBaseIntake/build.py --offline

echo "== FishBaseIntake tests"
TEST_STATUS=0
TEST_LOG="$("$VENV/bin/python" -m unittest discover -s Tools/FishBaseIntake -p 'test_*.py' 2>&1)" || TEST_STATUS=$?
if [ "$TEST_STATUS" -ne 0 ]; then
  printf '%s\n' "$TEST_LOG"
else
  printf '%s\n' "$TEST_LOG" | tail -3
fi

echo
echo "Done. Changed files:"
git -C "$REPO" status --short Data/GlobalMarine/FishBase || true
exit "$TEST_STATUS"
