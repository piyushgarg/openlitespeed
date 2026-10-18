#!/usr/bin/env bash
# Build and verify static and dynamically linked Linux servers without system installs.
# Usage: ./buildols.sh [--strip] [additional CMake options]
# JOBS=4 BUILDOLS_DIR=/path/to/cache ./buildols.sh
# Optional PageSpeed, ModSecurity and Lua modules are off by default.
# Outputs: dist/bin/openlitespeed-static and dist/bin/openlitespeed-dynamic.
# dist/bin/openlitespeed remains a copy of the static version for compatibility.
# The dynamic version retains upstream's static bundled third-party libraries.
set -euo pipefail
STRIP_BINARIES=0
CMAKE_OPTIONS=()
while (($#)); do
    case "$1" in
        --strip) STRIP_BINARIES=1; shift ;;
        --help|-h)
            cat <<'EOF'
Usage: ./buildols.sh [--strip] [additional CMake options]

Build and verify static and dynamic OpenLiteSpeed binaries in dist/bin/.
  --strip   Remove debug information and symbol tables from output binaries.
            Unstripped binaries remain in the build directories.
  --help    Show this help.

Additional options are passed to CMake for both builds.
Environment: JOBS (default: 4), BUILDOLS_DIR (default: .buildols).
EOF
            exit 0 ;;
        --) shift; CMAKE_OPTIONS+=("$@"); break ;;
        *) CMAKE_OPTIONS+=("$1"); shift ;;
    esac
done
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
WORK=${BUILDOLS_DIR:-"$ROOT/.buildols"}
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)
PREFIX="$WORK/prefix"
JOBS=${JOBS:-4}
export CFLAGS="-fPIC -O2"
export CXXFLAGS="-fPIC -O2"
# Keep library names out of LDFLAGS: link ordering belongs to each build system.
export LDFLAGS="-static-libgcc -static-libstdc++"
unset CPPFLAGS LIBS
mkdir -p "$WORK/downloads" "$WORK/src" "$PREFIX/lib" "$PREFIX/include"
for tool in curl tar cmake make gcc g++ autoconf automake libtoolize perl readelf file ldd cmp; do
    command -v "$tool" >/dev/null || { echo "Missing build tool: $tool" >&2; exit 1; }
done
if ((STRIP_BINARIES)); then
    command -v strip >/dev/null || { echo 'Missing build tool: strip' >&2; exit 1; }
fi
[[ $(uname -s) == Linux ]] || { echo 'These builds require Linux.' >&2; exit 1; }

fetch() {
    local name=$1 url=$2
    if [[ ! -d "$WORK/src/$name" ]]; then
        if [[ ! -f "$WORK/downloads/$name.tar" ]]; then
            curl --fail --location --retry 3 "$url" -o "$WORK/downloads/$name.tar.part"
            mv "$WORK/downloads/$name.tar.part" "$WORK/downloads/$name.tar"
        fi
        mkdir -p "$WORK/src/$name"
        tar -xf "$WORK/downloads/$name.tar" --strip-components=1 -C "$WORK/src/$name"
    fi
}
cmake_lib() {
    local name=$1
    shift
    cmake -S "$WORK/src/$name" -B "$WORK/src/$name/_build" \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_SHARED_LIBS=OFF "$@"
    cmake --build "$WORK/src/$name/_build" --parallel "$JOBS"
    cmake --install "$WORK/src/$name/_build"
}

if [[ ! -f "$PREFIX/lib/libz.a" ]]; then
    fetch zlib https://zlib.net/fossils/zlib-1.3.1.tar.gz
    (cd "$WORK/src/zlib"; ./configure --static --prefix="$PREFIX"; make -j"$JOBS"; make install)
fi
if [[ ! -f "$PREFIX/lib/libpcre2-8.a" ]]; then
    fetch pcre2 https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.45/pcre2-10.45.tar.gz
    cmake_lib pcre2 -DPCRE2_SUPPORT_JIT=ON -DPCRE2_BUILD_TESTS=OFF -DPCRE2_BUILD_PCRE2GREP=OFF
