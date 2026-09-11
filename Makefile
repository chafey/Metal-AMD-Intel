# Metal-AMD-Intel build entry points
#
# Swift artifacts use SwiftPM; C/C++ artifacts use CMake. CMake-backed
# directories only build once their CMakeLists.txt exists (implemented for
# tools/iokit-dump; mtl-bench and the C/C++ examples land in Phases 3-4).

BUILD_DIR := build

.PHONY: all tools examples ccpp swift-fmt c-fmt fmt-check clean

all: tools examples ccpp

tools:
	@echo "==> swift build tools"
	swift build --package-path tools -c release

examples:
	@echo "==> swift build examples"
	swift build --package-path examples/swift -c release

# Build every CMake project that has a CMakeLists.txt
ccpp:
	@for d in tools/mtl-bench tools/iokit-dump examples/c-cpp/metal-c-basic examples/c-cpp/mpsc-ring; do \
		if [ -f "$$d/CMakeLists.txt" ]; then \
			echo "==> cmake $$d"; \
			cmake -S "$$d" -B "$(BUILD_DIR)/$$d" && cmake --build "$(BUILD_DIR)/$$d"; \
		else \
			echo "==> skipping $$d (no CMakeLists.txt yet)"; \
		fi; \
	done

swift-fmt:
	swift-format format -i -r tools/Sources examples/swift/Sources 2>/dev/null || true

c-fmt:
	@find tools examples -name '*.[ch]' -o -name '*.cc' -o -name '*.hpp' | xargs -r clang-format -i

fmt-check:
	swift-format lint -s -r tools/Sources examples/swift/Sources
	@echo "swift-format lint OK"

clean:
	rm -rf .build tools/.build examples/swift/.build $(BUILD_DIR)
