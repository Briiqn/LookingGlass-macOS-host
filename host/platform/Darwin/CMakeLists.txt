cmake_minimum_required(VERSION 3.10)
project(platform_Darwin LANGUAGES C OBJC)

include_directories(
  ${PROJECT_SOURCE_DIR}/include
)

add_library(platform_Darwin STATIC
  src/platform.c
  src/input.m
)

target_compile_options(platform_Darwin PRIVATE $<$<COMPILE_LANGUAGE:OBJC>:-fobjc-arc>)
target_compile_definitions(platform_Darwin PRIVATE LG_HOST_INPUT)

add_subdirectory("capture")

target_link_libraries(platform_Darwin
  m
  capture
  pthread
  "-framework CoreGraphics"
  "-framework ApplicationServices"
  "-framework AppKit"
  "-framework IOKit"
)

target_include_directories(platform_Darwin
  PRIVATE
    src
)