fi
if [[ ! -f "$PREFIX/lib/libexpat.a" ]]; then
    fetch expat https://github.com/libexpat/libexpat/releases/download/R_2_7_3/expat-2.7.3.tar.xz
    cmake_lib expat -DEXPAT_SHARED_LIBS=OFF -DEXPAT_BUILD_TESTS=OFF -DEXPAT_BUILD_TOOLS=OFF -DEXPAT_BUILD_EXAMPLES=OFF -DEXPAT_BUILD_DOCS=OFF
fi
if [[ ! -f "$PREFIX/lib/libbrotlienc-static.a" ]]; then
    fetch brotli https://github.com/google/brotli/archive/refs/tags/v1.1.0.tar.gz
    cmake_lib brotli -DBROTLI_DISABLE_TESTS=ON
    # The server expects the names used by the older third-party build.
    for lib in enc dec common; do
        cp "$PREFIX/lib/libbrotli$lib.a" "$PREFIX/lib/libbrotli$lib-static.a"
    done
fi
if [[ ! -f "$PREFIX/lib/libcrypto.a" || ! -f "$PREFIX/.bssl-ols" ]]; then
    fetch bssl https://github.com/google/boringssl/archive/8b43ff0f72137b31b23d482f0b2344186d797b03.tar.gz
    # Match LiteSpeed's bssl_apk_keep_privkey.patch: async signing calls
    # SSL_get_privatekey() after installing the private key method.
    sed -i 's/^  cred_impl->privkey = nullptr;$/  \/\/ Keep the key for LiteSpeed async signing./' "$WORK/src/bssl/ssl/ssl_credential.cc"
    cmake -S "$WORK/src/bssl" -B "$WORK/src/bssl/_build" \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_SHARED_LIBS=OFF
    cmake --build "$WORK/src/bssl/_build" --parallel "$JOBS" --target ssl crypto decrepit
    for lib in ssl crypto decrepit; do
        cp "$WORK/src/bssl/_build/lib$lib.a" "$PREFIX/lib/"
    done
    cp -R "$WORK/src/bssl/include/openssl" "$PREFIX/include/"
    touch "$PREFIX/.bssl-ols"
fi
if [[ ! -f "$PREFIX/lib/libaio.a" ]]; then
    fetch libaio https://archive.ubuntu.com/ubuntu/pool/main/liba/libaio/libaio_0.3.113.orig.tar.gz
    (cd "$WORK/src/libaio"; make -j"$JOBS"; cp src/libaio.a "$PREFIX/lib/"; cp src/libaio.h "$PREFIX/include/")
fi
if [[ ! -f "$PREFIX/lib/libudns.a" ]]; then
    fetch udns https://github.com/ortclib/udns/archive/e0148dfba90ce0d17a8e2cae15f218b5ab99ad62.tar.gz
    # Its legacy configure probes omit prototypes, rejected by modern GCC.
    (cd "$WORK/src/udns"; CFLAGS="$CFLAGS -std=gnu89" ./configure; make -j"$JOBS"; cp libudns.a "$PREFIX/lib/"; cp udns.h "$PREFIX/include/")
fi
if [[ ! -f "$PREFIX/lib/libbcrypt.a" ]]; then
    fetch bcrypt https://github.com/litespeedtech/libbcrypt/archive/55ff64349dec3012cfbbb1c4f92d4dbd46920213.tar.gz
    (cd "$WORK/src/bcrypt"; make -j"$JOBS"; cp bcrypt.a "$PREFIX/lib/libbcrypt.a"; cp bcrypt.h "$PREFIX/include/")
fi
if [[ ! -f "$PREFIX/lib/libcrypt.a" ]]; then
    fetch crypt https://github.com/besser82/libxcrypt/releases/download/v4.4.38/libxcrypt-4.4.38.tar.xz
    (cd "$WORK/src/crypt"; CFLAGS="$CFLAGS -std=gnu17" ./configure --prefix="$PREFIX" --libdir="$PREFIX/lib" --disable-shared --enable-static --disable-werror; make -j"$JOBS"; make install)
