"""Read a release's App name from its versioned notes, preserving old fixtures."""

import re


def release_title(tag, notes):
    first_line = notes.splitlines()[0].strip() if notes else ""
    if not re.match(r"#\s+", first_line):
        return f"湘少英语三上点读 {tag}"
    heading = re.fullmatch(rf"#\s+(\S.*?)\s+{re.escape(tag)}", first_line)
    if heading is None:
        raise ValueError("Release notes heading must contain the App name and matching version tag")
    return f"{heading.group(1)} {tag}"
