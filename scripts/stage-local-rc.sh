#!/usr/bin/env bash
# Artifact assembly only. This deliberately does not source build-release.sh.
set -euo pipefail
[[ $# == 2 ]] || { echo 'Usage: stage-local-rc.sh NEW_AGENTS_DIRECTORY PORTABLE_BIN_DIRECTORY' >&2; exit 1; }
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT_DIR" "$1" "$2" <<'PY'
import os, pathlib, plistlib, shutil, subprocess, sys
root = pathlib.Path(sys.argv[1]).resolve()
allowed = root / '.agents'
target = pathlib.Path(sys.argv[2]).absolute()
bin_dir = pathlib.Path(sys.argv[3]).resolve()
# Resolve before creating anything. Existing outputs are never modified.
if ('..' in target.parts or target != target.resolve() or target.exists()
        or not target.parent.is_dir() or not target.resolve().is_relative_to(allowed.resolve())
        or target == allowed or not bin_dir.is_relative_to(allowed.resolve())
        or not (bin_dir / 'SpeakFlow').is_file()):
    sys.exit('Refused: require a new directory under .agents and a staged portable binary')

def run(*args):
    subprocess.run(args, check=True, cwd=root)

try:
    target.mkdir()  # Exclusive creation, preserve any failed assembly for diagnosis.
    app = target / 'SpeakFlow.app'
    macos = app / 'Contents/MacOS'
    resources = app / 'Contents/Resources'
    macos.mkdir(parents=True)
    resources.mkdir()
    shutil.copy2(bin_dir / 'SpeakFlow', macos / 'SpeakFlow')
    run('swift', str(root / 'scripts/release-resources.swift'), 'package', str(bin_dir), str(app))
    linked = subprocess.check_output(['otool', '-L', str(macos / 'SpeakFlow')], text=True)
    if 'Sparkle.framework/' in linked:
        subprocess.run(['bash', str(root / 'scripts/embed-sparkle.sh'), str(bin_dir), str(app)],
                       check=True, env={**os.environ, 'SPEAKFLOW_SIGNING_IDENTITY': '-'})
    iconset = target / 'AppIcon.iconset'
    iconset.mkdir()
    for size in (16, 32, 128, 256, 512):
        for scale, suffix in ((1, ''), (2, '@2x')):
            run('sips', '-z', str(size * scale), str(size * scale),
                str(root / 'Sources/Resources/AppIcon.png'), '--out',
                str(iconset / f'icon_{size}x{size}{suffix}.png'))
    run('iconutil', '-c', 'icns', str(iconset), '-o', str(resources / 'AppIcon.icns'))
    commit = subprocess.check_output(['git', 'rev-parse', '--verify', 'HEAD'], cwd=root, text=True).strip()
    with (app / 'Contents/Info.plist').open('wb') as file:
        plistlib.dump({
            'CFBundleExecutable': 'SpeakFlow', 'CFBundleIdentifier': 'nu.rez.speakflow.local-review',
            'CFBundleName': 'SpeakFlow', 'CFBundleDisplayName': 'SpeakFlow Local Review',
            'CFBundleVersion': '0.0.0', 'CFBundleShortVersionString': '0.0.0',
            'SpeakFlowDisplayVersion': '0.0.0-local-review', 'SpeakFlowBuildGitCommit': commit,
            'CFBundlePackageType': 'APPL', 'CFBundleIconFile': 'AppIcon',
            'LSMinimumSystemVersion': '26.0', 'LSUIElement': True,
            'NSMicrophoneUsageDescription': 'SpeakFlow needs microphone access to transcribe speech.',
        }, file)
    # Ad-hoc only. No keychain queries, installed identity copying or notary step.
    run('codesign', '--force', '--deep', '--sign', '-', str(app))
    run('codesign', '--verify', '--deep', '--strict', str(app))
    run('bash', str(root / 'scripts/verify-artifact-privacy.sh'), str(app))
except (OSError, subprocess.CalledProcessError):
    sys.exit('Local RC assembly failed; partial staged output retained')
print('PASS: artifact-only local RC staged (ad-hoc, not notarized, not installed or launched)')
PY
