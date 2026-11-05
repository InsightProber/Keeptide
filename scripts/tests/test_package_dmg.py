#!/usr/bin/env python3

from pathlib import Path
import hashlib
import json
import plistlib
import tempfile
import unittest
from unittest.mock import patch

import scripts.package_dmg as package_dmg


APP_ENTITLEMENTS = {
    "com.apple.security.app-sandbox": True,
    "com.apple.security.files.user-selected.read-write": True,
    "com.apple.security.files.bookmarks.app-scope": True,
}
HELPER_ENTITLEMENTS = {
    "com.apple.security.app-sandbox": True,
    "com.apple.security.inherit": True,
}


class PackageDmgTests(unittest.TestCase):
    def synthetic_icns(self, chunk_types: tuple[str, ...]) -> bytes:
        chunks = b"".join(
            chunk_type.encode("ascii")
            + (8 + len(package_dmg.PNG_SIGNATURE)).to_bytes(4, "big")
            + package_dmg.PNG_SIGNATURE
            for chunk_type in chunk_types
        )
        return b"icns" + (8 + len(chunks)).to_bytes(4, "big") + chunks

    def make_installer_icon_sources(self, root: Path) -> Path:
        contents = {
            "Keeptide/Resources/AppIcon.icon/icon.json": b"{}",
            "Keeptide/Resources/AppIcon.icon/Assets/Retained Page.svg": b"<svg/>",
            "Keeptide/Resources/AppIcon.icon/Assets/Tide.svg": b"<svg/>",
            package_dmg.INSTALLER_ICON_SOURCE: (
                package_dmg.PNG_SIGNATURE + (13).to_bytes(4, "big") + b"IHDR"
                + (1024).to_bytes(4, "big") + (1024).to_bytes(4, "big") + b"\x08\x06"
            ),
        }
        for relative_path, data in contents.items():
            path = root / relative_path
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        manifest = {
            "schemaVersion": 1,
            "files": {
                relative_path: hashlib.sha256(data).hexdigest()
                for relative_path, data in contents.items()
            },
        }
        manifest_path = root / package_dmg.INSTALLER_ICON_MANIFEST
        manifest_path.write_text(json.dumps(manifest))
        return root / package_dmg.INSTALLER_ICON_SOURCE

    def test_installer_icon_manifest_locks_exact_sources_and_png(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            expected = self.make_installer_icon_sources(root)
            with patch.object(package_dmg, "REPOSITORY_ROOT", root):
                self.assertEqual(package_dmg._verify_installer_icon_sources(), expected)

                tide = root / "Keeptide/Resources/AppIcon.icon/Assets/Tide.svg"
                tide.write_bytes(b"tampered")
                with self.assertRaisesRegex(package_dmg.PackagingError, "digest mismatch"):
                    package_dmg._verify_installer_icon_sources()

    def test_installer_icon_manifest_rejects_extra_file_and_invalid_png(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            png = self.make_installer_icon_sources(root)
            manifest_path = root / package_dmg.INSTALLER_ICON_MANIFEST
            manifest = json.loads(manifest_path.read_text())
            manifest["files"]["unexpected"] = "0" * 64
            manifest_path.write_text(json.dumps(manifest))
            with patch.object(package_dmg, "REPOSITORY_ROOT", root):
                with self.assertRaisesRegex(package_dmg.PackagingError, "unexpected file set"):
                    package_dmg._verify_installer_icon_sources()

                manifest["files"].pop("unexpected")
                png.write_bytes(b"not a PNG")
                manifest["files"][package_dmg.INSTALLER_ICON_SOURCE] = hashlib.sha256(
                    png.read_bytes()
                ).hexdigest()
                manifest_path.write_text(json.dumps(manifest))
                with self.assertRaisesRegex(package_dmg.PackagingError, "1024 x 1024"):
                    package_dmg._verify_installer_icon_sources()

    def test_installer_icon_export_requires_all_png_renditions(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            source = work / "InstallerIcon.png"
            destination = work / "InstallerIcon.icns"
            source.write_bytes(b"synthetic source")
            commands: list[list[str]] = []

            def runner(command: list[str], **_: object) -> str:
                commands.append(command)
                destination.write_bytes(self.synthetic_icns(tuple(package_dmg.INSTALLER_ICON_CHUNKS)))
                return ""

            icon = package_dmg._render_installer_icon(source, destination, work, runner)
            self.assertEqual(icon, destination.read_bytes())
            self.assertEqual(commands[0][:4], ["/usr/bin/xcrun", "--sdk", "macosx", "swift"])
            self.assertEqual(commands[0][-2:], [str(source), str(destination)])

        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            source = work / "InstallerIcon.png"
            destination = work / "InstallerIcon.icns"
            source.write_bytes(b"synthetic source")

            def incomplete(_command: list[str], **_: object) -> str:
                destination.write_bytes(self.synthetic_icns(("ic09", "ic10")))
                return ""

            with self.assertRaisesRegex(package_dmg.PackagingError, "missing required icon sizes"):
                package_dmg._render_installer_icon(source, destination, work, incomplete)

        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            source = work / "InstallerIcon.png"
            destination = work / "InstallerIcon.icns"
            source.write_bytes(b"synthetic source")

            def corrupt(_command: list[str], **_: object) -> str:
                icon = bytearray(
                    self.synthetic_icns(tuple(package_dmg.INSTALLER_ICON_CHUNKS))
                )
                final_png = icon.rfind(package_dmg.PNG_SIGNATURE)
                icon[final_png : final_png + len(package_dmg.PNG_SIGNATURE)] = bytes(
                    len(package_dmg.PNG_SIGNATURE)
                )
                destination.write_bytes(icon)
                return ""

            with self.assertRaisesRegex(package_dmg.PackagingError, "invalid .* icon record"):
                package_dmg._render_installer_icon(source, destination, work, corrupt)

    def test_installer_icon_export_propagates_tool_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)

            def runner(_command: list[str], **_: object) -> str:
                raise package_dmg.PackagingError("synthetic export failure")

            with self.assertRaisesRegex(package_dmg.PackagingError, "synthetic export failure"):
                package_dmg._render_installer_icon(
                    work / "source.png", work / "output.icns", work, runner
                )

    def test_compressed_image_selects_tool_by_macos_major_version(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "writable.dmg"
            source.write_bytes(b"synthetic writable image")
            cases = (
                (
                    "26.6",
                    ["/usr/bin/hdiutil", "convert", str(source), "-format", "UDZO", "-ov", "-o"],
                ),
                (
                    "27.0",
                    ["/usr/sbin/diskutil", "image", "create", "from", "--format", "UDZO", str(source)],
                ),
                (
                    "28.1.2",
                    ["/usr/sbin/diskutil", "image", "create", "from", "--format", "UDZO", str(source)],
                ),
            )
            for index, (version, prefix) in enumerate(cases):
                with self.subTest(version=version):
                    destination = root / f"final-{index}.dmg"
                    commands: list[list[str]] = []

                    def runner(command: list[str], **_: object) -> str:
                        commands.append(command)
                        destination.write_bytes(b"synthetic compressed image")
                        return ""

                    package_dmg._compress_disk_image(
                        source, destination, runner, macos_version=version
                    )
                    self.assertEqual(len(commands), 1)
                    self.assertEqual(commands[0][:-1], prefix)
                    self.assertEqual(commands[0][-1], str(destination))

    def test_compressed_image_uses_detected_version_and_preserves_failure_boundary(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "writable.dmg"
            destination = root / "final.dmg"
            source.write_bytes(b"synthetic writable image")
            commands: list[list[str]] = []

            def runner(command: list[str], **_: object) -> str:
                commands.append(command)
                raise package_dmg.PackagingError("fatal conversion")

            with patch.object(package_dmg.platform, "mac_ver", return_value=("27.2", ("", "", ""), "")):
                with self.assertRaisesRegex(package_dmg.PackagingError, "fatal conversion"):
                    package_dmg._compress_disk_image(source, destination, runner)
            self.assertEqual(len(commands), 1)
            self.assertEqual(commands[0][0], "/usr/sbin/diskutil")
            self.assertFalse(destination.exists())

            with self.assertRaisesRegex(package_dmg.PackagingError, "expected compressed image"):
                package_dmg._compress_disk_image(
                    source, destination, lambda *_args, **_kwargs: "", macos_version="27.2"
                )

    def test_compressed_image_rejects_invalid_or_unsupported_system_version(self):
        calls = 0

        def runner(*_args: object, **_kwargs: object) -> str:
            nonlocal calls
            calls += 1
            return ""

        for version in ("", "unknown", "27.2.1.4", "25.9"):
            with self.subTest(version=version), self.assertRaisesRegex(
                package_dmg.PackagingError, "macOS version|requires macOS 26"
            ):
                package_dmg._compress_disk_image(
                    Path("source.dmg"), Path("destination.dmg"), runner, macos_version=version
                )
        self.assertEqual(calls, 0)

    def test_packaging_build_disables_debug_entitlement_injection(self):
        with tempfile.TemporaryDirectory() as temporary:
            derived = Path(temporary)
            calls = []
            def runner(command, **kwargs):
                calls.append(command)
                (derived / 'Build/Products/Release/Keeptide.app').mkdir(parents=True)
                return ''
            package_dmg._build_app('1.2.3', '7', derived, runner)
            self.assertIn('CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO', calls[0])

    def test_exclusive_publication_preserves_concurrently_created_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / 'staged'
            source.mkdir()
            (source / 'payload').write_text('synthetic')
            output = Path(temporary) / 'published'
            output.mkdir()
            self.assertTrue(hasattr(package_dmg, 'publish_directory'), 'Exclusive publication is missing')
            with self.assertRaises(FileExistsError):
                package_dmg.publish_directory(source, output)
            self.assertTrue(source.is_dir())
            self.assertEqual(list(output.iterdir()), [])
            output.rmdir()
            package_dmg.publish_directory(source, output)
            self.assertEqual((output / 'payload').read_text(), 'synthetic')

    def test_mounted_dmg_accepts_canonical_equivalent_mount_path(self):
        attach_commands: list[list[str]] = []

        def runner(command, **kwargs):
            if command[1] == 'attach':
                attach_commands.append(command)
                mount = Path(command[command.index('-mountpoint') + 1])
                return plistlib.dumps({'system-entities': [{'mount-point': str(mount.resolve()),
                                                           'dev-entry': '/dev/disk99s1'}]}).decode()
            return ''
        with package_dmg.mounted_dmg(Path('synthetic.dmg'), runner, read_only=False) as mount:
            self.assertTrue(mount.is_dir())
        self.assertIn("-readwrite", attach_commands[0])
        self.assertNotIn("-readonly", attach_commands[0])

    def test_mounted_package_requires_exact_license_copy(self):
        with tempfile.TemporaryDirectory() as temporary:
            mount = Path(temporary)
            expected_icon = b"icns\x00\x00\x00\x10TOC \x00\x00\x00\x08"
            (mount / 'Applications').symlink_to('/Applications')
            (mount / 'README.txt').write_text(package_dmg.README_TEXT)
            with patch.object(package_dmg, 'verify_app_bundle'):
                with self.assertRaisesRegex(package_dmg.PackagingError, 'license'):
                    package_dmg._verify_mounted_contents(
                        mount, '1.2.3', '7', expected_icon, self.validating_runner
                    )
                (mount / 'LICENSE.txt').write_text('incomplete synthetic license')
                with self.assertRaisesRegex(package_dmg.PackagingError, 'license'):
                    package_dmg._verify_mounted_contents(
                        mount, '1.2.3', '7', expected_icon, self.validating_runner
                    )
                (mount / 'LICENSE.txt').write_bytes((package_dmg.REPOSITORY_ROOT / 'LICENSE').read_bytes())
                with self.assertRaisesRegex(package_dmg.PackagingError, 'notice'):
                    package_dmg._verify_mounted_contents(
                        mount, '1.2.3', '7', expected_icon, self.validating_runner
                    )
                (mount / 'NOTICE.txt').write_bytes((package_dmg.REPOSITORY_ROOT / 'NOTICE').read_bytes())
                (mount / '.VolumeIcon.icns').write_bytes(expected_icon)
                package_dmg._set_custom_icon_flag(mount)
                package_dmg._verify_mounted_contents(
                    mount, '1.2.3', '7', expected_icon, self.validating_runner
                )

    def test_parse_version_returns_numeric_bundle_version(self):
        self.assertEqual(package_dmg.parse_version("1.2.3"), "1.2.3")
        self.assertEqual(package_dmg.parse_version("1234.56.78-rc.9"), "1234.56.78")

    def test_parse_version_rejects_unsafe_or_non_apple_versions(self):
        invalid = (
            "v1.2.3",
            "1.2",
            "1.2.3.4",
            "01.2.3",
            "12345.1.1",
            "1.123.1",
            "1.2.3-preview.1",
            "1.2.3-rc.0",
            "1.2.3/../../bad",
        )
        for value in invalid:
            with self.subTest(value=value), self.assertRaises(ValueError):
                package_dmg.parse_version(value)

    def test_validate_build_number_accepts_positive_bounded_decimal(self):
        self.assertEqual(package_dmg.validate_build_number("1"), "1")
        self.assertEqual(package_dmg.validate_build_number("9999"), "9999")

    def test_validate_build_number_rejects_zero_leading_zero_and_large_values(self):
        for value in ("0", "01", "10000", "-1", "1.0", "build-1"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                package_dmg.validate_build_number(value)

    def make_app(self, root: Path, version: str = "1.2.3", build: str = "7") -> Path:
        app = root / "Keeptide.app"
        (app / "Contents" / "MacOS").mkdir(parents=True)
        (app / "Contents" / "Helpers").mkdir(parents=True)
        (app / "Contents" / "Resources").mkdir(parents=True)
        (app / "Contents" / "MacOS" / "Keeptide").write_bytes(b"app")
        (app / "Contents" / "Helpers" / "KeeptidePasteboardReader").write_bytes(b"helper")
        (app / "Contents" / "Resources" / "Keeptide.icns").write_bytes(
            b"icns\x00\x00\x00\x10TOC \x00\x00\x00\x08"
        )
        with (app / "Contents" / "Info.plist").open("wb") as stream:
            plistlib.dump(
                {
                    "CFBundleIdentifier": "io.github.insightprober.Keeptide",
                    "CFBundleShortVersionString": version,
                    "CFBundleVersion": build,
                    "CFBundleExecutable": "Keeptide",
                    "CFBundleIconFile": "Keeptide.icns",
                    "LSMinimumSystemVersion": "26.0",
                },
                stream,
            )
        return app

    def validating_runner(self, command: list[str], **_: object) -> str:
        if command[:2] == ["/usr/bin/lipo", "-archs"]:
            return "arm64\n"
        if command[:3] == ["/usr/bin/codesign", "-d", "--entitlements"]:
            target = Path(command[-1])
            entitlements = HELPER_ENTITLEMENTS if target.name == "KeeptidePasteboardReader" else APP_ENTITLEMENTS
            return plistlib.dumps(entitlements).decode("utf-8")
        if command[:3] == ["/usr/bin/codesign", "-d", "-vvv"]:
            return "Executable=/synthetic\nSignature=adhoc\n"
        if command[0] == "/usr/bin/codesign":
            return ""
        raise AssertionError(f"unexpected command: {command}")

    def test_verify_app_bundle_checks_identity_versions_architecture_and_entitlements(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(Path(directory))
            package_dmg.verify_app_bundle(app, "1.2.3", "7", self.validating_runner)

    def test_verify_app_bundle_rejects_missing_or_unsafe_icon_reference(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(Path(directory))
            info_path = app / "Contents" / "Info.plist"
            with info_path.open("rb") as stream:
                info = plistlib.load(stream)

            for icon_name in (None, "", "../Keeptide.icns", "Folder/Keeptide.icns"):
                with self.subTest(icon_name=icon_name):
                    updated = dict(info)
                    if icon_name is None:
                        updated.pop("CFBundleIconFile")
                    else:
                        updated["CFBundleIconFile"] = icon_name
                    with info_path.open("wb") as stream:
                        plistlib.dump(updated, stream)
                    with self.assertRaisesRegex(package_dmg.PackagingError, "icon"):
                        package_dmg.verify_app_bundle(app, "1.2.3", "7", self.validating_runner)

    def test_verify_app_bundle_rejects_malformed_or_symlinked_icon(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = self.make_app(root)
            icon = app / "Contents" / "Resources" / "Keeptide.icns"
            for invalid in (
                b"not-an-icns",
                b"icns\x00\x00\x00\x11TOC \x00\x00\x00\x08",
            ):
                with self.subTest(invalid=invalid):
                    icon.write_bytes(invalid)
                    with self.assertRaisesRegex(package_dmg.PackagingError, "icon"):
                        package_dmg.verify_app_bundle(app, "1.2.3", "7", self.validating_runner)

            icon.unlink()
            external = root / "external.icns"
            external.write_bytes(b"icns\x00\x00\x00\x10TOC \x00\x00\x00\x08")
            icon.symlink_to(external)
            with self.assertRaisesRegex(package_dmg.PackagingError, "icon"):
                package_dmg.verify_app_bundle(app, "1.2.3", "7", self.validating_runner)

    def test_mounted_package_requires_exact_icon_and_custom_volume_flag(self):
        with tempfile.TemporaryDirectory() as temporary:
            mount = Path(temporary)
            (mount / "Applications").symlink_to("/Applications")
            (mount / "README.txt").write_text(package_dmg.README_TEXT)
            for source_name in ("LICENSE", "NOTICE"):
                (mount / f"{source_name}.txt").write_bytes(
                    (package_dmg.REPOSITORY_ROOT / source_name).read_bytes()
                )
            expected_icon = b"icns\x00\x00\x00\x10TOC \x00\x00\x00\x08"
            (mount / ".VolumeIcon.icns").write_bytes(expected_icon)

            with patch.object(package_dmg, "verify_app_bundle"):
                with self.assertRaisesRegex(package_dmg.PackagingError, "custom icon flag"):
                    package_dmg._verify_mounted_contents(
                        mount, "1.2.3", "7", expected_icon, self.validating_runner
                    )

                package_dmg._set_custom_icon_flag(mount)
                package_dmg._verify_mounted_contents(
                    mount, "1.2.3", "7", expected_icon, self.validating_runner
                )

                (mount / ".VolumeIcon.icns").write_bytes(expected_icon + b"changed")
                with self.assertRaisesRegex(package_dmg.PackagingError, "volume icon"):
                    package_dmg._verify_mounted_contents(
                        mount, "1.2.3", "7", expected_icon, self.validating_runner
                    )

    def test_verify_app_bundle_rejects_test_products(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(Path(directory))
            (app / "Contents" / "PlugIns" / "Leak.xctest").mkdir(parents=True)
            with self.assertRaisesRegex(package_dmg.PackagingError, "test product"):
                package_dmg.verify_app_bundle(app, "1.2.3", "7", self.validating_runner)

    def test_verify_app_bundle_rejects_extra_entitlement(self):
        def runner(command: list[str], **kwargs: object) -> str:
            output = self.validating_runner(command, **kwargs)
            if command[:3] == ["/usr/bin/codesign", "-d", "--entitlements"] and command[-1].endswith("/Keeptide"):
                return plistlib.dumps({**APP_ENTITLEMENTS, "com.apple.security.network.client": True}).decode("utf-8")
            return output

        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(Path(directory))
            with self.assertRaisesRegex(package_dmg.PackagingError, "entitlements"):
                package_dmg.verify_app_bundle(app, "1.2.3", "7", runner)

    def test_verify_app_bundle_rejects_non_adhoc_signature(self):
        def runner(command: list[str], **kwargs: object) -> str:
            if command[:3] == ["/usr/bin/codesign", "-d", "-vvv"]:
                return "Executable=/synthetic\nAuthority=Developer ID Application: Example\n"
            return self.validating_runner(command, **kwargs)

        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(Path(directory))
            with self.assertRaisesRegex(package_dmg.PackagingError, "ad-hoc"):
                package_dmg.verify_app_bundle(app, "1.2.3", "7", runner)

    def test_package_release_refuses_existing_output_before_running_commands(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            output.mkdir()
            with patch.object(package_dmg, "run_command") as runner:
                with self.assertRaisesRegex(package_dmg.PackagingError, "already exists"):
                    package_dmg.package_release("1.2.3", "7", output)
            runner.assert_not_called()

    def test_package_release_leaves_no_output_when_build_fails(self):
        def runner(command: list[str], **_: object) -> str:
            self.assertEqual(command[0], "/usr/bin/xcodebuild")
            raise package_dmg.PackagingError("synthetic build failure")

        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            with self.assertRaisesRegex(package_dmg.PackagingError, "synthetic build failure"):
                package_dmg.package_release("1.2.3", "7", output, runner)
            self.assertFalse(output.exists())

    def test_mounted_dmg_detaches_when_validation_fails(self):
        commands: list[list[str]] = []

        def runner(command: list[str], **_: object) -> str:
            commands.append(command)
            if command[1] == "attach":
                mount_point = command[command.index("-mountpoint") + 1]
                return plistlib.dumps(
                    {"system-entities": [{"mount-point": mount_point, "dev-entry": "/dev/disk99s1"}]}
                ).decode("utf-8")
            return ""

        with tempfile.TemporaryDirectory() as directory:
            dmg = Path(directory) / "Keeptide.dmg"
            dmg.write_bytes(b"dmg")
            with self.assertRaisesRegex(RuntimeError, "validation failed"):
                with package_dmg.mounted_dmg(dmg, runner):
                    raise RuntimeError("validation failed")

        self.assertEqual(commands[-1][:2], ["/usr/bin/hdiutil", "detach"])
        self.assertEqual(commands[-1][-1], "/dev/disk99s1")

    def test_mounted_dmg_detaches_known_mountpoint_when_metadata_is_malformed(self):
        commands: list[list[str]] = []

        def runner(command: list[str], **_: object) -> str:
            commands.append(command)
            return "not a plist" if command[1] == "attach" else ""

        with tempfile.TemporaryDirectory() as directory:
            dmg = Path(directory) / "Keeptide.dmg"
            dmg.write_bytes(b"dmg")
            with self.assertRaisesRegex(package_dmg.PackagingError, "mount metadata"):
                with package_dmg.mounted_dmg(dmg, runner):
                    self.fail("malformed metadata must not yield a mounted path")

        attach = commands[0]
        expected_mount = attach[attach.index("-mountpoint") + 1]
        self.assertEqual(commands[-1], ["/usr/bin/hdiutil", "detach", expected_mount])


if __name__ == "__main__":
    unittest.main()
