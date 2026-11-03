"""Release metadata and publication boundaries; all content is synthetic."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/release_dmg.py'
sys.path.insert(0, str(ROOT / 'scripts'))


class ReleaseDMGTests(unittest.TestCase):
    def module(self):
        self.assertTrue(SCRIPT.exists(), 'Release orchestration is missing')
        spec = importlib.util.spec_from_file_location('release_dmg', SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_release_requires_published_existing_version_tag(self):
        module = self.module()
        valid = {'action': 'published', 'release': {'id': 123, 'tag_name': 'v1.2.3-rc.1', 'draft': False, 'published_at': '2026-11-03'}}
        self.assertEqual(module.event_version('release', valid, '42'), ('1.2.3-rc.1', 'v1.2.3-rc.1'))
        for tag in ['1.2.3', 'v1.2.3\ncontents=write', 'v1.2.3;echo hi', '../v1.2.3', 'v1.2']:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                module.event_version('release', {**valid, 'release': {**valid['release'], 'tag_name': tag}}, '42')
        for change in [{'draft': True}, {'published_at': None}]:
            with self.assertRaises(ValueError):
                module.event_version('release', {**valid, 'release': {**valid['release'], **change}}, '42')

    def test_pr_and_manual_prepare_do_not_select_a_release(self):
        module = self.module()
        self.assertEqual(module.event_version('pull_request', {}, '42'), ('0.0.0-alpha.42', ''))
        self.assertEqual(module.event_version('workflow_dispatch', {'inputs': {'version': '1.2.3'}}, '42'), ('1.2.3', ''))
        with self.assertRaises(ValueError):
            module.event_version('push', {}, '42')

    def test_release_source_must_equal_tag_and_belong_to_main(self):
        module = self.module()
        sha = 'a' * 40
        with patch.object(module, 'git', side_effect=[sha, sha, '']):
            self.assertEqual(module.verify_source('v1.2.3'), sha)
        with patch.object(module, 'git', side_effect=[sha, 'b' * 40]):
            with self.assertRaises(ValueError):
                module.verify_source('v1.2.3')
        import subprocess
        with patch.object(module, 'git', side_effect=[sha, sha, subprocess.CalledProcessError(1, 'git')]):
            with self.assertRaises(subprocess.CalledProcessError):
                module.verify_source('v1.2.3')

    def test_source_check_against_real_temporary_git_history(self):
        module = self.module()
        import subprocess
        with tempfile.TemporaryDirectory() as temporary:
            def local_git(*args):
                return subprocess.check_output(['git', '-C', temporary, *args], text=True, stderr=subprocess.PIPE).strip()
            local_git('init', '--initial-branch=main')
            local_git('config', 'user.name', 'Synthetic Test')
            local_git('config', 'user.email', 'synthetic@example.invalid')
            local_git('commit', '--allow-empty', '-m', 'fixture')
            sha = local_git('rev-parse', 'HEAD')
            local_git('update-ref', 'refs/remotes/origin/main', sha)
            local_git('tag', '-a', 'v1.2.3', '-m', 'fixture')
            with patch.object(module, 'git', side_effect=local_git):
                self.assertEqual(module.verify_source('v1.2.3'), sha)
            local_git('commit', '--allow-empty', '-m', 'unmerged')
            local_git('tag', 'v1.2.4')
            with patch.object(module, 'git', side_effect=local_git):
                with self.assertRaises(subprocess.CalledProcessError):
                    module.verify_source('v1.2.4')
                with self.assertRaises(ValueError):
                    module.verify_source('v1.2.3')

    def fixture(self, directory):
        version = '1.2.3-rc.1'
        dmg = directory / f'Keeptide-{version}-macOS-arm64.dmg'
        dmg.write_bytes(b'synthetic disk image')
        digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
        (directory / (dmg.name + '.sha256')).write_text(f'{digest}  {dmg.name}\n')
        (directory / 'build-info.json').write_text(json.dumps({'version': version, 'tag': 'v' + version, 'commit': 'a' * 40, 'build_number': '42', 'signing': 'ad-hoc', 'notarized': False}))
        return dmg

    def test_assets_must_match_manifest_and_checksum(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            dmg = self.fixture(directory)
            info, files = module.load_assets(directory)
            self.assertEqual(info['commit'], 'a' * 40)
            self.assertEqual(len(files), 3)
            dmg.write_bytes(b'changed')
            with self.assertRaises(ValueError):
                module.load_assets(directory)

    def test_symlink_and_extra_asset_are_rejected(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            dmg = self.fixture(directory)
            (directory / 'private.txt').write_text('synthetic unrelated content')
            with self.assertRaises(ValueError):
                module.load_assets(directory)
            (directory / 'private.txt').unlink()
            dmg.unlink()
            dmg.symlink_to(directory / 'build-info.json')
            with self.assertRaises(ValueError):
                module.load_assets(directory)

    def test_same_remote_asset_is_idempotent_and_conflicts_fail(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as temporary:
            file = Path(temporary) / 'Keeptide.dmg'
            file.write_bytes(b'synthetic')
            digest = hashlib.sha256(file.read_bytes()).hexdigest()
            matching = {'name': file.name, 'state': 'uploaded', 'size': file.stat().st_size, 'digest': 'sha256:' + digest}
            self.assertFalse(module.needs_upload(file, [matching]))
            self.assertTrue(module.needs_upload(file, []))
            for change in [{'digest': 'sha256:' + '0' * 64}, {'size': 0}, {'state': 'starter'}, {'digest': None}]:
                with self.assertRaises(ValueError):
                    module.needs_upload(file, [{**matching, **change}])

    def test_publish_refuses_tag_drift_or_wrong_release_before_upload(self):
        module = self.module()
        info = {'tag': 'v1.2.3', 'commit': 'a' * 40}
        release = {'id': 123, 'tag_name': 'v1.2.3', 'draft': False, 'published_at': '2026-11-03'}
        with patch.object(module, 'gh_json', side_effect=[release, {'sha': 'b' * 40}]):
            with self.assertRaises(ValueError):
                module.verify_release('owner/repo', '123', info)
        with patch.object(module, 'gh_json', return_value={**release, 'tag_name': 'v9.9.9'}):
            with self.assertRaises(ValueError):
                module.verify_release('owner/repo', '123', info)


    def test_publish_uploads_only_missing_files_and_verifies_readback(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.fixture(directory)
            _, files = module.load_assets(directory)
            assets = [{'name': path.name, 'state': 'uploaded', 'size': path.stat().st_size,
                       'digest': 'sha256:' + module.digest(path)} for path in files]
            with patch.object(module, 'git', return_value='a' * 40), \
                    patch.object(module, 'verify_release') as verify, \
                    patch.object(module, 'gh_json', side_effect=[[assets[:1]], [assets]]), \
                    patch.object(module.subprocess, 'run') as upload:
                module.publish(directory, 'owner/repo', '123')
                self.assertEqual(upload.call_count, 2)
                commands = [call.args[0] for call in upload.call_args_list]
                for command, file in zip(commands, files[1:]):
                    self.assertEqual(command[:2], ['gh', 'api'])
                    self.assertIn('https://uploads.github.com/repos/owner/repo/releases/123/assets?name=' + file.name, command)
                    self.assertIn(str(file), command)
                    self.assertIn('--input', command)
                    self.assertNotIn('v1.2.3-rc.1', command)
                self.assertEqual(verify.call_count, 2)
            with patch.object(module, 'git', return_value='a' * 40), \
                    patch.object(module, 'verify_release'), \
                    patch.object(module, 'gh_json', side_effect=[[assets], [assets]]), \
                    patch.object(module.subprocess, 'run') as upload:
                module.publish(directory, 'owner/repo', '123')
                upload.assert_not_called()

    def test_publish_conflict_prevents_all_uploads(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.fixture(directory)
            conflict = {'name': 'build-info.json', 'state': 'uploaded', 'size': 0, 'digest': None}
            with patch.object(module, 'git', return_value='a' * 40), \
                    patch.object(module, 'verify_release'), \
                    patch.object(module, 'gh_json', return_value=[[conflict]]), \
                    patch.object(module.subprocess, 'run') as upload:
                with self.assertRaises(ValueError):
                    module.publish(directory, 'owner/repo', '123')
                upload.assert_not_called()


if __name__ == '__main__':
    unittest.main()
