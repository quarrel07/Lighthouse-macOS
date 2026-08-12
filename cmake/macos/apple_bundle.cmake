# macOS .app bundle assembly for Lighthouse.
#
# Builds "Lighthouse.app" directly from the normal build (MACOSX_BUNDLE): compiles the Liquid Glass
# app icon from the Icon Composer package (when present; falls back to a flat icns from logo.png),
# bundles the runtime resources, relinks non-system dylibs (incl. SDL3 for the sdl2-compat shim)
# into Contents/Frameworks, and ad-hoc codesigns the result.
#
# Runtime layout (libultraship):
#   * GetAppBundlePath()    -> Lighthouse.app/Contents/Resources (read-only: lighthouse.o2r,
#                              config.yml, assets/, gamecontrollerdb.txt)
#   * GetAppDirectoryPath() -> SHIP_HOME (~/Library/Application Support/com.lighthouse):
#                              bk.o2r extracted from the user's ROM on first run, config/saves/logs/mods

set(MACOS_DIR ${CMAKE_SOURCE_DIR}/cmake/macos)
set(ENTITLEMENTS_FILE ${MACOS_DIR}/entitlements.plist)

option(LIGHTHOUSE_BUNDLE_DEPS "Relink and bundle dylibs into the .app so it is portable" ON)

# ---------------------------------------------------------------------------
# Bundle metadata. The configured plist carries the real project version
# (upstream's static Info.plist is pinned at 0.1.0).
# ---------------------------------------------------------------------------
configure_file(${CMAKE_SOURCE_DIR}/macosx/Info.plist.in ${CMAKE_BINARY_DIR}/macosx/Info.plist @ONLY)
set_target_properties(Lighthouse PROPERTIES
    OUTPUT_NAME "Lighthouse"
    MACOSX_BUNDLE TRUE
    MACOSX_BUNDLE_INFO_PLIST ${CMAKE_BINARY_DIR}/macosx/Info.plist
    XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY "-"
    XCODE_ATTRIBUTE_CODE_SIGN_ENTITLEMENTS ${ENTITLEMENTS_FILE}
)

