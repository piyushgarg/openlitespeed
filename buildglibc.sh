#!/usr/bin/env bash
# Build for Debian 12 (bookworm), x86-64, glibc 2.36, without Docker or sudo.
# Requires: Linux x86-64, bubblewrap (bwrap), Python 3.11+, curl, tar, ar.
# Downloads the official buildpack-deps:bookworm OCI image as a filesystem;
# no Docker daemon is used. Runs its GCC/libc in an isolated user namespace.
# Also downloads the official Kitware CMake binary, checking its SHA256.
# All downloaded layers are checked against the registry's SHA256 digests.
# Cached image manifest pins subsequent builds; use a new BUILDGLIBC_DIR to
# refresh the environment. No changes are made to the host's libc or packages.
#
# Usage: ./buildglibc.sh [--strip] [additional buildols.sh/CMake options]
#        ./buildglibc.sh --prepare-only
# Environment: JOBS (default 4), BUILDGLIBC_DIR (default .buildols/debian12).
# Both variants are built with a fresh, separate dependency/build cache.
# Verification includes HTTPS, authentication, compression and server control
# for both variants in Debian 12 with passwd/group NSS configured as compat.
# Outputs: .buildols/debian12/dist/bin/openlitespeed-{static,dynamic}
# Host-built dist/bin binaries are preserved. Copy the target dynamic output
# to ~/ols/dist/bin/openlitespeed-dynamic on the Debian 12 server, then run:
#   ./setupols.sh --variant dynamic --start
# The dynamic variant embeds bundled third-party libraries, including crypto
# and libaio, but uses the target's system libc (minimum supported: 2.36).
# The static glibc variant can still load NSS modules at runtime; it is not a
# universally portable executable. Prefer dynamic on this Debian 12 target.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
WORK=${BUILDGLIBC_DIR:-"$ROOT/.buildols/debian12"}
PREPARE_ONLY=0
case "${1:-}" in
    --help|-h) sed -n '2,/^set -euo pipefail/{ /^set -euo pipefail/d; s/^# \?//; p; }' "$0"; exit 0 ;;
    --prepare-only) PREPARE_ONLY=1; shift ;;
esac
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || { echo 'Requires Linux x86-64.' >&2; exit 1; }
for tool in bwrap python3 curl tar ar; do
    command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done
mkdir -p "$WORK"
WORK=$(cd -- "$WORK" && pwd -P)
mkdir -p "$WORK"/{rootfs,layers,build/downloads,dist/bin,lsquic}
export BUILDGLIBC_WORK="$WORK"
python3 - <<'PY'
import hashlib
import json
import os
from pathlib import Path
import subprocess
import urllib.request

work = Path(os.environ['BUILDGLIBC_WORK'])
registry = 'https://registry-1.docker.io/v2/library/buildpack-deps/'

def get(url, headers=None):
    request = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(request, timeout=120) as response:
        return response.read()

def download(url, path, digest=None):
    if not path.exists():
        print('Downloading ' + path.name, flush=True)
        partial = path.with_suffix(path.suffix + '.part')
        subprocess.run(['curl', '--fail', '--location', '--retry', '3', url,
                        '-o', str(partial)], check=True)
        partial.replace(path)
    if digest and hashlib.file_digest(path.open('rb'), 'sha256').hexdigest() != digest:
        raise SystemExit('SHA256 mismatch: ' + str(path))

manifest_path = work / 'image-manifest.json'
token = json.loads(get('https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/buildpack-deps:pull'))['token']
headers = {'Authorization': 'Bearer ' + token, 'Accept': 'application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'}
if not manifest_path.exists():
    index = json.loads(get(registry + 'manifests/bookworm', headers))
    selected = next(item for item in index['manifests']
                    if item.get('platform', {}).get('os') == 'linux'
                    and item.get('platform', {}).get('architecture') == 'amd64')
    raw = get(registry + 'manifests/' + selected['digest'], headers)
    if 'sha256:' + hashlib.sha256(raw).hexdigest() != selected['digest']:
        raise SystemExit('Manifest SHA256 mismatch')
    manifest_path.write_bytes(raw)
    (work / 'image-digest.txt').write_text(selected['digest'] + '\n')
manifest = json.loads(manifest_path.read_bytes())
ready = work / 'rootfs.ready'
if not ready.exists():
    for layer in manifest['layers']:
        digest = layer['digest']
        if not digest.startswith('sha256:'):
            raise SystemExit('Unsupported layer digest: ' + digest)
        path = work / 'layers' / (digest.split(':')[1] + '.tar.gz')
        if not path.exists():
            print('Downloading Debian build layer ' + digest, flush=True)
            partial = path.with_suffix('.part')
            request = urllib.request.Request(registry + 'blobs/' + digest, headers=headers)
            with urllib.request.urlopen(request, timeout=120) as response, partial.open('wb') as out:
                import shutil
                shutil.copyfileobj(response, out)
            partial.replace(path)
        with path.open('rb') as stream:
            actual = hashlib.file_digest(stream, 'sha256').hexdigest()
        if 'sha256:' + actual != digest:
            raise SystemExit('Layer SHA256 mismatch: ' + str(path))
        subprocess.run(['tar', '--extract', '--gzip', '--no-same-owner',
                        '--file', str(path), '--directory', str(work / 'rootfs')], check=True)
    ready.touch()