fi
if [[ ! -f "$PREFIX/lib/libmaxminddb.a" ]]; then
    fetch maxmind https://github.com/maxmind/libmaxminddb/releases/download/1.12.2/libmaxminddb-1.12.2.tar.gz
    (cd "$WORK/src/maxmind"; ./configure --prefix="$PREFIX" --libdir="$PREFIX/lib" --disable-shared --enable-static --disable-binaries; make -j"$JOBS"; make install)
fi
if [[ ! -f "$PREFIX/lib/libIP2Location.a" ]]; then
    fetch ip2loc https://github.com/chrislim2888/IP2Location-C-Library/archive/refs/tags/8.6.1.tar.gz
    (cd "$WORK/src/ip2loc"; autoreconf -fi; ./configure --prefix="$PREFIX" --libdir="$PREFIX/lib" --disable-shared --enable-static; make -j"$JOBS"; make install)
fi
if [[ ! -f "$PREFIX/lib/libxml2.a" ]]; then
    fetch libxml2 https://download.gnome.org/sources/libxml2/2.15/libxml2-2.15.3.tar.xz
    cmake_lib libxml2 -DLIBXML2_WITH_PYTHON=OFF -DLIBXML2_WITH_TESTS=OFF -DLIBXML2_WITH_PROGRAMS=OFF -DLIBXML2_WITH_ICONV=OFF -DLIBXML2_WITH_ZLIB=OFF -DLIBXML2_WITH_LZMA=OFF
fi

# Populate missing submodules without a forced git checkout of existing work.
if [[ ! -f "$ROOT/lsquic/CMakeLists.txt" ]]; then
    fetch lsquic "https://github.com/litespeedtech/lsquic/archive/$(tr -d '\n' < "$ROOT/LSQUICCOMMIT").tar.gz"
    mkdir -p "$ROOT/lsquic"
    cp -R "$WORK/src/lsquic/." "$ROOT/lsquic/"
fi
# Revisions recorded by the LSQUIC commit in LSQUICCOMMIT.
if [[ ! -f "$ROOT/lsquic/src/lshpack/hpack.c" ]]; then
    fetch lshpack https://github.com/litespeedtech/ls-hpack/archive/cf0f70dd10b352194c97448eb5d00b4aa484f531.tar.gz
    mkdir -p "$ROOT/lsquic/src/lshpack"
    cp -R "$WORK/src/lshpack/." "$ROOT/lsquic/src/lshpack/"
fi
if [[ ! -f "$ROOT/lsquic/src/liblsquic/ls-qpack/lsqpack.c" ]]; then
    fetch lsqpack https://github.com/litespeedtech/ls-qpack/archive/91567706c41c0d97ab8dc576873ecd472d7869fa.tar.gz
    mkdir -p "$ROOT/lsquic/src/liblsquic/ls-qpack"
    cp -R "$WORK/src/lsqpack/." "$ROOT/lsquic/src/liblsquic/ls-qpack/"
fi

# CMake uses PCRE2 and the current server sources; the legacy configure script
# does not implement --enable-static-pcre or --enable-static-ssl.
build_server() {
    local mode=$1 build_dir=$2
    shift 2
    local -a link_options
    if [[ "$mode" == static ]]; then
        link_options=(
            -DCMAKE_LINK_SEARCH_START_STATIC=ON -DCMAKE_LINK_SEARCH_END_STATIC=ON
            "-DCMAKE_EXE_LINKER_FLAGS=-L$PREFIX/lib -static -static-libgcc -static-libstdc++ -Wl,--gc-sections"
            # Rescan GCC and libc archives to resolve their circular references.
            "-DCMAKE_CXX_STANDARD_LIBRARIES=-Wl,--start-group -lgcc -lgcc_eh -lc -Wl,--end-group"
        )
    else
        link_options=(
            -DCMAKE_LINK_SEARCH_START_STATIC=OFF -DCMAKE_LINK_SEARCH_END_STATIC=OFF
            "-DCMAKE_EXE_LINKER_FLAGS=-L$PREFIX/lib -Wl,--gc-sections"
            -DCMAKE_CXX_STANDARD_LIBRARIES=
        )
    fi
    echo "Building $mode OpenLiteSpeed in $build_dir"
    cmake -S "$ROOT" -B "$build_dir" \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_BUILD_TYPE=Release \
        -DGIT_SUBMODULE=OFF -DMOD_PAGESPEED=OFF -DMOD_SECURITY=OFF -DMOD_LUA=OFF \
        -DCMAKE_C_FLAGS="$CFLAGS -I$PREFIX/include -I$PREFIX/include/libxml2" \
        -DCMAKE_CXX_FLAGS="$CXXFLAGS -I$PREFIX/include -I$PREFIX/include/libxml2" \
        "${link_options[@]}" "$@"
    cmake --build "$build_dir" --target openlitespeed --parallel "$JOBS"
}

