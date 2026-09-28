#
# ZeonVNC - native macOS client for VNC, SSH, Telnet and SFTP
#
# Licensed under the GNU GPL, version 2 or later (see LICENSE). Code in
# third_party/ keeps its own copyright notices and licenses
# (see THIRD_PARTY_NOTICES.md).
#

cmake_minimum_required(VERSION 3.20)

# Must be set before project(), otherwise the compiler targets the macOS
# version of the build machine and the app refuses to start on older ones
set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0" CACHE STRING "Minimum macOS version")

project(ZeonVNC VERSION 0.3.3 LANGUAGES C CXX OBJC OBJCXX)

if(NOT APPLE)
  message(FATAL_ERROR "ZeonVNC only supports macOS")
endif()

set(CMAKE_MODULE_PATH ${CMAKE_SOURCE_DIR}/cmake/Modules)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

set(CMAKE_C_STANDARD 99)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Keep asserts in release builds (the protocol core relies on them)
set(CMAKE_C_FLAGS_RELEASE "${CMAKE_C_FLAGS_RELEASE} -UNDEBUG")
set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} -UNDEBUG")
set(CMAKE_OBJCXX_FLAGS_RELEASE "${CMAKE_OBJCXX_FLAGS_RELEASE} -UNDEBUG")

add_compile_options(-Wall -Wno-deprecated-declarations)
add_definitions(-D__ASSERT_MACROS_DEFINE_VERSIONS_WITHOUT_UNDERSCORES=0)