# ---------------------------------------------------------------------------
# App icon + runtime resources into Contents/Resources after the app links.
#
# Icon: if an Icon Composer package (macosx/lighthouseicon.icon) exists and the local Xcode's
# actool supports it (Xcode 26+), compile it to Assets.car (real Liquid Glass material on
# macOS 26+) plus a flattened icns for older systems, and set CFBundleIconName. Otherwise fall
# back to a flat icns generated from logo.png with sips/iconutil — same art as upstream, and no
# CFBundleIconName is written (an asset-catalog icon key without the catalog = generic icon).
# NB: CMAKE_OSX_DEPLOYMENT_TARGET can be an EMPTY cache entry in this repo (project() creates it
# before the top-level set(... CACHE ...) runs), and an empty value makes actool swallow the next
# flag and fail with bogus layer errors — hence the explicit fallback in DT below.
# ---------------------------------------------------------------------------
set(RES_DIR "$<TARGET_BUNDLE_DIR:Lighthouse>/Contents/Resources")
add_custom_command(TARGET Lighthouse POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory "${RES_DIR}"
    COMMAND ${CMAKE_COMMAND} -E copy "${CMAKE_BINARY_DIR}/macosx/Info.plist" "$<TARGET_BUNDLE_DIR:Lighthouse>/Contents/Info.plist"
    COMMAND bash -c "\
ICON_SRC='${CMAKE_SOURCE_DIR}/macosx/lighthouseicon.icon'; \
DT='${CMAKE_OSX_DEPLOYMENT_TARGET}'; [ -n \"$DT\" ] || DT=11.0; \
GLASS_TMP='${CMAKE_BINARY_DIR}/AppIconAssets'; mkdir -p \"$GLASS_TMP\"; \
if [ -d \"$ICON_SRC\" ] && xcrun actool \"$ICON_SRC\" --compile \"$GLASS_TMP\" \
     --app-icon lighthouseicon --output-partial-info-plist \"$GLASS_TMP/icon-partial.plist\" \
     --platform macosx --target-device mac --minimum-deployment-target \"$DT\" \
     >/dev/null 2>&1 && [ -f \"$GLASS_TMP/Assets.car\" ] && [ -f \"$GLASS_TMP/lighthouseicon.icns\" ]; then \
  cp \"$GLASS_TMP/Assets.car\" '${RES_DIR}/Assets.car'; \
  cp \"$GLASS_TMP/lighthouseicon.icns\" '${RES_DIR}/lighthouseicon.icns'; \
  plutil -replace CFBundleIconName -string lighthouseicon '$<TARGET_BUNDLE_DIR:Lighthouse>/Contents/Info.plist'; \
  echo 'App icon: Liquid Glass (actool) + flattened icns fallback'; \
else \
  rm -rf \"$GLASS_TMP/flat.iconset\"; mkdir -p \"$GLASS_TMP/flat.iconset\"; \
  for s in 16 32 128 256 512; do \
    sips -z $s $s '${CMAKE_SOURCE_DIR}/logo.png' --out \"$GLASS_TMP/flat.iconset/icon_\${s}x\${s}.png\" >/dev/null; \
    sips -z $((s*2)) $((s*2)) '${CMAKE_SOURCE_DIR}/logo.png' --out \"$GLASS_TMP/flat.iconset/icon_\${s}x\${s}@2x.png\" >/dev/null; \
  done; \
  iconutil -c icns -o '${RES_DIR}/lighthouseicon.icns' \"$GLASS_TMP/flat.iconset\"; \
  echo 'App icon: flat icns from logo.png (no .icon package or actool lacks .icon support)'; \
fi"
    COMMAND bash -c "[ -f '${CMAKE_BINARY_DIR}/lighthouse.o2r' ] && cp '${CMAKE_BINARY_DIR}/lighthouse.o2r' '${RES_DIR}/lighthouse.o2r' || echo 'note: lighthouse.o2r not found - build the GeneratePortO2R target, then rebuild'"
    COMMAND bash -c "[ -f '${CMAKE_BINARY_DIR}/gamecontrollerdb.txt' ] && cp '${CMAKE_BINARY_DIR}/gamecontrollerdb.txt' '${RES_DIR}/gamecontrollerdb.txt' || true"
    COMMAND bash -c "[ -f '${CMAKE_BINARY_DIR}/config.yml' ] && cp '${CMAKE_BINARY_DIR}/config.yml' '${RES_DIR}/config.yml' || true"
    # The first-run Torch extractor reads the asset definitions at GetAppBundlePath()/assets
    # (= Contents/Resources/assets). Mirrors upstream's cpack install of the same directory.
    COMMAND ${CMAKE_COMMAND} -E copy_directory "${CMAKE_SOURCE_DIR}/assets" "${RES_DIR}/assets"
    COMMENT "Bundling Lighthouse resources into the .app"
    VERBATIM
)

# ---------------------------------------------------------------------------
# Relink dylibs into Contents/Frameworks (portable .app) + SDL3, then codesign
# ---------------------------------------------------------------------------
if (LIGHTHOUSE_BUNDLE_DEPS)
    add_custom_command(TARGET Lighthouse POST_BUILD
        COMMAND ${CMAKE_COMMAND}
            -DAPP_BUNDLE=$<TARGET_BUNDLE_DIR:Lighthouse>
            "-DEXECUTABLE_NAME=Lighthouse"
            -P ${MACOS_DIR}/fixup_bundle.cmake
        COMMAND bash -c "install_name_tool -add_rpath '@executable_path/../Frameworks/' '$<TARGET_BUNDLE_DIR:Lighthouse>/Contents/MacOS/Lighthouse' 2>/dev/null || true"
        # Homebrew's sdl2 is sdl2-compat, a shim that dlopen()s libSDL3.dylib from @loader_path at
        # runtime; fixup_bundle can't follow a dlopen, so copy SDL3 in next to the bundled libSDL2.
        COMMAND bash -c "SDL3_LIB=$(brew --prefix sdl3 2>/dev/null)/lib/libSDL3.0.dylib; if [ -f \"$SDL3_LIB\" ]; then cp \"$SDL3_LIB\" '$<TARGET_BUNDLE_DIR:Lighthouse>/Contents/Frameworks/libSDL3.dylib' && chmod u+w '$<TARGET_BUNDLE_DIR:Lighthouse>/Contents/Frameworks/libSDL3.dylib'; fi"
        COMMENT "Relinking dylibs into the .app bundle (incl. SDL3 for sdl2-compat)"
        VERBATIM
    )
endif()

add_custom_command(TARGET Lighthouse POST_BUILD
    COMMAND codesign --force --deep --sign - --options runtime --entitlements ${ENTITLEMENTS_FILE} "$<TARGET_BUNDLE_DIR:Lighthouse>"
    COMMENT "Ad-hoc codesigning Lighthouse.app"
    VERBATIM
)
