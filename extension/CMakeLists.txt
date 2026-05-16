cmake_minimum_required(VERSION 3.24)
project(sd_nnue LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(SOURCEMOD_ROOT "" CACHE PATH "Path to an AlliedModders SourceMod source checkout")
if(NOT SOURCEMOD_ROOT)
  message(FATAL_ERROR "Set -DSOURCEMOD_ROOT=<path to SourceMod source checkout>")
endif()

add_library(sd_nnue_ext SHARED
  src/extension.cpp
  src/natives.cpp
  src/score_cache.cpp
  src/cpu_nnue_backend.cpp
  src/score_service.cpp
  "${SOURCEMOD_ROOT}/public/smsdk_ext.cpp"
)

target_include_directories(sd_nnue_ext PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/src"
  "${SOURCEMOD_ROOT}/public"
  "${SOURCEMOD_ROOT}/sourcepawn/include"
  "${SOURCEMOD_ROOT}/public/amtl"
  "${SOURCEMOD_ROOT}/public/amtl/amtl"
)

if(MSVC)
  target_compile_options(sd_nnue_ext PRIVATE /O2 /EHsc /W4)
else()
  target_compile_options(sd_nnue_ext PRIVATE -O3 -Wall -Wextra -Wpedantic -fPIC)
endif()

set_target_properties(sd_nnue_ext PROPERTIES
  PREFIX ""
  OUTPUT_NAME "sd_nnue.ext"
)
