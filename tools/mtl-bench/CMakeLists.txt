cmake_minimum_required(VERSION 3.20)
project(mtl_bench LANGUAGES CXX OBJCXX)

if(NOT APPLE)
  message(FATAL_ERROR "mtl-bench targets Metal and only builds on macOS")
endif()

# Default to an optimized build: with no optimization the command-buffer
# allocation loop stalls on the AMD MPX driver (observed macOS 26.6.2,
# W6800X Duo; see docs/metal/gotchas.md).
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

add_executable(mtl-bench main.mm)
set_source_files_properties(main.mm PROPERTIES LANGUAGE OBJCXX)
target_compile_features(mtl-bench PRIVATE cxx_std_17)
target_compile_options(mtl-bench PRIVATE -fobjc-arc -Wall)
target_link_libraries(mtl-bench PRIVATE "-framework Metal" "-framework Foundation")
