
add_library(chiaki-tvos STATIC include/chiakitv.h src/chiakitv.c)
target_include_directories(chiaki-tvos PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(chiaki-tvos chiaki-lib)
