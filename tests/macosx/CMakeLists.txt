include(GoogleTest)

add_executable(macosx-test)

target_sources(macosx-test
    PRIVATE
        IINAWatchHelper-test.mm
        NSStringAdditions-test.mm
        TorrentPlayable-regression-test.mm
        ${CMAKE_SOURCE_DIR}/macosx/IINAWatchHelper.h
        ${CMAKE_SOURCE_DIR}/macosx/IINAWatchHelper.mm
        ${CMAKE_SOURCE_DIR}/macosx/NSDataAdditions.h
        ${CMAKE_SOURCE_DIR}/macosx/NSDataAdditions.mm
        ${CMAKE_SOURCE_DIR}/macosx/NSStringAdditions.h
        ${CMAKE_SOURCE_DIR}/macosx/NSStringAdditions.mm)

set_property(
    TARGET macosx-test
    PROPERTY FOLDER "tests")

target_compile_definitions(macosx-test
    PRIVATE
        __TRANSMISSION__)

target_link_libraries(macosx-test
    PRIVATE
        gtestall
        ${TR_NAME})

# Add compile options for Objective-C++ (ARC, modules, etc.)
target_compile_options(macosx-test
    PRIVATE
        $<$<COMPILE_LANGUAGE:C,CXX>:-fmodules>
        $<$<COMPILE_LANGUAGE:C,CXX>:-fcxx-modules>
        $<$<COMPILE_LANGUAGE:C,CXX>:-fobjc-arc>
        $<$<COMPILE_LANGUAGE:C,CXX>:-fobjc-weak>
        $<$<COMPILE_LANGUAGE:C,CXX>:-Wno-gnu>)

# Add include directories
target_include_directories(macosx-test
    PRIVATE
        ${CMAKE_SOURCE_DIR}/macosx
        ${CMAKE_SOURCE_DIR})

# Link frameworks for macOS (IINAWatchHelper uses AVFoundation and CommonCrypto)
if(APPLE)
    find_library(FOUNDATION_LIB Foundation)
    target_link_libraries(macosx-test PRIVATE
        ${FOUNDATION_LIB}
        "-framework AVFoundation"
        "-framework Security")
    
    # Set minimum deployment target
    set_target_properties(macosx-test PROPERTIES
        MACOSX_RPATH ON
        OSX_DEPLOYMENT_TARGET "10.13")
endif()

if(NOT CMAKE_CROSSCOMPILING OR CMAKE_CROSSCOMPILING_EMULATOR)
    gtest_discover_tests(macosx-test
        TEST_PREFIX "macOS.")
else()
    add_test(
        NAME macosx-test
        COMMAND macosx-test)
endif()
