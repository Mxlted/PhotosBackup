#!/usr/bin/env python3
"""Choose an available iPhone runtime for the selected Xcode's simulator SDK."""
import argparse
import json
import re
import sys


def select_simulator(devices, sdk):
    sdk_version = tuple(int(part) for part in sdk.split("."))
    sdk_version = (sdk_version + (0, 0))[:3]
    candidates = []
    for runtime, entries in devices.get("devices", {}).items():
        match = re.fullmatch(r"com\.apple\.CoreSimulator\.SimRuntime\.iOS-(\d+(?:-\d+)*)", runtime)
        if not match:
            continue
        version = tuple(int(part) for part in match.group(1).split("-"))
        version = (version + (0, 0))[:3]
        # Do not silently pick an old preinstalled runtime or one newer than
        # this toolchain. Older-OS coverage can still use an explicit UUID.
        if version[0] != sdk_version[0] or version > sdk_version:
            continue
        for device in entries:
            if device.get("isAvailable") and device.get("name", "").startswith("iPhone "):
                candidates.append((version, device.get("state") == "Booted", device))
    if not candidates:
        raise ValueError(f"No available iPhone runtime compatible with iOS SDK {sdk}. "
                         "Install a matching runtime, or pass a simulator UUID explicitly.")
    candidates.sort(key=lambda entry: (entry[0], entry[1]), reverse=True)
    version, _, device = candidates[0]
    print(f"Selected {device['name']} (iOS {'.'.join(map(str, version[:2]))}) "
          f"for simulator SDK {sdk}", file=sys.stderr)
    return device["udid"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", required=True)
    args = parser.parse_args()
    try:
        print(select_simulator(json.load(sys.stdin), args.sdk))
    except (ValueError, KeyError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
