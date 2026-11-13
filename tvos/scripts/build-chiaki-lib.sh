#!/bin/bash
# Cross-compiles chiaki-lib and its dependencies for tvOS (device + simulator)
# and packages them as tvos/build/ChiakiTV.xcframework for the Xcode project.
#
# Requirements: Xcode with the tvOS SDK, cmake, ninja, protoc, xcodegen
#   brew install cmake ninja protobuf xcodegen
# Usage: tvos/scripts/build-chiaki-lib.sh [Release|Debug]

set -euo pipefail

CONFIG="${1:-Release}"
TVOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT_DIR="$(cd "${TVOS_DIR}/.." && pwd)"
BUILD_DIR="${TVOS_DIR}/build"
DEPLOYMENT_TARGET="17.0"

mkdir -p "${BUILD_DIR}"

# nanopb's generator needs the python protobuf package
VENV="${BUILD_DIR}/venv"
if [ ! -x "${VENV}/bin/python3" ]; then
	python3 -m venv "${VENV}"
	"${VENV}/bin/pip" install --quiet protobuf
fi

# Keep pkg-config from handing host (Homebrew) libraries to the cross build
export PKG_CONFIG_LIBDIR="${BUILD_DIR}/no-pkgconfig"
mkdir -p "${PKG_CONFIG_LIBDIR}"

build_platform() {
	local sdk="$1"
	local dir="${BUILD_DIR}/${sdk}"
	cmake -S "${ROOT_DIR}" -B "${dir}" -G Ninja \
		-DCMAKE_BUILD_TYPE="${CONFIG}" \
		-DCMAKE_SYSTEM_NAME=tvOS \
		-DCMAKE_OSX_SYSROOT="${sdk}" \
		-DCMAKE_OSX_ARCHITECTURES=arm64 \
		-DCMAKE_OSX_DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET}" \
		-DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
		-DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" \
		-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
		-DPYTHON_EXECUTABLE="${VENV}/bin/python3" \
		-DCHIAKI_ENABLE_TVOS=ON \
		-DCHIAKI_ENABLE_TESTS=OFF \
		-DCHIAKI_ENABLE_CLI=OFF \
		-DCHIAKI_ENABLE_GUI=OFF \
		-DCHIAKI_ENABLE_SETSU=OFF \
		-DCHIAKI_ENABLE_STEAMDECK_NATIVE=OFF \
		-DCHIAKI_ENABLE_STEAM_SHORTCUT=OFF \
		-DCHIAKI_ENABLE_FFMPEG_DECODER=OFF \
		-DCHIAKI_ENABLE_PI_DECODER=OFF \
		-DCHIAKI_ENABLE_SPEEX=OFF \
		-DCHIAKI_USE_SYSTEM_JERASURE=OFF \
		-DCHIAKI_USE_SYSTEM_NANOPB=OFF \
		-DCHIAKI_USE_SYSTEM_CURL=OFF \
		-DCHIAKI_LIB_ENABLE_OPUS=ON \
		-DCHIAKI_LIB_OPUS_EXTERNAL_PROJECT=ON \
		-DCHIAKI_LIB_LIBEVENT_EXTERNAL_PROJECT=ON \
		-DCHIAKI_LIB_ENABLE_MBEDTLS=ON \
		-DCHIAKI_LIB_MBEDTLS_EXTERNAL_PROJECT=ON \
		-DMBEDTLS_FATAL_WARNINGS=OFF \
		-DCHIAKI_LIB_JSONC_EXTERNAL_PROJECT=ON \
		-DCHIAKI_LIB_MINIUPNPC_EXTERNAL_PROJECT=ON
	cmake --build "${dir}" --target chiaki-tvos

	# Merge every static library the bridge depends on into one archive
	local libs
	libs=$(find "${dir}" -name '*.a' -not -path '*/CMakeFiles/*' | sort)
	echo "Merging for ${sdk}:"
	echo "${libs}"
	rm -f "${dir}/libchiakitv.a"
	# shellcheck disable=SC2086
	libtool -static -no_warning_for_no_symbols -o "${dir}/libchiakitv.a" ${libs}
}

build_platform appletvos
build_platform appletvsimulator

# Public headers seen by Swift: the bridge plus the plain-data chiaki headers it uses
HEADERS="${BUILD_DIR}/headers"
rm -rf "${HEADERS}"
mkdir -p "${HEADERS}/chiaki"
cp "${TVOS_DIR}/bridge/include/chiakitv.h" "${HEADERS}/"
cp "${ROOT_DIR}/lib/include/chiaki/controller.h" "${ROOT_DIR}/lib/include/chiaki/common.h" "${HEADERS}/chiaki/"
cat > "${HEADERS}/module.modulemap" <<'MODULEMAP'
module ChiakiTVBridge {
	header "chiakitv.h"
	export *
}
MODULEMAP

rm -rf "${BUILD_DIR}/ChiakiTV.xcframework"
xcodebuild -create-xcframework \
	-library "${BUILD_DIR}/appletvos/libchiakitv.a" -headers "${HEADERS}" \
	-library "${BUILD_DIR}/appletvsimulator/libchiakitv.a" -headers "${HEADERS}" \
	-output "${BUILD_DIR}/ChiakiTV.xcframework"

echo "Built ${BUILD_DIR}/ChiakiTV.xcframework"

if command -v xcodegen >/dev/null 2>&1; then
	(cd "${TVOS_DIR}" && xcodegen --quiet)
	echo "Generated ${TVOS_DIR}/ChiakiTV.xcodeproj"
else
	echo "Install xcodegen (brew install xcodegen) and run it in ${TVOS_DIR} to generate the Xcode project"
fi
