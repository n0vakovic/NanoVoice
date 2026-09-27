"""Run the actual capture implementation on macOS with Homebrew opus/ogg installed."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'submodules/TelegramUI/Sources/WalkVoiceSession.swift').read_text()
with tempfile.TemporaryDirectory(prefix='nanovoice-capture-') as temp:
    out = Path(temp)
    def run(*args):
        subprocess.run(args, cwd=root, check=True)
    binding = root / 'submodules/OpusBinding'
    run('clang', '-dynamiclib', '-fobjc-arc', '-framework', 'Foundation',
        '-I/opt/homebrew/include', '-I' + str(binding / 'PublicHeaders/OpusBinding'),
        '-I' + str(binding / 'Sources/opusenc'), str(binding / 'Sources/TGDataItem.m'),
        str(binding / 'Sources/opusenc/opusenc.m'), str(binding / 'Sources/opusenc/opus_header.c'),
        '-L/opt/homebrew/lib', '-lopus', '-logg', '-o', str(out / 'libCaptureOpus.dylib'))
    (out / 'Bridge.h').write_text('\n'.join('#import "' + str(binding / 'PublicHeaders/OpusBinding' / h) + '"' for h in ['TGOggOpusWriter.h', 'TGDataItem.h']))
    (out / 'main.swift').write_text('import Foundation\nimport AVFoundation\n' + source[source.index('private enum WalkVoiceError'):] + '\n' + (root / 'Tests/WalkLive/capture-main.swift').read_text())
    run('swiftc', '-module-cache-path', str(out / 'cache'), '-import-objc-header', str(out / 'Bridge.h'), str(out / 'main.swift'), '-L' + str(out), '-lCaptureOpus', '-o', str(out / 'test'))
    run(str(out / 'test'), str(out / 'capture.ogg'))
    run('ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'default=noprint_wrappers=1', str(out / 'capture.ogg'))
