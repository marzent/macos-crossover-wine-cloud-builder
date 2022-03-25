#!/usr/bin/env arch -x86_64 bash

set -ex

echo Wine-Crossover-MacOS

export GITHUB_WORKSPACE=$(pwd)

if [ -z "$CROSS_OVER_VERSION" ]; then
    export CROSS_OVER_VERSION=21.2.0
    echo "CROSS_OVER_VERSION not set building crossover-wine-${CROSS_OVER_VERSION}"
fi

# avoid weird linker errors with Xcode 10 and later
export MACOSX_DEPLOYMENT_TARGET=10.14
# crossover source code to be downloaded
export CROSS_OVER_SOURCE_URL=https://media.codeweavers.com/pub/crossover/source/crossover-sources-${CROSS_OVER_VERSION}.tar.gz
export CROSS_OVER_LOCAL_FILE=crossover-${CROSS_OVER_VERSION}
# directories / files inside the downloaded tar file directory structure
export LLVM_MAKEDIR=$GITHUB_WORKSPACE/sources/$([[ ${CROSS_OVER_VERSION} == 2?.* ]] && echo "clang/llvm" || echo "llvm")
export CLANG_MAKEDIR=$GITHUB_WORKSPACE/sources/$([[ ${CROSS_OVER_VERSION} == 2?.* ]] && echo "clang/clang" || echo "clang")
export WINE_CONFIGURE=$GITHUB_WORKSPACE/sources/wine/configure
export DXVK_BUILDSCRIPT=$GITHUB_WORKSPACE/sources/dxvk/package-release.sh
# build directories
export BUILDROOT=$GITHUB_WORKSPACE/build
export LLVM_BUILDDIR=$GITHUB_WORKSPACE/build/llvm
export CLANG_BUILDDIR=$GITHUB_WORKSPACE/build/clang
# target directory for installation
export INSTALLROOT=$GITHUB_WORKSPACE/install
export PACKAGE_UPLOAD=$GITHUB_WORKSPACE/upload
# artifact names
export TOOLS_INSTALLATION=build-tools-cx${CROSS_OVER_VERSION}
export WINE_INSTALLATION=wine-cx${CROSS_OVER_VERSION}
export DXVK_INSTALLATION=dxvk-cx${CROSS_OVER_VERSION}

# Need to ensure Instel brew actually exists
if ! command -v "/usr/local/bin/brew" &> /dev/null
then
    echo "</usr/local/bin/brew> could not be found"
    echo "An Intel brew installation is required"
    exit
fi

# Make a wrapper to ensure Intel brew is used and not Apple Silicon brew
ibrew() {
    /usr/local/bin/brew "$@"
}
export -f ibrew

# Make sure Intel brew Install is before a possible Apple Silicon brew
export PATH="/usr/local/bin:/usr/local/sbin:${PATH}"

echo Installing Dependencies
# build dependencies
ibrew install  bison            \
               cmake            \
               mingw-w64        \
               ninja

# runtime dependencies for crossover-wine
ibrew install  faudio           \
               freetype         \
               gnutls           \
               gphoto2          \
               gst-plugins-base \
               libpng           \
               little-cms2      \
               molten-vk        \
               mpg123           \
               sane-backends    \
               sdl2

echo Add bison to PATH
export PATH="$(brew --prefix bison)/bin":${PATH}

echo Add llvm/clang to PATH for later
export PATH="${INSTALLROOT}/${TOOLS_INSTALLATION}/bin":${PATH}


############ Download and Prepare Source Code ##############

echo Get Source
curl -o ${CROSS_OVER_LOCAL_FILE}.tar.gz ${CROSS_OVER_SOURCE_URL}

echo Extract Source
tar xf ${CROSS_OVER_LOCAL_FILE}.tar.gz

if [[ "${CROSS_OVER_VERSION}" == "20.0.1" || "${CROSS_OVER_VERSION}" == "20.0.2"  ]]; then
    echo Add missing llvm/clang
    curl -o crossover-21.1.0.tar.gz https://media.codeweavers.com/pub/crossover/source/crossover-sources-21.1.0.tar.gz
    tar -xf crossover-21.1.0.tar.gz sources/clang
fi

echo "Replace wine with custom version"
rm -rf sources/wine
pushd sources
git clone https://github.com/marzent/winecx
mv winecx wine
popd


