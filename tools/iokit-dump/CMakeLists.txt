cmake_minimum_required(VERSION 3.16)
project(iokit-dump C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

add_executable(iokit-dump main.c)
target_compile_options(iokit-dump PRIVATE -Wall -Wextra)
target_link_libraries(iokit-dump PRIVATE
  "-framework CoreFoundation"
  "-framework IOKit"
)
