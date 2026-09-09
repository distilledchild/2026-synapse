#!/bin/bash
set -euo pipefail
source_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="$source_root/build/telegram-dependency"
revision=d1085f9cebc5a62379991ae1652673954f229c1f
prefix="$source_root/build/tdlib-runtime"
mkdir -p "$build_root"
# Run `brew install cmake gperf openssl@3` first. This script installs the
# dependency inside ignored build output and never reads account configuration.
curl -fL "https://github.com/tdlib/td/archive/$revision.tar.gz" -o "$build_root/tdlib.tar.gz"
tar -xzf "$build_root/tdlib.tar.gz" -C "$build_root"
cmake -S "$build_root/td-$revision" -B "$build_root/cmake" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
    -DCMAKE_INSTALL_PREFIX="$prefix" -DOPENSSL_ROOT_DIR="$(brew --prefix openssl@3)" \
    -DTD_ENABLE_JNI=OFF -DTD_INSTALL_STATIC_LIBRARIES=OFF -DTD_INSTALL_SHARED_LIBRARIES=ON -DBUILD_TESTING=OFF
cmake --build "$build_root/cmake" --target tdjson --parallel 4
cmake --install "$build_root/cmake"
printf '%s\n' "$revision" > "$prefix/.synapse-tdlib-revision"
printf 'Runtime installed. Build using SYNAPSE_TDLIB_PREFIX=%q bash native/scripts/build.sh\n' "$prefix"