if [[ ${CROSS_OVER_VERSION} == 20.* ]]; then
    echo "Patch wcslen() in ntdll/wcstring.c to prevent crash if a nullptr is suppluied to the function (HACK)"
    pushd sources/wine
    patch -p1 < ${GITHUB_WORKSPACE}/wcstring.patch
    popd

    echo "Patch msvcrt to export the missing sincos function"
    # https://github.com/wine-mirror/wine/commit/f0131276474997b9d4e593bbf8c5616b879d3bd5
    pushd sources/wine
    patch -p1 < ${GITHUB_WORKSPACE}/msvcrt-sincos.patch
    popd

    echo Patch DXVK
    patch sources/dxvk/src/util/rc/util_rc_ptr.h < dxvk_util_rc_ptr.patch
fi

############ Build LLVM / Clang ##############

echo Configure LLVM
mkdir -p ${LLVM_BUILDDIR}
pushd ${LLVM_BUILDDIR}
cmake -G Ninja \
    -DLLVM_TARGETS_TO_BUILD=X86 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${INSTALLROOT}/${TOOLS_INSTALLATION}" \
    ${LLVM_MAKEDIR}
popd

echo Build LLVM
pushd ${LLVM_BUILDDIR}
Ninja
popd

echo Install LLVM
pushd ${LLVM_BUILDDIR}
Ninja install
popd

echo Configure Clang
mkdir -p ${CLANG_BUILDDIR}
pushd ${CLANG_BUILDDIR}
cmake -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${INSTALLROOT}/${TOOLS_INSTALLATION}" \
    ${CLANG_MAKEDIR}
popd

echo Build Clang
pushd ${CLANG_BUILDDIR}
Ninja
popd

echo Install Clang
pushd ${CLANG_BUILDDIR}
Ninja install
popd

echo Tar Build Tools
pushd ${INSTALLROOT}
tar -czf ${TOOLS_INSTALLATION}.tar.gz ${TOOLS_INSTALLATION}
popd

echo Upload Build Tools
mkdir -p ${PACKAGE_UPLOAD}
cp ${INSTALLROOT}/${TOOLS_INSTALLATION}.tar.gz ${PACKAGE_UPLOAD}/


############ Build DXVK ##############

#if [[ ${CROSS_OVER_VERSION} == 20.* ]]; thend
#    Echo "Installing dependencies for dxvk"
#    brew install  coreutils \
#                  meson     \
#                  glslang
#    echo Build DXVK
#    PATH="$(brew --prefix coreutils)/libexec/gnubin:${PATH}" ${DXVK_BUILDSCRIPT} master ${INSTALLROOT}/${DXVK_INSTALLATION} --no-package
#
#    echo Tar DXVK
#    pushd ${INSTALLROOT}
#    tar -czf ${DXVK_INSTALLATION}.tar.gz ${DXVK_INSTALLATION}
#    popd
#
#    echo Upload DXVK
#    mkdir -p ${PACKAGE_UPLOAD}
#    cp ${INSTALLROOT}/${DXVK_INSTALLATION}.tar.gz ${PACKAGE_UPLOAD}/
#fi

############ Build 64bit Version ##############

echo Configure wine64
export CC=clang
export CXX=clang++
# see https://github.com/Gcenx/macOS_Wine_builds/issues/17#issuecomment-750346843
export CROSSCFLAGS=$([[ ${CROSS_OVER_VERSION} -le 20.0.2 ]] && echo "-s -O3 -fcommon" || echo "-s -O3")
# Xcode12 by default enables '-Werror,-Wimplicit-function-declaration' (49917738)
# this causes wine(64) builds to fail so needs to be disabled.
# https://developer.apple.com/documentation/xcode-release-notes/xcode-12-release-notes
export CFLAGS="-O3 -Wno-implicit-function-declaration -Wno-deprecated-declarations -Wno-format"
export LDFLAGS="-Wl,-rpath,../runtime"

export GPHOTO2_CFLAGS="-I$(brew --prefix libgphoto2)/include -I$(brew --prefix libgphoto2)/include/gphoto2"
export GPHOTO2_PORT_CFLAGS="-I$(brew --prefix libgphoto2)/include -I$(brew --prefix libgphoto2)/include/gphoto2"
export SDL2_CFLAGS="-I$(brew --prefix sdl2)/"$(echo "include/SDL2" || echo "include")
export ac_cv_lib_soname_vulkan=""
export ac_cv_lib_soname_MoltenVK="libMoltenVK.dylib"

mkdir -p ${BUILDROOT}/wine64
pushd ${BUILDROOT}/wine64
${WINE_CONFIGURE} \
        --disable-option-checking \
        --enable-win64 \
        --disable-tests \
        --without-alsa \
        --without-capi \
        --without-dbus \
        --without-inotify \
        --without-oss \
        --without-pulse \
        --without-udev \
        --without-v4l2 \
        --without-gsm \
        --with-mingw \
        --with-png \
        --with-sdl \
        --without-krb5 \
        --with-vulkan \
        --without-x
popd

