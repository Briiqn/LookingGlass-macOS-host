cmake_minimum_required(VERSION 3.10)
project(capture_ScreenCaptureKit LANGUAGES C OBJC)

add_library(capture_ScreenCaptureKit STATIC
  src/sck.m
)

target_compile_options(capture_ScreenCaptureKit PRIVATE -fobjc-arc)

target_link_libraries(capture_ScreenCaptureKit
  lg_common
  "-framework Foundation"
  "-framework AppKit"
  "-framework CoreMedia"
  "-framework CoreVideo"
  "-framework CoreGraphics"
  "-framework ScreenCaptureKit"
)

target_include_directories(capture_ScreenCaptureKit
  PRIVATE
    src
)
