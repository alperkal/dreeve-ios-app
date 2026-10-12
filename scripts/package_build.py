#!/usr/bin/env python3
"""Package verified CI products without signing credentials or third-party libraries."""
import argparse
import hashlib
import plistlib
import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path


def app_info(app, platform):
    if not app.is_dir():
        raise ValueError(f"Missing app product: {app}")
    with (app / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if platform not in info.get("CFBundleSupportedPlatforms", []):
        raise ValueError(f"Wrong platform for {app}: expected {platform}")
    if not (app / info["CFBundleExecutable"]).is_file():
        raise ValueError(f"Missing app executable: {app}")
    return info


def package(simulator, iphone, output):
    simulator_info = app_info(simulator, "iPhoneSimulator")
    iphone_info = app_info(iphone, "iPhoneOS")
    for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion"):
        if simulator_info[key] != iphone_info[key]:
            raise ValueError(f"Simulator and iPhone products disagree on {key}")
    if (iphone / "_CodeSignature").exists() or (iphone / "embedded.mobileprovision").exists():
        raise ValueError("Expected an unsigned iPhone build without a provisioning profile")
    output.mkdir(parents=True, exist_ok=True)
    source_zip = output / "DreeveIOS-project.zip"
    simulator_zip = output / "DreeveIOS-simulator.zip"
    ipa = output / "DreeveIOS-unsigned.ipa"
    repo = Path(__file__).resolve().parent.parent
    # Archive the exact checkout commit, excluding ignored build products and user state.
    subprocess.run(["git", "archive", "--format=zip", "--prefix=DreeveIOS/",
                    f"--output={source_zip}", "HEAD"], cwd=repo, check=True)
    subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent",
                    str(simulator), str(simulator_zip)], check=True)
    with tempfile.TemporaryDirectory(prefix="dreeve-ipa-") as temporary:
        payload = Path(temporary) / "Payload"
        payload.mkdir()
        shutil.copytree(iphone, payload / "DreeveIOS.app", symlinks=True)
        subprocess.run(["ditto", "-c", "-k", "--keepParent", str(payload), str(ipa)], check=True)
    for path in (source_zip, simulator_zip, ipa):
        with zipfile.ZipFile(path) as archive:
            if archive.testzip() is not None:
                raise ValueError(f"Corrupt ZIP: {path}")
    sums = "".join(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n"
                   for path in (source_zip, simulator_zip, ipa))
    (output / "SHA256SUMS.txt").write_text(sums)
    print(f"Packaged source, simulator app and unsigned IPA in {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator-app", type=Path, required=True)
    parser.add_argument("--iphone-app", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    package(args.simulator_app.resolve(), args.iphone_app.resolve(), args.output_dir.resolve())
