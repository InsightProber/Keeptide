#!/usr/bin/env python3
"""Build and verify an ad-hoc signed Keeptide release disk image."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import ctypes
import errno
import hashlib
import json
import os
from pathlib import Path
import platform
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
    "com.apple.security.network.client": True,
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
FINDER_INFO_ATTRIBUTE = "com.apple.FinderInfo"
FINDER_FLAG_OFFSET = 8
FINDER_FLAG_HAS_CUSTOM_ICON = 0x0400
MAX_ICON_BYTES = 32 * 1024 * 1024
INSTALLER_ICON_SOURCE = "Keeptide/Resources/InstallerIcon.png"
INSTALLER_ICON_MANIFEST = "Keeptide/Resources/InstallerIcon.source.json"
INSTALLER_ICON_SOURCES = (
    "Keeptide/Resources/AppIcon.icon/icon.json",
    "Keeptide/Resources/AppIcon.icon/Assets/Retained Page.svg",
    "Keeptide/Resources/AppIcon.icon/Assets/Tide.svg",
    INSTALLER_ICON_SOURCE,
)
INSTALLER_ICON_CHUNKS = frozenset(
    {"icp4", "ic11", "icp5", "ic12", "ic07", "ic13", "ic08", "ic14", "ic09", "ic10"}
)
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


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


def _read_icns(resource: Path, description: str, required_chunks: frozenset[str] = frozenset()) -> bytes:
    if not resource.is_file() or resource.is_symlink():
        raise PackagingError(f"{description} is missing or invalid: {resource}")
    try:
        icon = resource.read_bytes()
    except OSError as error:
        raise PackagingError(f"{description} cannot be read: {resource}") from error
    if not 16 <= len(icon) <= MAX_ICON_BYTES or icon[:4] != b"icns":
        raise PackagingError(f"{description} is not a valid icns container")
    if int.from_bytes(icon[4:8], byteorder="big") != len(icon):
        raise PackagingError(f"{description} has an invalid icns length")
    chunks: set[str] = set()
    offset = 8
    while offset < len(icon):
        if offset + 8 > len(icon):
            raise PackagingError(f"{description} has a truncated icns record")
        chunk_type = icon[offset : offset + 4].decode("ascii", errors="replace")
        chunk_length = int.from_bytes(icon[offset + 4 : offset + 8], byteorder="big")
        if chunk_length < 8 or offset + chunk_length > len(icon):
            raise PackagingError(f"{description} has an invalid icns record")
        if (chunk_type in required_chunks
                and icon[offset + 8 : offset + 16] != PNG_SIGNATURE):
            raise PackagingError(f"{description} has an invalid {chunk_type} icon record")
        chunks.add(chunk_type)
        offset += chunk_length
    missing = required_chunks - chunks
    if missing:
        raise PackagingError(f"{description} is missing required icon sizes: {sorted(missing)}")
    return icon


def _application_icon(app: Path, info: dict[str, object]) -> bytes:
    icon_name = info.get("CFBundleIconFile")
    if not isinstance(icon_name, str) or not icon_name:
        raise PackagingError("application icon declaration is missing or invalid")
    if Path(icon_name).name != icon_name or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", icon_name) is None:
        raise PackagingError("application icon declaration must be a safe resource name")
    icon_path = Path(icon_name)
    if icon_path.suffix not in ("", ".icns"):
        raise PackagingError("application icon declaration must reference an icns resource")
    if not icon_path.suffix:
        icon_path = icon_path.with_suffix(".icns")
    resource = app / "Contents" / "Resources" / icon_path.name
    return _read_icns(resource, "application icon resource")


def _verify_installer_icon_sources() -> Path:
    manifest_path = REPOSITORY_ROOT / INSTALLER_ICON_MANIFEST
    if not manifest_path.is_file() or manifest_path.is_symlink():
        raise PackagingError("installer icon source manifest is missing or invalid")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise PackagingError("installer icon source manifest is unreadable") from error
    if not isinstance(manifest, dict) or set(manifest) != {"schemaVersion", "files"}:
        raise PackagingError("installer icon source manifest has an invalid structure")
    files = manifest.get("files")
    if manifest.get("schemaVersion") != 1 or not isinstance(files, dict):
        raise PackagingError("installer icon source manifest has an unsupported schema")
    if set(files) != set(INSTALLER_ICON_SOURCES):
        raise PackagingError("installer icon source manifest has an unexpected file set")
    png_data: bytes | None = None
    for relative_path in INSTALLER_ICON_SOURCES:
        expected = files.get(relative_path)
        source = REPOSITORY_ROOT / relative_path
        if (not isinstance(expected, str) or re.fullmatch(r"[0-9a-f]{64}", expected) is None
                or not source.is_file() or source.is_symlink()):
            raise PackagingError(f"installer icon source is missing or invalid: {relative_path}")
        try:
            source_data = source.read_bytes()
        except OSError as error:
            raise PackagingError(f"installer icon source cannot be read: {relative_path}") from error
        if hashlib.sha256(source_data).hexdigest() != expected:
            raise PackagingError(f"installer icon source digest mismatch: {relative_path}")
        if relative_path == INSTALLER_ICON_SOURCE:
            png_data = source_data
    png = REPOSITORY_ROOT / INSTALLER_ICON_SOURCE
    header = (png_data or b"")[:26]
    if (len(header) != 26 or header[:8] != PNG_SIGNATURE
            or header[12:16] != b"IHDR"
            or int.from_bytes(header[16:20], "big") != 1024
            or int.from_bytes(header[20:24], "big") != 1024
            or header[24:26] != b"\x08\x06"):
        raise PackagingError("installer icon PNG must be 1024 x 1024 8-bit RGBA")
    return png


def _render_installer_icon(source: Path, destination: Path, work: Path, runner: CommandRunner) -> bytes:
    module_cache = work / "SwiftModuleCache"
    module_cache.mkdir()
    runner(
        [
            "/usr/bin/xcrun", "--sdk", "macosx", "swift",
            "-module-cache-path", str(module_cache),
            str(REPOSITORY_ROOT / "scripts" / "render_installer_icon.swift"),
            str(source), str(destination),
        ]
    )
    return _read_icns(destination, "rendered installer icon", INSTALLER_ICON_CHUNKS)


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
    _application_icon(app, info)

    test_products = sorted(app.rglob("*.xctest"))
    if test_products:
        raise PackagingError(f"application contains test product: {test_products[0]}")

    main_executable = app / "Contents" / "MacOS" / "Keeptide"
    helper = app / "Contents" / "Helpers" / "KeeptidePasteboardReader"
    _verify_executable(main_executable, APP_ENTITLEMENTS, runner)
    _verify_executable(helper, HELPER_ENTITLEMENTS, runner)
    runner(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)])


@contextmanager
def mounted_dmg(
    dmg: Path,
    runner: CommandRunner = run_command,
    *,
    read_only: bool = True,
) -> Iterator[Path]:
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
                    "-readonly" if read_only else "-readwrite",
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


def _finder_info(path: Path) -> bytes | None:
    getxattr = ctypes.CDLL(None, use_errno=True).getxattr
    getxattr.argtypes = [
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_void_p,
        ctypes.c_size_t,
        ctypes.c_uint32,
        ctypes.c_int,
    ]
    getxattr.restype = ctypes.c_ssize_t
    encoded_path = os.fsencode(path)
    encoded_name = FINDER_INFO_ATTRIBUTE.encode("ascii")
    size = getxattr(encoded_path, encoded_name, None, 0, 0, 0)
    if size < 0:
        error_code = ctypes.get_errno()
        missing_codes = {getattr(errno, "ENOATTR", 93), getattr(errno, "ENODATA", -1)}
        if error_code in missing_codes:
            return None
        raise PackagingError(
            f"could not read Finder metadata for {path}: {os.strerror(error_code)}"
        )
    buffer = ctypes.create_string_buffer(size)
    actual_size = getxattr(encoded_path, encoded_name, buffer, size, 0, 0)
    if actual_size != size:
        error_code = ctypes.get_errno()
        detail = os.strerror(error_code) if actual_size < 0 else "metadata changed while reading"
        raise PackagingError(f"could not read Finder metadata for {path}: {detail}")
    value = buffer.raw
    if len(value) != 32:
        raise PackagingError(f"Finder metadata has an invalid length for {path}")
    return value


def _set_custom_icon_flag(path: Path) -> None:
    finder_info = bytearray(_finder_info(path) or bytes(32))
    flags = int.from_bytes(finder_info[FINDER_FLAG_OFFSET : FINDER_FLAG_OFFSET + 2], "big")
    finder_info[FINDER_FLAG_OFFSET : FINDER_FLAG_OFFSET + 2] = (
        flags | FINDER_FLAG_HAS_CUSTOM_ICON
    ).to_bytes(2, "big")
    setxattr = ctypes.CDLL(None, use_errno=True).setxattr
    setxattr.argtypes = [
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_void_p,
        ctypes.c_size_t,
        ctypes.c_uint32,
        ctypes.c_int,
    ]
    setxattr.restype = ctypes.c_int
    value = bytes(finder_info)
    buffer = ctypes.create_string_buffer(value)
    result = setxattr(
        os.fsencode(path),
        FINDER_INFO_ATTRIBUTE.encode("ascii"),
        buffer,
        len(value),
        0,
        0,
    )
    if result != 0:
        error_code = ctypes.get_errno()
        raise PackagingError(
            f"could not set Finder custom icon flag for {path}: {os.strerror(error_code)}"
        )


def _has_custom_icon_flag(path: Path) -> bool:
    finder_info = _finder_info(path)
    if finder_info is None:
        return False
    flags = int.from_bytes(finder_info[FINDER_FLAG_OFFSET : FINDER_FLAG_OFFSET + 2], "big")
    return bool(flags & FINDER_FLAG_HAS_CUSTOM_ICON)


def _verify_mounted_contents(
    mount_point: Path,
    version: str,
    build_number: str,
    expected_volume_icon: bytes,
    runner: CommandRunner,
) -> None:
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
    volume_icon = mount_point / ".VolumeIcon.icns"
    if (not volume_icon.is_file() or volume_icon.is_symlink()
            or volume_icon.read_bytes() != expected_volume_icon):
        raise PackagingError("disk image volume icon is missing or invalid")
    if not _has_custom_icon_flag(mount_point):
        raise PackagingError("disk image Finder custom icon flag is missing")
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


def _compress_disk_image(
    source: Path,
    destination: Path,
    runner: CommandRunner,
    *,
    macos_version: str | None = None,
) -> None:
    version = macos_version if macos_version is not None else platform.mac_ver()[0]
    match = re.fullmatch(r"([0-9]+)(?:\.[0-9]+){0,2}", version)
    if match is None:
        raise PackagingError(f"could not determine a valid macOS version: {version!r}")
    major_version = int(match.group(1))
    if major_version < 26:
        raise PackagingError(f"DMG packaging requires macOS 26 or newer, found {version}")
    if major_version >= 27:
        command = [
            "/usr/sbin/diskutil",
            "image",
            "create",
            "from",
            "--format",
            "UDZO",
            str(source),
            str(destination),
        ]
    else:
        command = [
            "/usr/bin/hdiutil",
            "convert",
            str(source),
            "-format",
            "UDZO",
            "-ov",
            "-o",
            str(destination),
        ]
    runner(command)
    if not destination.is_file():
        raise PackagingError("disk image conversion did not produce the expected compressed image")


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
    installer_icon_source = _verify_installer_icon_sources()
    filename = f"Keeptide-{full_version}-macOS-arm64.dmg"
    with tempfile.TemporaryDirectory(prefix="keeptide-dmg-build-") as work_directory:
        work = Path(work_directory)
        app = _build_app(version, build_number, work / "DerivedData", runner)
        verify_app_bundle(app, version, build_number, runner)
        volume_icon = _render_installer_icon(
            installer_icon_source, work / "KeeptideInstaller.icns", work, runner
        )

        staging = work / "volume"
        staging.mkdir()
        runner(["/usr/bin/ditto", str(app), str(staging / "Keeptide.app")])
        (staging / "Applications").symlink_to("/Applications")
        (staging / "README.txt").write_text(README_TEXT, encoding="utf-8")
        for source_name in ("LICENSE", "NOTICE"):
            shutil.copyfile(REPOSITORY_ROOT / source_name, staging / f"{source_name}.txt")
        (staging / ".VolumeIcon.icns").write_bytes(volume_icon)
        writable_dmg = work / "Keeptide-writable.dmg"
        runner(
            [
                "/usr/bin/hdiutil",
                "create",
                "-srcfolder",
                str(staging),
                "-volname",
                f"Keeptide {full_version}",
                "-format",
                "UDRW",
                "-ov",
                str(writable_dmg),
            ]
        )
        if not writable_dmg.is_file():
            raise PackagingError("hdiutil did not produce the expected writable disk image")
        with mounted_dmg(writable_dmg, runner, read_only=False) as mount_point:
            _set_custom_icon_flag(mount_point)
            _verify_mounted_contents(
                mount_point, version, build_number, volume_icon, runner
            )
        temporary_dmg = work / filename
        _compress_disk_image(writable_dmg, temporary_dmg, runner)
        runner(["/usr/bin/hdiutil", "verify", str(temporary_dmg)])
        with mounted_dmg(temporary_dmg, runner) as mount_point:
            _verify_mounted_contents(
                mount_point, version, build_number, volume_icon, runner
            )

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