echo Build wine64
pushd ${BUILDROOT}/wine64
make -j$(sysctl -n hw.ncpu 2>/dev/null)
popd


############ Build 32bit Version (WoW64) ##############

echo Configure wine32on64
export CC=clang
export CXX=clang++
# see https://github.com/Gcenx/macOS_Wine_builds/issues/17#issuecomment-750346843
export CROSSCFLAGS=$([[ ${CROSS_OVER_VERSION} -le 20.0.2 ]] && echo "-s -O3 -fcommon" || echo "-s -O3 -Wno-error -Wno-incompatible-pointer-types")
# Xcode12 by default enables '-Werror,-Wimplicit-function-declaration' (49917738)
# this causes wine(64) builds to fail so needs to be disabled.
# https://developer.apple.com/documentation/xcode-release-notes/xcode-12-release-notes
export CFLAGS="-O3 -Wno-implicit-function-declaration -Wno-deprecated-declarations -Wno-format -Wno-error -Wno-incompatible-pointer-types"
export LDFLAGS="-Wl,-rpath,../runtime"

export GPHOTO2_CFLAGS="-I$(brew --prefix libgphoto2)/include -I$(brew --prefix libgphoto2)/include/gphoto2"
export GPHOTO2_PORT_CFLAGS="-I$(brew --prefix libgphoto2)/include -I$(brew --prefix libgphoto2)/include/gphoto2"
export SDL2_CFLAGS="-I$(brew --prefix sdl2)/"$( echo "include/SDL2" || echo "include")

mkdir -p ${BUILDROOT}/wine32on64
pushd ${BUILDROOT}/wine32on64
${WINE_CONFIGURE} \
        --disable-option-checking \
        --enable-win32on64 \
        --with-wine64=${BUILDROOT}/wine64 \
        --disable-tests \
        --without-alsa \
        --without-capi \
        --without-dbus \
        --without-inotify \
        --without-oss \
        --without-pulse \
        --without-udev \
        --without-v4l2 \
        --disable-winedbg \
        --without-cms \
        --without-gstreamer \
        --without-gsm \
        --without-gphoto \
        --without-sane \
        --with-mingw \
        --with-png \
        --with-sdl \
        --without-krb5 \
        --without-vkd3d \
        --without-vulkan \
        --disable-vulkan_1 \
        --disable-winevulkan \
        --without-x \
        --without-pcap
popd

echo Build wine32on64
pushd ${BUILDROOT}/wine32on64
make -j$(sysctl -n hw.activecpu 2>/dev/null)
popd


############ Install wine ##############

echo Install wine32on64
pushd ${BUILDROOT}/wine32on64
make install-lib DESTDIR="${INSTALLROOT}/${WINE_INSTALLATION}"
popd

echo Install wine64
pushd ${BUILDROOT}/wine64
make install-lib DESTDIR="${INSTALLROOT}/${WINE_INSTALLATION}"
popd


############ Install runtime ##############

echo Installing runtime
rm -rf "${INSTALLROOT}/${WINE_INSTALLATION}/usr/local/runtime"
cp -PR runtime "${INSTALLROOT}/${WINE_INSTALLATION}/usr/local"
pushd "${INSTALLROOT}/${WINE_INSTALLATION}/usr/local/runtime"
FILES="libSDL2-2.0.0.dylib
libffi.8.dylib
libfreetype.6.dylib
libglib-2.0.0.dylib
libgmodule-2.0.0.dylib
libgmp.10.dylib
libgnutls.30.dylib
libgobject-2.0.0.dylib
libgstaudio-1.0.0.dylib
libgstbase-1.0.0.dylib
libgstreamer-1.0.0.dylib
libgsttag-1.0.0.dylib
libgstvideo-1.0.0.dylib
libhogweed.6.4.dylib
libidn2.0.dylib
libintl.8.dylib
libjpeg.9.dylib
libmpg123.0.dylib
libnettle.8.4.dylib
liborc-0.4.0.dylib
libp11-kit.0.dylib
libpcre.1.dylib
libpng16.16.dylib
libtasn1.6.dylib
libunistring.2.dylib
libusb-1.0.0.dylib"
for f in $FILES
do
    cp $(echo $(find /usr/local/Cellar -name "$f") | head -n1 | cut -d " " -f1) .
done
popd


############ Bundle and Upload Deliverable ##############

echo Tar Wine
pushd ${INSTALLROOT}
tar -czvf ${WINE_INSTALLATION}.tar.gz ${WINE_INSTALLATION}
popd

echo Upload Wine
mkdir -p ${PACKAGE_UPLOAD}
cp ${INSTALLROOT}/${WINE_INSTALLATION}.tar.gz ${PACKAGE_UPLOAD}/
