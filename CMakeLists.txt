cmake_minimum_required(VERSION 3.21)

project(GXMusicStudio VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 6.8 REQUIRED COMPONENTS
    Core
    Gui
    Quick
    QuickControls2
    Multimedia
    SerialPort
    Concurrent
)

qt_standard_project_setup(REQUIRES 6.8)

qt_add_executable(GXMusicStudio
    src/main.cpp
    src/AppController.cpp
    src/AppController.h
    src/AudioConverter.cpp
    src/AudioConverter.h
    src/AudioAnalyzer.cpp
    src/AudioAnalyzer.h
    src/LrcParser.cpp
    src/LrcParser.h
    src/SongPackage.cpp
    src/SongPackage.h
    src/SerialLink.cpp
    src/SerialLink.h
    src/SystemAudioMonitor.cpp
    src/SystemAudioMonitor.h
)

qt_add_qml_module(GXMusicStudio
    URI GXMusicStudio
    VERSION 1.0
    QML_FILES
        qml/Main.qml
        qml/components/GlassPanel.qml
        qml/components/NavButton.qml
        qml/components/SpectrumView.qml
        qml/components/WaveformView.qml
        qml/components/VuMeter.qml
        qml/components/StudioButton.qml
        qml/components/RainbowSpectrum.qml
        qml/PlayerPage.qml
        qml/ImportPage.qml
        qml/BoardPage.qml
        qml/ExternalAudioPage.qml
)

add_custom_command(TARGET GXMusicStudio POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_directory
            "${CMAKE_CURRENT_SOURCE_DIR}/media"
            "$<TARGET_FILE_DIR:GXMusicStudio>/media"
    COMMENT "Copying companion music and lyrics"
)

target_link_libraries(GXMusicStudio PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Quick
    Qt6::QuickControls2
    Qt6::Multimedia
    Qt6::SerialPort
    Qt6::Concurrent
)

if (WIN32)
    # WASAPI loopback capture used by the "system audio" monitor page.
    target_link_libraries(GXMusicStudio PRIVATE ole32 uuid)
endif()

target_compile_definitions(GXMusicStudio PRIVATE
    GX_APP_VERSION="${PROJECT_VERSION}"
)

set_target_properties(GXMusicStudio PROPERTIES
    WIN32_EXECUTABLE TRUE
    MACOSX_BUNDLE TRUE
)

include(GNUInstallDirs)
install(TARGETS GXMusicStudio
    BUNDLE DESTINATION .
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)
