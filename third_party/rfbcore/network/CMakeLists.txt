add_library(network STATIC
  Socket.cxx
  TcpSocket.cxx)

if(NOT WIN32)
  target_sources(network PRIVATE UnixSocket.cxx)
endif()

target_include_directories(network PUBLIC ${ZV_COMMON_DIR})
target_link_libraries(network core rdr)

if(WIN32)
	target_link_libraries(network ws2_32)
endif()

