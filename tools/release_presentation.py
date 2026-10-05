"""Compare immutable release notes with explicitly registered display prefixes.

Promotional images belong to Release presentation, not the App's tagged notes or
update manifest. Only an exact prefix registered for this tag and platform may
appear before the original notes; this helper never updates a remote Release.
"""

import json
from pathlib import Path


REGISTRY = Path(__file__).resolve().parents[1] / "docs/promo/releases.json"


def release_body_matches(body, notes, *, tag, platform, registry_path=None):
    """Accept the original notes or their exact, registered promotional prefix."""
    if platform not in ("github", "gitee"):
        raise ValueError("Unsupported release presentation platform")
    if not isinstance(body, str) or not isinstance(notes, str):
        return False
    original = notes.strip()
    if body.strip() == original:
        return True
    path = Path(registry_path) if registry_path is not None else REGISTRY
    if not path.is_file():
        return False
    try:
        registry = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise ValueError("Invalid release presentation registry") from None
    if (not isinstance(registry, dict)
            or type(registry.get("schemaVersion")) is not int
            or registry["schemaVersion"] != 1
            or not isinstance(registry.get("releases"), dict)):
        raise ValueError("Invalid release presentation registry")
    registration = registry["releases"].get(tag)
    if registration is None:
        return False
    if not isinstance(registration, dict):
        raise ValueError("Invalid release presentation registration")
    display = registration.get(platform)
    if display is None:
        return False
    if (not isinstance(display, dict) or not isinstance(display.get("prefix"), str)
            or not display["prefix"].strip()):
        raise ValueError("Invalid release presentation prefix")
    expected = (display["prefix"] + "\n\n" + original).strip()
    return body.strip() == expected
