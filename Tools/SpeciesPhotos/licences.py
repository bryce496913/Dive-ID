"""Photo licence policy: which licences a species photo may carry."""
import json
from pathlib import Path

POLICY_PATH = Path(__file__).resolve().parent / "photo_policy.json"

# Canonical licence codes (iNaturalist's spelling) with their display names and deeds.
LICENCES = {
    "cc0": ("CC0 1.0", "https://creativecommons.org/publicdomain/zero/1.0/"),
    "cc-by": ("CC BY 4.0", "https://creativecommons.org/licenses/by/4.0/"),
    "cc-by-nc": ("CC BY-NC 4.0", "https://creativecommons.org/licenses/by-nc/4.0/"),
    "cc-by-sa": ("CC BY-SA 4.0", "https://creativecommons.org/licenses/by-sa/4.0/"),
    "cc-by-nc-sa": ("CC BY-NC-SA 4.0", "https://creativecommons.org/licenses/by-nc-sa/4.0/"),
    "cc-by-nd": ("CC BY-ND 4.0", "https://creativecommons.org/licenses/by-nd/4.0/"),
    "cc-by-nc-nd": ("CC BY-NC-ND 4.0", "https://creativecommons.org/licenses/by-nc-nd/4.0/"),
}

ALLOWED, LATER_DECISION, EXCLUDED_NO_DERIVATIVES, EXCLUDED_UNKNOWN = (
    "allowed", "later-decision", "excluded-no-derivatives", "excluded-unknown")


def load_policy(path=POLICY_PATH):
    policy = json.loads(Path(path).read_text())
    for code in policy["allowedLicences"] + policy["laterDecisionLicences"]:
        if code not in LICENCES:
            raise ValueError(f"unknown licence in policy: {code}")
        if code.endswith("-nd"):
            raise ValueError(f"a no-derivatives licence cannot be allowed: {code}")
    if set(policy["allowedLicences"]) & set(policy["laterDecisionLicences"]):
        raise ValueError("a licence cannot be both allowed and held for a later decision")
    return policy


def normalise(code):
    """iNaturalist's code ('cc-by-nc'), or None for all rights reserved / missing."""
    if not code:
        return None
    value = str(code).strip().lower().replace("_", "-").replace(" ", "-")
    return value if value in LICENCES else None


def classify(code, policy):
    """Allowed, held for a later decision (share-alike), or excluded."""
    value = normalise(code)
    if value is None:
        return EXCLUDED_UNKNOWN
    if value in policy["allowedLicences"]:
        return ALLOWED
    if value.endswith("-nd"):
        return EXCLUDED_NO_DERIVATIVES
    if value in policy["laterDecisionLicences"]:
        return LATER_DECISION
    return EXCLUDED_UNKNOWN


def display(code):
    """(licence name, licence URL) for an allowed or known code."""
    return LICENCES[normalise(code)]
