# Exclude Homebrew paths from library discovery on macOS.
# Bundled third-party deps are used instead of /opt/homebrew dylibs.

function(tr_path_is_homebrew PATH_OUT RESULT)
    set(_is_hb FALSE)
    if("${PATH_OUT}" MATCHES "^/opt/homebrew(/|$)"
            OR "${PATH_OUT}" MATCHES "^/usr/local/(Cellar|opt|Homebrew)(/|$)")
        set(_is_hb TRUE)
    endif()
    set(${RESULT} "${_is_hb}" PARENT_SCOPE)
endfunction()

function(tr_filter_homebrew_paths PATHS_VAR OUT_VAR)
    set(_filtered)
    foreach(_path IN LISTS ${PATHS_VAR})
        tr_path_is_homebrew("${_path}" _is_hb)
        if(NOT _is_hb)
            list(APPEND _filtered "${_path}")
        endif()
    endforeach()
    set(${OUT_VAR} "${_filtered}" PARENT_SCOPE)
endfunction()

function(tr_filter_homebrew_path_list PATH_LIST OUT_VAR)
    if("${PATH_LIST}" STREQUAL "")
        set(${OUT_VAR} "" PARENT_SCOPE)
        return()
    endif()
    string(REPLACE ":" ";" _paths "${PATH_LIST}")
    tr_filter_homebrew_paths(_paths _filtered)
    string(REPLACE ";" ":" _joined "${_filtered}")
    set(${OUT_VAR} "${_joined}" PARENT_SCOPE)
endfunction()

macro(tr_ignore_homebrew)
    set(_TR_HB_IGNORE
        /opt/homebrew
        /opt/homebrew/bin
        /opt/homebrew/include
        /opt/homebrew/lib
        /opt/homebrew/opt
        /opt/homebrew/Cellar
        /opt/homebrew/share
        /usr/local/Cellar
        /usr/local/opt
        /usr/local/Homebrew)

    list(APPEND CMAKE_IGNORE_PATH ${_TR_HB_IGNORE})
    if(CMAKE_VERSION VERSION_GREATER_EQUAL "3.24")
        list(APPEND CMAKE_IGNORE_PREFIX_PATH /opt/homebrew /usr/local/Cellar /usr/local/opt)
    endif()

    tr_filter_homebrew_paths(CMAKE_PREFIX_PATH _prefix)
    set(CMAKE_PREFIX_PATH "${_prefix}")

    tr_filter_homebrew_paths(CMAKE_INCLUDE_PATH _include)
    set(CMAKE_INCLUDE_PATH "${_include}")

    tr_filter_homebrew_paths(CMAKE_LIBRARY_PATH _library)
    set(CMAKE_LIBRARY_PATH "${_library}")

    tr_filter_homebrew_paths(CMAKE_PROGRAM_PATH _program)
    set(CMAKE_PROGRAM_PATH "${_program}")

    if(DEFINED ENV{PKG_CONFIG_PATH})
        tr_filter_homebrew_path_list("$ENV{PKG_CONFIG_PATH}" _pc_path)
        set(ENV{PKG_CONFIG_PATH} "${_pc_path}")
    endif()

    if(DEFINED ENV{PKG_CONFIG_LIBDIR})
        tr_filter_homebrew_path_list("$ENV{PKG_CONFIG_LIBDIR}" _pc_libdir)
        set(ENV{PKG_CONFIG_LIBDIR} "${_pc_libdir}")
    endif()

    if(DEFINED ENV{LIBRARY_PATH})
        tr_filter_homebrew_path_list("$ENV{LIBRARY_PATH}" _lib_path)
        set(ENV{LIBRARY_PATH} "${_lib_path}")
    endif()

    if(DEFINED ENV{C_INCLUDE_PATH})
        tr_filter_homebrew_path_list("$ENV{C_INCLUDE_PATH}" _c_include)
        set(ENV{C_INCLUDE_PATH} "${_c_include}")
    endif()

    if(DEFINED ENV{CPLUS_INCLUDE_PATH})
        tr_filter_homebrew_path_list("$ENV{CPLUS_INCLUDE_PATH}" _cxx_include)
        set(ENV{CPLUS_INCLUDE_PATH} "${_cxx_include}")
    endif()

    unset(_TR_HB_IGNORE)
endmacro()
