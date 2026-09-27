#!/usr/bin/env python3
"""Generate ignored local Bazel inputs; never prints credentials."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument('--configuration', type=Path, required=True)
parser.add_argument('--profile', type=Path)
parser.add_argument('--unsigned', action='store_true')
args = parser.parse_args()
if not args.unsigned and args.profile is None:
    parser.error('--profile is required unless --unsigned is used')
root = Path(__file__).resolve().parents[2]
config = json.loads(args.configuration.read_text())
version, checksum = json.loads((root / 'versions.json').read_text())['bazel'].split(':')
bazel = root / 'build-input' / f'bazel-{version}-darwin-arm64'
bazel.parent.mkdir(exist_ok=True)
if not bazel.exists():
    urllib.request.urlretrieve(f'https://github.com/bazelbuild/bazel/releases/download/{version}/bazel-{version}-darwin-arm64', bazel)
if hashlib.sha256(bazel.read_bytes()).hexdigest() != checksum:
    raise SystemExit('Bazel checksum mismatch')
bazel.chmod(0o755)
values = {'telegram_bazel_path': str(bazel), 'telegram_use_xcode_managed_codesigning': False}
keys = ['bundle_id', 'api_id', 'api_hash', 'team_id', 'app_center_id', 'is_internal_build', 'is_appstore_build', 'appstore_id', 'app_specific_url_scheme', 'premium_iap_product_id']
for key in keys:
    values['telegram_' + key] = str(config[key])
values.update(telegram_aps_environment='development', telegram_enable_siri=config['enable_siri'], telegram_enable_icloud=config['enable_icloud'], telegram_enable_watch=True)
# Starlark shares Python's bool literals; strings use JSON escaping.
def literal(value):
    return str(value) if isinstance(value, bool) else json.dumps(value)
os.umask(0o077)
directory = root / 'build-input/configuration-repository'
directory.mkdir(parents=True, exist_ok=True)
(directory / 'WORKSPACE').write_text('')
(directory / 'MODULE.bazel').write_text('module(name = "build_configuration")\n')
(directory / 'BUILD').write_text('')
(directory / 'variables.bzl').write_text(''.join(f'{key} = {literal(value)}\n' for key, value in values.items()))
(directory / 'variables.bzl').chmod(0o600)
profiles = directory / 'provisioning'
profiles.mkdir(exist_ok=True)
if args.unsigned:
    # Device rules require a profile input even when codesigning is disabled.
    shutil.copyfile(root / 'build-system/fake-codesigning/profiles/Telegram.mobileprovision', profiles / 'Telegram.mobileprovision')
    (profiles / 'BUILD').write_text('exports_files(["Telegram.mobileprovision"])\n')
else:
    shutil.copyfile(args.profile, profiles / 'Telegram.mobileprovision')
    (profiles / 'BUILD').write_text('exports_files(["Telegram.mobileprovision"])\n')
print('Prepared ignored build inputs. No credentials printed.')
