#!/usr/bin/env python3
"""Prepare release metadata and upload verified assets to an existing release."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
from urllib.parse import quote

from package_dmg import parse_version, validate_build_number


def git(*args):
    return subprocess.check_output(['git', *args], text=True).strip()


def event_version(event_name, event, build_number):
    validate_build_number(build_number)
    tag = ''
    if event_name == 'release':
        release = event['release']
        if event.get('action') != 'published' or release.get('draft') or not release.get('published_at'):
            raise ValueError('Only published releases may upload assets')
        tag = release['tag_name']
        if not tag.startswith('v'):
            raise ValueError('Release tags must start with v')
        version = tag[1:]
    elif event_name == 'pull_request':
        version = f'0.0.0-alpha.{build_number}'
    elif event_name == 'workflow_dispatch':
        version = event.get('inputs', {}).get('version', '')
    else:
        raise ValueError('Unsupported packaging event')
    parse_version(version)
    return version, tag


def verify_source(tag):
    sha = git('rev-parse', 'HEAD')
    if not re.fullmatch(r'[0-9a-f]{40}', sha):
        raise ValueError('Expected a full commit SHA')
    if tag:
        if git('rev-parse', '--verify', f'refs/tags/{tag}^{{commit}}') != sha:
            raise ValueError('Checkout does not match the release tag')
        git('merge-base', '--is-ancestor', sha, 'refs/remotes/origin/main')
    return sha


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def load_assets(directory):
    info_path = directory / 'build-info.json'
    if info_path.is_symlink() or not info_path.is_file():
        raise ValueError('Expected a regular build manifest')
    info = json.loads(info_path.read_text())
    parse_version(info['version'])
    validate_build_number(info['build_number'])
    if info['tag'] != 'v' + info['version'] or not re.fullmatch(r'[0-9a-f]{40}', info['commit']):
        raise ValueError('Invalid release manifest')
    if info.get('signing') != 'ad-hoc' or info.get('notarized') is not False:
        raise ValueError('Unexpected signing claim')
    name = f"Keeptide-{info['version']}-macOS-arm64.dmg"
    files = [directory / name, directory / (name + '.sha256'), info_path]
    if set(directory.iterdir()) != set(files):
        raise ValueError('Artifact contains missing or unexpected files')
    if any(path.is_symlink() or not path.is_file() for path in files):
        raise ValueError('Assets must be regular files')
    expected = f'{digest(files[0])}  {name}\n'
    if files[1].read_text() != expected:
        raise ValueError('DMG checksum does not match')
    return info, files


def gh_json(endpoint, paginate=False):
    command = ['gh', 'api', endpoint]
    if paginate:
        command += ['--paginate', '--slurp']
    return json.loads(subprocess.check_output(command, text=True))


def verify_release(repository, release_id, info):
    release = gh_json(f'repos/{repository}/releases/{release_id}')
    if str(release['id']) != release_id or release['tag_name'] != info['tag'] or release['draft'] or not release.get('published_at'):
        raise ValueError('Release identity or publication state changed')
    commit = gh_json(f"repos/{repository}/commits/{quote(info['tag'], safe='')}")
    if commit['sha'] != info['commit']:
        raise ValueError('Release tag no longer matches the packaged commit')


def needs_upload(path, remote_assets):
    matches = [asset for asset in remote_assets if asset['name'] == path.name]
    if not matches:
        return True
    if len(matches) != 1:
        raise ValueError(f'Duplicate remote assets: {path.name}')
    asset = matches[0]
    if (asset.get('state') != 'uploaded' or asset.get('size') != path.stat().st_size
            or asset.get('digest') != 'sha256:' + digest(path)):
        raise ValueError(f'Existing asset differs or cannot be verified: {path.name}; refusing to overwrite')
    return False


def publish(directory, repository, release_id):
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository) or not re.fullmatch(r'[1-9][0-9]*', release_id):
        raise ValueError('Invalid repository or release identity')
    info, files = load_assets(directory)
    if git('rev-parse', 'HEAD') != info['commit']:
        raise ValueError('Publisher checkout differs from build manifest')
    verify_release(repository, release_id, info)
    endpoint = f'repos/{repository}/releases/{release_id}/assets?per_page=100'
    assets = [asset for page in gh_json(endpoint, paginate=True) for asset in page]
    # Check every conflict before any upload. No --clobber and no release creation.
    pending = [path for path in files if needs_upload(path, assets)]
    for path in pending:
        # Bind the external write to the validated ID, never re-resolve a mutable tag.
        upload_url = (f'https://uploads.github.com/repos/{repository}/releases/{release_id}/assets'
                      f'?name={quote(path.name, safe="")}')
        subprocess.run(['gh', 'api', upload_url, '--method', 'POST',
                        '-H', 'Content-Type: application/octet-stream', '--input', str(path)],
                       check=True, stdout=subprocess.DEVNULL)
    verify_release(repository, release_id, info)
    uploaded = [asset for page in gh_json(endpoint, paginate=True) for asset in page]
    if any(needs_upload(path, uploaded) for path in files):
        raise ValueError('Release upload readback is incomplete')
    print('Release assets verified; existing matching assets were preserved.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('prepare')
    upload = commands.add_parser('publish')
    upload.add_argument('--directory', type=Path, required=True)
    upload.add_argument('--repository', required=True)
    upload.add_argument('--release-id', required=True)
    args = parser.parse_args()
    if args.command == 'publish':
        publish(args.directory, args.repository, args.release_id)
        return
    event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
    build_number = os.environ['GITHUB_RUN_NUMBER']
    version, tag = event_version(os.environ['GITHUB_EVENT_NAME'], event, build_number)
    sha = verify_source(tag)
    info = dict(version=version, tag=tag, commit=sha, build_number=build_number,
                signing='ad-hoc', notarized=False)
    with Path(os.environ['GITHUB_OUTPUT']).open('a') as stream:
        stream.write(f'version={version}\ncommit={sha}\n')
    print(json.dumps(info, indent=2))


if __name__ == '__main__':
    main()
