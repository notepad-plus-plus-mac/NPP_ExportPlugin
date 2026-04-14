cmake_minimum_required(VERSION 3.20)
project(NPP_ExportPlugin LANGUAGES CXX OBJCXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64")
set(CMAKE_OSX_DEPLOYMENT_TARGET "11.0")

# Path to the Notepad++ macOS port for shared headers (Scintilla is vendored
# inside notepad-plus-plus-macos/scintilla since the v1.0.1 restructure).
set(NPP_MACOS_DIR "${CMAKE_SOURCE_DIR}/../../notepad-plus-plus-macos")
set(SCINTILLA_INCLUDE "${NPP_MACOS_DIR}/scintilla/include")
set(NPP_PLUGIN_INCLUDE "${NPP_MACOS_DIR}/src")

add_library(NPP_ExportPlugin SHARED src/NPP_ExportPlugin.mm)
target_include_directories(NPP_ExportPlugin PRIVATE
    ${NPP_PLUGIN_INCLUDE}
    ${SCINTILLA_INCLUDE})
target_link_libraries(NPP_ExportPlugin PRIVATE
    "-framework Cocoa"
    "-framework UniformTypeIdentifiers")
set_target_properties(NPP_ExportPlugin PROPERTIES PREFIX "" SUFFIX ".dylib")
set(PLUGIN_INSTALL_DIR "$ENV{HOME}/.notepad++/plugins/NPP_ExportPlugin")
install(TARGETS NPP_ExportPlugin DESTINATION "${PLUGIN_INSTALL_DIR}")
