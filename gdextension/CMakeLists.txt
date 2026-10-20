cmake_minimum_required(VERSION 3.18)

project(sw_circuit_native LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# godot-cpp 绑定库：由 GODOT_CPP_DIR 指向已生成/编译的 4.7.2 绑定
set(GODOT_CPP_DIR "J:/godot/godot-cpp-47" CACHE PATH "path to configured godot-cpp tree")
set(GODOT_CPP_TARGET_NAME "libgodot-cpp.windows.template_debug.x86_64"
	CACHE STRING "static lib name produced by that godot-cpp build")

include_directories(
	include
	"${GODOT_CPP_DIR}/include"
	"${GODOT_CPP_DIR}/build/gen/include"
)
link_directories("${GODOT_CPP_DIR}/build/bin")

add_library(sw_circuit_native SHARED
	src/register_types.cpp
	src/sw_bool_eval.cpp
)

# 与 godot-cpp 那次 configure 的编译宏逐条对齐：DEBUG_ENABLED 之类影响头文件里的
# 内联布局，TYPED_METHOD_BIND 决定 bind_method 的成员指针写法，缺一个就编不过
target_compile_definitions(sw_circuit_native PRIVATE
	WINDOWS_ENABLED GDEXTENSION DEBUG_ENABLED HOT_RELOAD_ENABLED THREADS_ENABLED)

if(MSVC)
	# 注释里有中文，不加 /utf-8 时 MSVC 按本地代码页解析，多字节尾缀会吞掉行尾
	target_compile_options(sw_circuit_native PRIVATE /utf-8 /wd4251 /wd4275)
	target_compile_definitions(sw_circuit_native PRIVATE TYPED_METHOD_BIND NOMINMAX _HAS_EXCEPTIONS=0)
	# 预编译的 libgodot-cpp.windows.template_debug.x86_64.lib 是 /MD（MD_DynamicRelease、
	# _ITERATOR_DEBUG_LEVEL=0）——名字里的 template_debug 指 Godot 侧的 DEBUG_ENABLED，与 CRT 无关。
	# 这里对全部配置强制 /MD：用 Debug 配置链接会触发 LNK1319 运行时不匹配，
	# 而且失败链接会把 bin/ 里已有的 dll 删掉。构建请固定用 --config Release。
	set_property(TARGET sw_circuit_native PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")
	target_link_libraries(sw_circuit_native PRIVATE "${GODOT_CPP_TARGET_NAME}.lib")
else()
	target_compile_options(sw_circuit_native PRIVATE -Wall -Wextra)
	target_link_libraries(sw_circuit_native PRIVATE "${GODOT_CPP_TARGET_NAME}")
endif()

# VS 是多配置生成器，只设 RUNTIME_OUTPUT_DIRECTORY 会追加 bin/<Config> 子目录，
# 与 .gdextension 里写死的 res:// 路径不符，因此逐配置指定
set_target_properties(sw_circuit_native PROPERTIES
	PREFIX "lib"
	SUFFIX ".windows.debug.x86_64.dll"
	RUNTIME_OUTPUT_DIRECTORY_DEBUG "${CMAKE_CURRENT_SOURCE_DIR}/bin"
	RUNTIME_OUTPUT_DIRECTORY_RELEASE "${CMAKE_CURRENT_SOURCE_DIR}/bin"
	RUNTIME_OUTPUT_DIRECTORY_RELWITHDEBINFO "${CMAKE_CURRENT_SOURCE_DIR}/bin"
	RUNTIME_OUTPUT_DIRECTORY_MINSIZEREL "${CMAKE_CURRENT_SOURCE_DIR}/bin"
	LIBRARY_OUTPUT_DIRECTORY_DEBUG "${CMAKE_CURRENT_SOURCE_DIR}/bin"
	LIBRARY_OUTPUT_DIRECTORY_RELEASE "${CMAKE_CURRENT_SOURCE_DIR}/bin"
)