REPORTS="$WORK/verification"
mkdir -p "$REPORTS"
verify_server() {
    local mode=$1 binary=$2
    file "$binary" > "$REPORTS/$mode-file.txt"
    readelf --wide --program-headers "$binary" > "$REPORTS/$mode-program-headers.txt"
    readelf --wide --dynamic "$binary" > "$REPORTS/$mode-dynamic-section.txt"
    if [[ "$mode" == static ]]; then
        if grep -q INTERP "$REPORTS/$mode-program-headers.txt" || \
           grep -q NEEDED "$REPORTS/$mode-dynamic-section.txt"; then
            echo 'ERROR: the static binary still depends on shared libraries.' >&2
            return 1
        fi
    else
        if ! grep -q INTERP "$REPORTS/$mode-program-headers.txt" || \
           ! grep -q NEEDED "$REPORTS/$mode-dynamic-section.txt"; then
            echo 'ERROR: the dynamic binary lacks an interpreter or shared dependencies.' >&2
            return 1
        fi
        if ! ldd "$binary" > "$REPORTS/$mode-ldd.txt" 2>&1 || \
           grep -q 'not found' "$REPORTS/$mode-ldd.txt"; then
            cat "$REPORTS/$mode-ldd.txt" >&2
            echo 'ERROR: the dynamic binary has unresolved shared dependencies.' >&2
            return 1
        fi
        cat "$REPORTS/$mode-ldd.txt"
    fi
    "$binary" -v > "$REPORTS/$mode-version.txt"
    grep -q 'LiteSpeed/.* Open' "$REPORTS/$mode-version.txt" || {
        echo "ERROR: unexpected $mode version output." >&2
        return 1
    }
    cat "$REPORTS/$mode-file.txt" "$REPORTS/$mode-version.txt"
    echo "Verified $mode binary"
}

# Keep the existing static build directory so earlier builds remain incremental.
build_server static "$WORK/server" "${CMAKE_OPTIONS[@]}"
build_server dynamic "$WORK/server-dynamic" "${CMAKE_OPTIONS[@]}"
# Prepare copies so stripping never changes the incremental build artifacts.
OUTPUT="$WORK/output"
mkdir -p "$OUTPUT"
for mode in static dynamic; do
    build_dir="$WORK/server"
    [[ "$mode" == static ]] || build_dir="$WORK/server-dynamic"
    if ((STRIP_BINARIES)); then
        strip --strip-all -o "$OUTPUT/openlitespeed-$mode" "$build_dir/src/openlitespeed"
    else
        cp "$build_dir/src/openlitespeed" "$OUTPUT/openlitespeed-$mode"
    fi
    verify_server "$mode" "$OUTPUT/openlitespeed-$mode"
done
if ! cmp -s "$REPORTS/static-version.txt" "$REPORTS/dynamic-version.txt"; then
    echo 'ERROR: static and dynamic binaries report different versions.' >&2
    exit 1
fi
mkdir -p "$ROOT/dist/bin"
cp "$OUTPUT/openlitespeed-static" "$ROOT/dist/bin/openlitespeed-static"
cp "$OUTPUT/openlitespeed-dynamic" "$ROOT/dist/bin/openlitespeed-dynamic"
cp "$ROOT/dist/bin/openlitespeed-static" "$ROOT/dist/bin/openlitespeed"
echo "Static binary: $ROOT/dist/bin/openlitespeed-static"
echo "Dynamic binary: $ROOT/dist/bin/openlitespeed-dynamic"
echo "Verification reports: $REPORTS"
