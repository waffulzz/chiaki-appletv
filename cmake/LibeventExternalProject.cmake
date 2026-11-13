
include(FetchContent)

set(EVENT__LIBRARY_TYPE STATIC CACHE STRING "" FORCE)
set(EVENT__DISABLE_OPENSSL ON CACHE BOOL "" FORCE)
set(EVENT__DISABLE_MBEDTLS ON CACHE BOOL "" FORCE)
set(EVENT__DISABLE_BENCHMARK ON CACHE BOOL "" FORCE)
set(EVENT__DISABLE_TESTS ON CACHE BOOL "" FORCE)
set(EVENT__DISABLE_REGRESS ON CACHE BOOL "" FORCE)
set(EVENT__DISABLE_SAMPLES ON CACHE BOOL "" FORCE)
set(EVENT__DISABLE_DEBUG_MODE ON CACHE BOOL "" FORCE)

FetchContent_Declare(libevent
	URL https://github.com/libevent/libevent/releases/download/release-2.1.12-stable/libevent-2.1.12-stable.tar.gz
	URL_HASH SHA256=92e6de1be9ec176428fd2367677e61ceffc2ee1cb119035037a27d346b0403bb
)
FetchContent_MakeAvailable(libevent)

set(LIBEVENT_INCLUDE_DIRS "${libevent_SOURCE_DIR}/include" "${libevent_BINARY_DIR}/include")
set(LIBEVENT_LIBRARIES event_core_static)
