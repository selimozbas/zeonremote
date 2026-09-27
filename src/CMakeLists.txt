set(ZV_SOURCES
  main.mm
  ZVAppDelegate.mm
  ZVBookmark.m
  ZVClipboard.m
  ZVConnectionsWindowController.mm
  ZVFilePane.mm
  ZVFileTransferWindowController.mm
  ZVFramebuffer.mm
  ZVKeychain.m
  ZVListener.m
  ZVNetUtil.mm
  ZVPreferences.mm
  ZVRemoteView.mm
  ZVSFTPClient.mm
  ZVSession.mm
  ZVSessionWindowController.mm
  ZVTelnetClient.mm
  ZVTerminalWindowController.mm
  ZVTrust.mm
  ${ZV_COMMON_DIR}/keyboard/KeyboardMacOS.mm
  ${ZV_COMMON_DIR}/keyboard/keysym2ucs.c
  ${ZV_COMMON_DIR}/keyboard/osx_to_qnum.c)

set(ZV_ICON ${CMAKE_SOURCE_DIR}/resources/ZeonVNC.icns)
if(EXISTS ${ZV_ICON})
  set_source_files_properties(${ZV_ICON} PROPERTIES MACOSX_PACKAGE_LOCATION Resources)
  list(APPEND ZV_SOURCES ${ZV_ICON})
endif()

add_executable(ZeonVNC MACOSX_BUNDLE ${ZV_SOURCES})

set_target_properties(ZeonVNC PROPERTIES
  OUTPUT_NAME ZeonVNC
  MACOSX_BUNDLE_INFO_PLIST ${CMAKE_SOURCE_DIR}/resources/Info.plist.in)

# The Info.plist template uses @VAR@ placeholders
configure_file(${CMAKE_SOURCE_DIR}/resources/Info.plist.in
               ${CMAKE_CURRENT_BINARY_DIR}/Info.plist @ONLY)
set_target_properties(ZeonVNC PROPERTIES
  MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_BINARY_DIR}/Info.plist)

target_compile_options(ZeonVNC PRIVATE
  $<$<COMPILE_LANGUAGE:OBJC,OBJCXX>:-fobjc-arc>
  -Wno-unused-parameter)

target_include_directories(ZeonVNC PRIVATE ${CMAKE_CURRENT_SOURCE_DIR} ${ZV_COMMON_DIR}/keyboard)

# SSH / SFTP for file transfer
target_include_directories(ZeonVNC SYSTEM PRIVATE ${LIBSSH2_INCLUDE_DIR})
target_link_libraries(ZeonVNC ${LIBSSH2_LIBRARY})

target_link_libraries(ZeonVNC rfb network rdr core
  "-framework Cocoa"
  "-framework Metal"
  "-framework MetalKit"
  "-framework QuartzCore"
  "-framework IOSurface"
  "-framework IOKit"
  "-framework Carbon"
  "-framework Security"
  "-framework UniformTypeIdentifiers"
  "-framework CoreVideo")

# Third party code written for manual reference counting
set_source_files_properties(${ZV_COMMON_DIR}/keyboard/KeyboardMacOS.mm PROPERTIES COMPILE_OPTIONS -fno-objc-arc)

# License texts inside the bundle (Contents/Resources/Licenses)
add_custom_command(TARGET ZeonVNC POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_directory ${CMAKE_SOURCE_DIR}/licenses
          $<TARGET_BUNDLE_CONTENT_DIR:ZeonVNC>/Resources/Licenses
  COMMAND ${CMAKE_COMMAND} -E copy ${CMAKE_SOURCE_DIR}/THIRD_PARTY_NOTICES.md
          $<TARGET_BUNDLE_CONTENT_DIR:ZeonVNC>/Resources/Licenses/
  VERBATIM)

# Terminal view (Swift, SwiftTerm), built with SwiftPM as a dynamic library
set(ZV_TERMINAL_DIR ${CMAKE_SOURCE_DIR}/terminal)
set(ZV_TERMINAL_LIB ${ZV_TERMINAL_DIR}/.build/release/libZVTerminalKit.dylib)
file(GLOB_RECURSE ZV_TERMINAL_SOURCES CONFIGURE_DEPENDS
     ${ZV_TERMINAL_DIR}/Sources/*.swift ${ZV_TERMINAL_DIR}/Vendor/*.swift)
add_custom_command(OUTPUT ${ZV_TERMINAL_LIB}
  COMMAND swift build -c release --package-path ${ZV_TERMINAL_DIR}
  DEPENDS ${ZV_TERMINAL_SOURCES} ${ZV_TERMINAL_DIR}/Package.swift
  COMMENT "Building terminal view (Swift)"
  VERBATIM)
add_custom_target(zvterminal DEPENDS ${ZV_TERMINAL_LIB})
add_dependencies(ZeonVNC zvterminal)
target_link_libraries(ZeonVNC ${ZV_TERMINAL_LIB})
add_custom_command(TARGET ZeonVNC POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E make_directory $<TARGET_BUNDLE_CONTENT_DIR:ZeonVNC>/Frameworks
  COMMAND ${CMAKE_COMMAND} -E copy ${ZV_TERMINAL_LIB} $<TARGET_BUNDLE_CONTENT_DIR:ZeonVNC>/Frameworks/
  VERBATIM)

# Make the bundle self-contained (copies Homebrew libraries into it)
option(BUNDLE_DYLIBS "Copy third party libraries into the app bundle" ON)

# A stable signing identity keeps Keychain access and privacy permissions
# across rebuilds. Defaults to the first "Apple Development" certificate.
if(NOT DEFINED CODESIGN_IDENTITY)
  execute_process(COMMAND security find-identity -v -p codesigning
                  OUTPUT_VARIABLE _identities ERROR_QUIET)
  string(REGEX MATCH "([0-9A-F]+) \"Apple Development:[^\"]*\"" _match "${_identities}")
  if(_match)
    set(_default_identity ${CMAKE_MATCH_1})
  else()
    set(_default_identity "-")
  endif()
  set(CODESIGN_IDENTITY ${_default_identity} CACHE STRING
      "Code signing identity (hash or name, - for ad hoc)")
endif()
message(STATUS "Code signing identity: ${CODESIGN_IDENTITY}")

if(BUNDLE_DYLIBS)
  add_custom_command(TARGET ZeonVNC POST_BUILD
    COMMAND ${CMAKE_SOURCE_DIR}/tools/bundle-dylibs.sh $<TARGET_BUNDLE_DIR:ZeonVNC> ${CODESIGN_IDENTITY}
    VERBATIM)
endif()