# The generic build image omits the Linux capability development headers.
# Fetch Debian's package using its repository metadata/checksum; unpack only
# into the private rootfs, without installing packages on the host.
if not (work / 'rootfs/usr/include/sys/capability.h').exists():
    import lzma
    index = work / 'bookworm-Packages.xz'
    download('https://deb.debian.org/debian/dists/bookworm/main/binary-amd64/Packages.xz', index)
    packages = lzma.decompress(index.read_bytes()).decode()
    record = next(item for item in packages.split('\n\n')
                  if item.startswith('Package: libcap-dev\n'))
    fields = dict(line.split(': ', 1) for line in record.splitlines()
                  if ': ' in line and not line.startswith(' '))
    deb = work / Path(fields['Filename']).name
    download('https://deb.debian.org/debian/' + fields['Filename'], deb, fields['SHA256'])
    member = next(item for item in subprocess.check_output(['ar', 't', str(deb)], text=True).splitlines()
                  if item.startswith('data.tar'))
    archive = work / member
    with archive.open('wb') as stream:
        subprocess.run(['ar', 'p', str(deb), member], stdout=stream, check=True)
    subprocess.run(['tar', '-xf', str(archive), '--no-same-owner',
                    '-C', str(work / 'rootfs')], check=True)

version = '4.0.3'
name = f'cmake-{version}-linux-x86_64.tar.gz'
base = f'https://github.com/Kitware/CMake/releases/download/v{version}/'
sums = work / f'cmake-{version}-SHA-256.txt'
download(base + sums.name, sums)
digest = next(line.split()[0] for line in sums.read_text().splitlines()
              if line.split()[-1] == name)
download(base + name, work / name, digest)
if not (work / 'rootfs/opt/cmake/bin/cmake').exists():
    (work / 'rootfs/opt/cmake').mkdir(parents=True, exist_ok=True)
    subprocess.run(['tar', '-xzf', str(work / name), '--strip-components=1',
                    '--no-same-owner', '-C', str(work / 'rootfs/opt/cmake')], check=True)
# The non-root installer/test needs to resolve the build user's Unix identity.
import pwd
import grp
uid, gid = os.getuid(), os.getgid()
for file, number, entry in (
    ('passwd', uid, f'{pwd.getpwuid(uid).pw_name}:x:{uid}:{gid}:Build user:/tmp/build-home:/bin/bash'),
    ('group', gid, f'{grp.getgrgid(gid).gr_name}:x:{gid}:')):
    path = work / 'rootfs/etc' / file
    if not any(line.split(':')[2] == str(number) for line in path.read_text().splitlines() if line):
        with path.open('a') as stream:
            stream.write(entry + '\n')
# Reproduce the target's compat NSS loading instead of testing only files NSS.
path = work / 'rootfs/etc/nsswitch.conf'
original = path.with_suffix('.conf.original')
if not original.exists():
    original.write_bytes(path.read_bytes())
import re
text = path.read_text()
for database in ('passwd', 'group'):
    text = re.sub(r'^' + database + r':.*$', database + ': compat', text, flags=re.M)
path.write_text(text)
PY
# Reuse only downloaded source archives; never host-compiled libraries/objects.
if [[ -d "$ROOT/.buildols/downloads" ]]; then
    for archive in "$ROOT/.buildols/downloads/"*.tar; do
        [[ ! -f "$archive" || -e "$WORK/build/downloads/${archive##*/}" ]] || cp "$archive" "$WORK/build/downloads/"
    done
fi
# buildols.sh may populate missing QUIC submodules; keep those writes isolated.
if [[ -d "$ROOT/lsquic" ]]; then
    cp -a "$ROOT/lsquic/." "$WORK/lsquic/"
fi
run_target() {
    bwrap --unshare-user --unshare-pid --die-with-parent \
        --bind "$WORK/rootfs" / --proc /proc --dev /dev --tmpfs /tmp \
        --ro-bind "$ROOT" /src --bind "$WORK/build" /work \
        --bind "$WORK/lsquic" /src/lsquic \
        --bind "$WORK/dist/bin" /src/dist/bin \
        --ro-bind /etc/resolv.conf /etc/resolv.conf \
        --chdir /src --clearenv \
        --setenv PATH /opt/cmake/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        --setenv HOME /tmp/build-home --setenv LC_ALL C \
        --setenv BUILDOLS_DIR /work --setenv JOBS "${JOBS:-4}" "$@"
}
run_target bash -c 'getconf GNU_LIBC_VERSION; gcc --version | head -1; cmake --version | head -1'
((!PREPARE_ONLY)) || exit 0
run_target bash /src/buildols.sh --strip "$@"
# Record symbol requirements. Never silently ship a binary newer than the target.
run_target bash -c 'readelf --version-info /src/dist/bin/openlitespeed-dynamic > /work/verification/dynamic-symbol-versions.txt'
python3 - "$WORK/build/verification/dynamic-symbol-versions.txt" <<'PY'
from pathlib import Path
import re
import sys
versions = set(re.findall(r'GLIBC_([0-9.]+)', Path(sys.argv[1]).read_text()))
if not versions:
    raise SystemExit('No glibc version requirements found in dynamic binary')
newest = max(versions, key=lambda item: tuple(map(int, item.split('.'))))
print('Maximum required glibc version: ' + newest)
if tuple(map(int, newest.split('.'))) > (2, 36):
    raise SystemExit('Binary requires glibc newer than the target 2.36')
PY
run_target python3 /src/test/scripts/setupols_test.py
echo "Debian 12 binaries: $WORK/dist/bin"
echo "Verification reports: $WORK/build/verification"
echo 'Recommended for the target: openlitespeed-dynamic (uses system glibc 2.36).'