# Homebrew prefix for dependency lookup
execute_process(COMMAND brew --prefix OUTPUT_VARIABLE BREW_PREFIX
                OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
if(BREW_PREFIX)
  list(APPEND CMAKE_PREFIX_PATH ${BREW_PREFIX} ${BREW_PREFIX}/opt/jpeg-turbo)
endif()

#### Dependencies ####

find_package(ZLIB REQUIRED)
find_package(Pixman REQUIRED)
find_package(JPEG REQUIRED)

option(ENABLE_GNUTLS "TLS / X509 security types" ON)
if(ENABLE_GNUTLS)
  find_package(GnuTLS)
  if(GNUTLS_FOUND)
    add_definitions(-DHAVE_GNUTLS)
  endif()
endif()

option(ENABLE_NETTLE "RSA-AES (RA2), DH and MSLogonII security types" ON)
if(ENABLE_NETTLE)
  find_package(Nettle)
  if(NETTLE_FOUND)
    add_definitions(-DHAVE_NETTLE)
  endif()
endif()

option(ENABLE_H264 "H.264 encoding support (hardware decoding via VideoToolbox)" ON)
set(H264_LIBS "NONE")
if(ENABLE_H264)
  set(H264_LIBS "VT")
  set(H264_LIBRARIES "-framework VideoToolbox" "-framework CoreMedia"
                     "-framework CoreVideo" "-framework CoreFoundation")
  add_definitions(-DHAVE_H264)
endif()
add_definitions(-DH264_${H264_LIBS})

find_path(LIBSSH2_INCLUDE_DIR libssh2_sftp.h REQUIRED)
find_library(LIBSSH2_LIBRARY ssh2 REQUIRED)

option(ENABLE_SPARKLE "Automatic updates with Sparkle (downloaded at configure time)" ON)
if(ENABLE_SPARKLE)
  set(SPARKLE_VERSION 2.9.6)
  set(SPARKLE_SHA256 52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192)
  set(SPARKLE_DIR ${CMAKE_BINARY_DIR}/sparkle-${SPARKLE_VERSION})
  if(NOT EXISTS ${SPARKLE_DIR}/Sparkle.framework)
    set(_archive ${CMAKE_BINARY_DIR}/Sparkle-${SPARKLE_VERSION}.tar.xz)
    file(DOWNLOAD
      https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz
      ${_archive} EXPECTED_HASH SHA256=${SPARKLE_SHA256} STATUS _status)
    list(GET _status 0 _code)
    if(NOT _code EQUAL 0)
      message(FATAL_ERROR "Downloading Sparkle failed (${_status}); configure with -DENABLE_SPARKLE=OFF to build without automatic updates")
    endif()
    file(ARCHIVE_EXTRACT INPUT ${_archive} DESTINATION ${SPARKLE_DIR})
  endif()
  # Public half of the key that signs updates ("Automatic updates" in docs/BUILDING.md)
  set(SPARKLE_PUBLIC_KEY "")
  if(EXISTS ${CMAKE_SOURCE_DIR}/resources/sparkle-public-key.txt)
    file(STRINGS ${CMAKE_SOURCE_DIR}/resources/sparkle-public-key.txt SPARKLE_PUBLIC_KEY LIMIT_COUNT 1)
    string(STRIP "${SPARKLE_PUBLIC_KEY}" SPARKLE_PUBLIC_KEY)
  endif()
  if(SPARKLE_PUBLIC_KEY STREQUAL "")
    message(STATUS "Sparkle ${SPARKLE_VERSION}: no public key in resources/sparkle-public-key.txt, updates are off")
  else()
    message(STATUS "Sparkle ${SPARKLE_VERSION}: automatic updates on")
  endif()
endif()

option(ENABLE_RDP "RDP connections with FreeRDP 3 (tools/build-freerdp.sh)" ON)
set(FREERDP_DIR "" CACHE PATH "FreeRDP prefix built by tools/build-freerdp.sh")
if(ENABLE_RDP)
  if(FREERDP_DIR)
    list(APPEND CMAKE_PREFIX_PATH ${FREERDP_DIR})
  endif()
  find_package(FreeRDP-Client 3 CONFIG QUIET)
  if(FreeRDP-Client_FOUND)
    message(STATUS "RDP: FreeRDP ${FreeRDP-Client_VERSION}")
  else()
    message(WARNING "FreeRDP 3 not found, building without RDP. Run tools/build-freerdp.sh <prefix> "
                    "and configure with -DFREERDP_DIR=<prefix>.")
    set(ENABLE_RDP OFF)
  endif()
endif()

#### RFB protocol core ####

set(ZV_COMMON_DIR ${CMAKE_SOURCE_DIR}/third_party/rfbcore)
add_subdirectory(third_party/rfbcore)

#### Application ####

add_subdirectory(src)

#### Test server (development only) ####

option(BUILD_TESTSERVER "Build the synthetic test VNC server" ON)
if(BUILD_TESTSERVER)
  add_executable(zv-testserver tools/zv-testserver.cxx)
  target_link_libraries(zv-testserver rfb network rdr core)
endif()
if(BUILD_TESTSERVER)
  add_executable(zv-vnctest tools/zv-vnctest.cxx)
  target_link_libraries(zv-vnctest rfb network rdr core)
endif()
if(BUILD_TESTSERVER AND ENABLE_RDP)
  add_executable(zv-rdptest tools/zv-rdptest.cpp src/rdp/ZVRdpClient.cpp)
  target_include_directories(zv-rdptest PRIVATE src/rdp)
  target_compile_options(zv-rdptest PRIVATE -Wno-deprecated-declarations)
  target_link_libraries(zv-rdptest freerdp-client freerdp winpr)
endif()
if(BUILD_TESTSERVER AND ENABLE_H264)
  add_executable(zv-h264test tools/zv-h264test.cxx)
  target_link_libraries(zv-h264test rfb core)
endif()
if(BUILD_TESTSERVER)
  add_executable(zv-sftptest tools/zv-sftptest.mm src/ZVSFTPClient.mm src/ZVNetUtil.mm)
  target_include_directories(zv-sftptest PRIVATE src)
  target_include_directories(zv-sftptest SYSTEM PRIVATE ${LIBSSH2_INCLUDE_DIR})
  target_compile_options(zv-sftptest PRIVATE -fobjc-arc)
  target_link_libraries(zv-sftptest ${LIBSSH2_LIBRARY} "-framework Foundation")
endif()
if(BUILD_TESTSERVER)
  add_executable(zv-sftpconflict tools/zv-sftpconflict.mm src/ZVSFTPClient.mm src/ZVNetUtil.mm)
  target_include_directories(zv-sftpconflict PRIVATE src)
  target_include_directories(zv-sftpconflict SYSTEM PRIVATE ${LIBSSH2_INCLUDE_DIR})
  target_compile_options(zv-sftpconflict PRIVATE -fobjc-arc)
  target_link_libraries(zv-sftpconflict ${LIBSSH2_LIBRARY} "-framework Foundation")
endif()
