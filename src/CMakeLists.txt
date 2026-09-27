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
set(ZV_ICON_FILE ZeonVNC)
set(ZV_ICON_NAME_ENTRY "")

# macOS 26 icon (Icon Composer format), compiled into Assets.car by the
# actool of Xcode 26 or later. Older Xcodes keep the plain ZeonVNC.icns,
# which macOS 26 shows shrunk inside a grey tile.
set(ZV_APPICON ${CMAKE_SOURCE_DIR}/resources/AppIcon.icon)
execute_process(COMMAND xcrun actool --version OUTPUT_VARIABLE _actool_version ERROR_QUIET)
string(REGEX MATCH "short-bundle-version</key>[ \t\r\n]*<string>([0-9]+)" _match "${_actool_version}")
if(_match AND CMAKE_MATCH_1 GREATER_EQUAL 26)
  set(ZV_ICON_OUT ${CMAKE_CURRENT_BINARY_DIR}/appicon)
  file(GLOB ZV_APPICON_FILES CONFIGURE_DEPENDS ${ZV_APPICON}/*.json ${ZV_APPICON}/Assets/*)
  add_custom_command(
    OUTPUT ${ZV_ICON_OUT}/Assets.car ${ZV_ICON_OUT}/AppIcon.icns
    COMMAND ${CMAKE_COMMAND} -E make_directory ${ZV_ICON_OUT}
    COMMAND xcrun actool ${ZV_APPICON} --compile ${ZV_ICON_OUT}
            --app-icon AppIcon --include-all-app-icons
            --output-partial-info-plist ${ZV_ICON_OUT}/partial.plist
            --platform macosx --target-device mac
            --minimum-deployment-target ${CMAKE_OSX_DEPLOYMENT_TARGET}
            --enable-on-demand-resources NO --development-region en
            --errors --warnings --output-format human-readable-text
    DEPENDS ${ZV_APPICON_FILES}
    COMMENT "Compiling the app icon"
    VERBATIM)
  set_source_files_properties(${ZV_ICON_OUT}/Assets.car ${ZV_ICON_OUT}/AppIcon.icns
    PROPERTIES MACOSX_PACKAGE_LOCATION Resources GENERATED TRUE)
  list(APPEND ZV_SOURCES ${ZV_ICON_OUT}/Assets.car ${ZV_ICON_OUT}/AppIcon.icns)
  set(ZV_ICON_FILE AppIcon)
  set(ZV_ICON_NAME_ENTRY "<key>CFBundleIconName</key>\n  <string>AppIcon</string>")
  message(STATUS "App icon: Icon Composer (actool ${CMAKE_MATCH_1})")
else()
  message(STATUS "App icon: ZeonVNC.icns (actool of Xcode 26 or later not found)")
endif()

add_executable(ZeonVNC MACOSX_BUNDLE ${ZV_SOURCES})

set_target_properties(ZeonVNC PROPERTIES
  OUTPUT_NAME ZeonVNC
  MACOSX_BUNDLE_INFO_PLIST ${CMAKE_SOURCE_DIR}/resources/Info.plist.in)

# Automatic updates
set(ZV_SPARKLE_ENTRIES "")
if(ENABLE_SPARKLE)
  target_compile_definitions(ZeonVNC PRIVATE ZV_SPARKLE=1)
  target_compile_options(ZeonVNC PRIVATE -F${SPARKLE_DIR})
  target_link_options(ZeonVNC PRIVATE -F${SPARKLE_DIR} -Wl,-rpath,@executable_path/../Frameworks)
  target_link_libraries(ZeonVNC "-framework Sparkle")
  add_custom_command(TARGET ZeonVNC POST_BUILD
    COMMAND rm -rf $<TARGET_BUNDLE_CONTENT_DIR:ZeonVNC>/Frameworks/Sparkle.framework
    COMMAND ditto ${SPARKLE_DIR}/Sparkle.framework
            $<TARGET_BUNDLE_CONTENT_DIR:ZeonVNC>/Frameworks/Sparkle.framework
    VERBATIM)
  if(NOT SPARKLE_PUBLIC_KEY STREQUAL "")
    string(CONCAT ZV_SPARKLE_ENTRIES
      "<key>SUFeedURL</key>\n"
      "  <string>https://github.com/selimozbas/zeonvnc/releases/latest/download/appcast.xml</string>\n"
      "  <key>SUPublicEDKey</key>\n"
      "  <string>${SPARKLE_PUBLIC_KEY}</string>\n"
      "  <key>SUEnableAutomaticChecks</key>\n"
      "  <true/>")
  endif()
endif()

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
