cmake_minimum_required(VERSION 3.10)
project(capture LANGUAGES C)

include("PreCapture")

add_capture("ScreenCaptureKit")

include("PostCapture")

add_library(capture STATIC ${CAPTURE_C})
target_link_libraries(capture ${CAPTURE_LINK})
