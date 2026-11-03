#!/usr/bin/env python3
"""Build and verify an ad-hoc signed Keeptide release disk image."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import ctypes
import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from collections.abc import Callable, Iterator, Sequence


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
VERSION_PATTERN = re.compile(
    r"(?P<base>(?:0|[1-9][0-9]{0,3})\.(?:0|[1-9][0-9]?)\.(?:0|[1-9][0-9]?))"
    r"(?:-(?:alpha|beta|rc)\.(?:[1-9][0-9]{0,3}))?\Z"
)
APP_IDENTIFIER = "io.github.insightprober.Keeptide"
APP_ENTITLEMENTS = {
    "com.apple.security.app-sandbox": True,
    "com.apple.security.files.user-selected.read-write": True,
    "com.apple.security.files.bookmarks.app-scope": True,
}
HELPER_ENTITLEMENTS = {
    "com.apple.security.app-sandbox": True,
    "com.apple.security.inherit": True,
}
README_TEXT = """Keeptide for macOS

Drag Keeptide.app to Applications to install it.

This automated build is ad-hoc signed for integrity checks. It is not signed
with an Apple Developer ID and has not been notarized by Apple. macOS may block
it on other computers. It is intended for project testing until the official
distribution signing and notarization process is configured.

License and attribution are provided in LICENSE.txt and NOTICE.txt.
"""


class PackagingError(RuntimeError):
    """The release package failed validation or could not be created safely."""


CommandRunner = Callable[..., str]


def parse_version(value: str) -> str:
    """Validate a release version and return its numeric Apple bundle version."""
    match = VERSION_PATTERN.fullmatch(value)
    if match is None:
        raise ValueError(
            "version must be MAJOR.MINOR.PATCH with optional -alpha.N, -beta.N, or -rc.N; "
            "release version components are limited to 4, 2, and 2 digits"
        )
    return match.group("base")


def validate_build_number(value: str) -> str:
    if re.fullmatch(r"[1-9][0-9]{0,3}", value) is None:
        raise ValueError("build number must be a decimal integer from 1 through 9999")
    return value


def run_command(command: Sequence[str], *, cwd: Path | None = None) -> str:
    completed = subprocess.run(
        list(command),
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    stdout = completed.stdout.decode("utf-8", errors="replace")
    stderr = completed.stderr.decode("utf-8", errors="replace")
    if completed.returncode != 0:
        rendered = " ".join(command)
        raise PackagingError(f"command failed ({completed.returncode}): {rendered}\n{stdout}{stderr}")
    return stdout if stdout else stderr


def _load_entitlements(output: str, target: Path) -> dict[str, object]:
    xml_start = output.find("<?xml")
    xml_end = output.find("</plist>", xml_start)
    if xml_start < 0 or xml_end < 0:
        raise PackagingError(f"codesign returned no entitlement plist for {target}")
    try:
        value = plistlib.loads(output[xml_start : xml_end + len("</plist>")].encode("utf-8"))
    except (plistlib.InvalidFileException, ValueError) as error:
        raise PackagingError(f"codesign returned invalid entitlements for {target}") from error
    if not isinstance(value, dict):
        raise PackagingError(f"codesign returned invalid entitlements for {target}")
    return value


def _verify_executable(executable: Path, expected_entitlements: dict[str, object], runner: CommandRunner) -> None:
    if not executable.is_file():
        raise PackagingError(f"required executable is missing: {executable}")
    architectures = runner(["/usr/bin/lipo", "-archs", str(executable)]).split()
    if architectures != ["arm64"]:
        raise PackagingError(f"{executable.name} must contain only arm64, found: {architectures}")
    runner(["/usr/bin/codesign", "--verify", "--strict", "--verbose=2", str(executable)])
    signature_details = runner(["/usr/bin/codesign", "-d", "-vvv", str(executable)])
    if re.search(r"(?m)^Signature=adhoc$", signature_details) is None:
        raise PackagingError(f"{executable.name} is not ad-hoc signed")
    entitlement_output = runner(
        ["/usr/bin/codesign", "-d", "--entitlements", ":-", "--xml", str(executable)]
    )
    actual_entitlements = _load_entitlements(entitlement_output, executable)
    if actual_entitlements != expected_entitlements:
        raise PackagingError(
            f"unexpected entitlements for {executable.name}: {actual_entitlements!r}"
        )


def verify_app_bundle(app: Path, version: str, build_number: str, runner: CommandRunner = run_command) -> None:
    info_path = app / "Contents" / "Info.plist"
    try:
        with info_path.open("rb") as stream:
            info = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException) as error:
        raise PackagingError(f"invalid application Info.plist: {info_path}") from error

    expected_info = {
        "CFBundleIdentifier": APP_IDENTIFIER,
        "CFBundleShortVersionString": version,
        "CFBundleVersion": build_number,
        "CFBundleExecutable": "Keeptide",
        "LSMinimumSystemVersion": "26.0",
    }
    for key, expected in expected_info.items():
        if info.get(key) != expected:
            raise PackagingError(f"unexpected {key}: {info.get(key)!r}; expected {expected!r}")

    test_products = sorted(app.rglob("*.xctest"))
    if test_products:
        raise PackagingError(f"application contains test product: {test_products[0]}")

    main_executable = app / "Contents" / "MacOS" / "Keeptide"
    helper = app / "Contents" / "Helpers" / "KeeptidePasteboardReader"
    _verify_executable(main_executable, APP_ENTITLEMENTS, runner)
    _verify_executable(helper, HELPER_ENTITLEMENTS, runner)
    runner(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)])


@contextmanager
def mounted_dmg(dmg: Path, runner: CommandRunner = run_command) -> Iterator[Path]:
    with tempfile.TemporaryDirectory(prefix="keeptide-dmg-mount-") as mount_directory:
        mount_point = Path(mount_directory) / "Keeptide"
        mount_point.mkdir()
        attached = False
        detach_target = str(mount_point)
        try:
            output = runner(
                [
                    "/usr/bin/hdiutil",
                    "attach",
                    "-readonly",
                    "-nobrowse",
                    "-noautoopen",
                    "-mountpoint",
                    str(mount_point),
                    "-plist",
                    str(dmg),
                ]
            )
            attached = True
            try:
                attach_info = plistlib.loads(output.encode("utf-8"))
                entities = attach_info.get("system-entities", [])
                mounted_entities = [entity for entity in entities if entity.get("mount-point")]
            except (AttributeError, plistlib.InvalidFileException, TypeError, ValueError) as error:
                raise PackagingError("hdiutil returned invalid mount metadata") from error
            if len(mounted_entities) != 1:
                raise PackagingError(f"expected one mounted volume, found {len(mounted_entities)}")
            mounted_entity = mounted_entities[0]
            if Path(mounted_entity["mount-point"]).resolve() != mount_point.resolve():
                raise PackagingError("hdiutil mounted the image at an unexpected path")
            device = mounted_entity.get("dev-entry")
            if isinstance(device, str) and device.startswith("/dev/"):
                detach_target = device
            yield mount_point
        finally:
            if attached:
                runner(["/usr/bin/hdiutil", "detach", detach_target])


def _build_app(version: str, build_number: str, derived_data: Path, runner: CommandRunner) -> Path:
    runner(
        [
            "/usr/bin/xcodebuild",
            "-project",
            "Keeptide.xcodeproj",
            "-scheme",
            "Keeptide",
            "-configuration",
            "Release",
            "-destination",
            "platform=macOS,arch=arm64",
            "-derivedDataPath",
            str(derived_data),
            "build",
            "ARCHS=arm64",
            "ONLY_ACTIVE_ARCH=YES",
            "CODE_SIGN_STYLE=Manual",
            "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO",
            "CODE_SIGNING_ALLOWED=YES",
            "CODE_SIGNING_REQUIRED=NO",
            "CODE_SIGN_IDENTITY=-",
            "DEVELOPMENT_TEAM=",
            f"KEEPTIDE_MARKETING_VERSION={version}",
            f"KEEPTIDE_BUILD_NUMBER={build_number}",
        ],
        cwd=REPOSITORY_ROOT,
    )
    app = derived_data / "Build" / "Products" / "Release" / "Keeptide.app"
    if not app.is_dir():
        raise PackagingError(f"xcodebuild did not produce the expected application: {app}")
    return app


def _verify_mounted_contents(mount_point: Path, version: str, build_number: str, runner: CommandRunner) -> None:
    app = mount_point / "Keeptide.app"
    applications = mount_point / "Applications"
    readme = mount_point / "README.txt"
    if not applications.is_symlink() or os.readlink(applications) != "/Applications":
        raise PackagingError("disk image Applications link is missing or invalid")
    if not readme.is_file() or readme.read_text(encoding="utf-8") != README_TEXT:
        raise PackagingError("disk image release notice is missing or invalid")
    for source_name in ("LICENSE", "NOTICE"):
        bundled = mount_point / f"{source_name}.txt"
        if (not bundled.is_file() or bundled.is_symlink()
                or bundled.read_bytes() != (REPOSITORY_ROOT / source_name).read_bytes()):
            raise PackagingError(f"disk image {source_name.lower()} is missing or invalid")
    verify_app_bundle(app, version, build_number, runner)


def publish_directory(source: Path, destination: Path) -> None:
    """Atomically publish on macOS without replacing even an empty directory."""
    rename = ctypes.CDLL(None, use_errno=True).renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    # RENAME_EXCL is defined in the macOS SDK's public sys/stdio.h.
    if rename(os.fsencode(source), os.fsencode(destination), 0x00000004) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(destination))


def package_release(
    full_version: str,
    build_number: str,
    output: Path,
    runner: CommandRunner = run_command,
) -> tuple[Path, Path]:
    version = parse_version(full_version)
    build_number = validate_build_number(build_number)
    output = output.absolute()
    if output.exists() or output.is_symlink():
        raise PackagingError(f"output path already exists: {output}")

    output.parent.mkdir(parents=True, exist_ok=True)
    filename = f"Keeptide-{full_version}-macOS-arm64.dmg"
    with tempfile.TemporaryDirectory(prefix="keeptide-dmg-build-") as work_directory:
        work = Path(work_directory)
        app = _build_app(version, build_number, work / "DerivedData", runner)
        verify_app_bundle(app, version, build_number, runner)

        staging = work / "volume"
        staging.mkdir()
        runner(["/usr/bin/ditto", str(app), str(staging / "Keeptide.app")])
        (staging / "Applications").symlink_to("/Applications")
        (staging / "README.txt").write_text(README_TEXT, encoding="utf-8")
        for source_name in ("LICENSE", "NOTICE"):
            shutil.copyfile(REPOSITORY_ROOT / source_name, staging / f"{source_name}.txt")
        temporary_dmg = work / filename
        runner(
            [
                "/usr/bin/hdiutil",
                "create",
                "-srcfolder",
                str(staging),
                "-volname",
                f"Keeptide {full_version}",
                "-format",
                "UDZO",
                "-ov",
                str(temporary_dmg),
            ]
        )
        if not temporary_dmg.is_file():
            raise PackagingError("hdiutil did not produce the expected disk image")
        runner(["/usr/bin/hdiutil", "verify", str(temporary_dmg)])
        with mounted_dmg(temporary_dmg, runner) as mount_point:
            _verify_mounted_contents(mount_point, version, build_number, runner)

        digest = hashlib.sha256(temporary_dmg.read_bytes()).hexdigest()
        final_stage = Path(tempfile.mkdtemp(prefix=".keeptide-release-", dir=output.parent))
        try:
            staged_dmg = final_stage / filename
            staged_checksum = final_stage / f"{filename}.sha256"
            shutil.copy2(temporary_dmg, staged_dmg)
            staged_checksum.write_text(f"{digest}  {filename}\n", encoding="ascii")
            publish_directory(final_stage, output)
        except BaseException:
            shutil.rmtree(final_stage, ignore_errors=True)
            raise

    return output / filename, output / f"{filename}.sha256"


def main(arguments: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True, help="Release version without a leading v")
    parser.add_argument("--build-number", required=True, help="Positive CI build number (1-9999)")
    parser.add_argument("--output", required=True, type=Path, help="New output directory")
    options = parser.parse_args(arguments)
    try:
        dmg, checksum = package_release(options.version, options.build_number, options.output)
    except (PackagingError, ValueError) as error:
        parser.error(str(error))
    print(dmg)
    print(checksum)
    return 0


if __name__ == "__main__":
    sys.exit(main())
