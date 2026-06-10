#!/usr/bin/env bash
#
# proj4/mayhem/test.sh — build PROJ's OWN gtest/ctest unit suite with NORMAL flags (separate tree)
# and RUN the self-contained subset, emitting a CTRF summary. exit 0 iff no test failed.
#
# PATCH-grade oracle: PROJ ships a real gtest suite (test/unit/*: test_crs, test_io, test_operation,
# test_factory, gie_self_tests, …) plus gie-runner regression tests, all driven by proj.db. They
# assert concrete CRS/coordinate/parse RESULTS, so a no-op / exit(0) patch to the parser or factory
# cannot pass. This script BUILDS that suite (clean, normal flags — not the fuzzer's sanitized tree)
# and RUNS it via ctest, then parses ctest's summary into CTRF.
#
# Anti-reward-hacking oracle: after ctest, we run ONE GTest binary directly with --gtest_verbose
# and check that its stdout contains GTest progress markers ([ RUN      ], [       OK ]) and specific
# known test NAMES. When a no-op/exit(0) patch neuters the program, the binary exits immediately and
# produces zero GTest output — so the grep fails and the oracle correctly rejects the patch.
#
# Network-dependent tests (test_network and the gie network cases) are excluded: they need internet
# access to grid CDNs which isn't available in the build sandbox. Everything else is self-contained
# given the proj.db generated alongside.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

: "${MAYHEM_JOBS:=$(nproc)}"
BUILDDIR="$SRC/mayhem-tests"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# ── 1) Build the test suite with NORMAL flags (no sanitizers) in a clean tree ──────────────────
# External GTest (libgtest-dev) avoids a network FetchContent. TIFF/CURL OFF (no geotiff/network).
# Static libproj so the test binaries are self-contained.
if ! command -v cmake >/dev/null 2>&1; then
  echo "cmake not available — cannot build the test suite" >&2
  emit_ctrf "ctest" 0 1 0; exit 2
fi

if [ ! -d "$BUILDDIR" ]; then
  echo "=== configuring + building PROJ test suite (normal flags) in $BUILDDIR ==="
  env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
    cmake -S "$SRC" -B "$BUILDDIR" \
      -DCMAKE_BUILD_TYPE=None \
      -DBUILD_SHARED_LIBS=OFF \
      -DBUILD_APPS=OFF \
      -DBUILD_TESTING=ON \
      -DENABLE_TIFF=OFF \
      -DENABLE_CURL=OFF \
      -DUSE_EXTERNAL_GTEST=ON \
    || { echo "cmake configure failed" >&2; emit_ctrf "ctest" 0 1 0; exit 2; }
  env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
    cmake --build "$BUILDDIR" -j"$MAYHEM_JOBS" \
    || { echo "test build failed" >&2; emit_ctrf "ctest" 0 1 0; exit 2; }
fi

# ── 2) Behavioral oracle: run test_c_api directly and assert specific output ────────────────────
# proj_test_cpp_api includes test_c_api.cpp and exercises the C API (proj_create,
# proj_normalize_for_visualization, proj_trans) with known EPSG codes.
# A no-op/exit(0) patch produces ZERO GTest output; a real PROJ produces lines like:
#   [ RUN      ] proj_test_api_1.test_proj_context_create
# We grep for GTest progress markers AND a specific test name that must appear in the output.
# The binary lands in $BUILDDIR/bin/ (CMake RUNTIME_OUTPUT_DIRECTORY).
# ctest sets PROJ_DATA=${PROJ_BINARY_DIR}/data/for_tests; replicate that here.
TEST_CPP_API="$BUILDDIR/bin/proj_test_cpp_api"
if [ ! -f "$TEST_CPP_API" ]; then
  echo "ERROR: $TEST_CPP_API not found — test suite may not have built" >&2
  emit_ctrf "ctest" 0 1 0; exit 1
fi

echo "=== behavioral oracle: running proj_test_cpp_api --gtest_filter=util.NameFactory ==="
# Run a specific GTest case from PROJ's C++ API test suite. A real PROJ run emits GTest progress
# markers and the test name; a no-op/exit(0) patch produces zero GTest output, so grep fails.
oracle_out="$(PROJ_DATA="$BUILDDIR/data/for_tests" "$TEST_CPP_API" --gtest_filter="util.NameFactory" 2>&1)" oracle_rc=$?
echo "$oracle_out"

# Assertions:
#   1. GTest [ RUN      ] marker — proves the binary actually entered GTest dispatch
#   2. "util.NameFactory" in the output — the specific test ran (not just GTest init)
#   3. "[  PASSED  ]" — the test passed (PROJ correctly handles the lookup)
if ! printf '%s\n' "$oracle_out" | grep -q '\[ RUN      \]'; then
  echo "FAIL: behavioral oracle: no GTest output from proj_test_cpp_api (expected '[ RUN      ]' markers)" >&2
  emit_ctrf "ctest" 0 1 0; exit 1
fi
if ! printf '%s\n' "$oracle_out" | grep -q 'util\.NameFactory'; then
  echo "FAIL: behavioral oracle: expected 'util.NameFactory' in proj_test_cpp_api output" >&2
  emit_ctrf "ctest" 0 1 0; exit 1
fi
if ! printf '%s\n' "$oracle_out" | grep -q '\[  PASSED  \]'; then
  echo "FAIL: behavioral oracle: proj_test_cpp_api util.NameFactory did not pass" >&2
  emit_ctrf "ctest" 0 1 0; exit 1
fi
echo "=== behavioral oracle: PASS (proj_test_cpp_api ran util.NameFactory and produced GTest output) ==="

# ── 3) RUN the full self-contained subset via ctest (ctest sets each test's PROJ_DATA env) ──────
# Exclude network tests (need internet). -E is a regex over test names.
echo "=== running ctest in $BUILDDIR ==="
out="$(cd "$BUILDDIR" && env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
        ctest --output-on-failure -E 'network|download|Network' 2>&1)"; rc=$?
echo "$out"

# ctest prints:  "N% tests passed, M tests failed out of K"
TOTAL=$(printf '%s\n' "$out" | sed -n 's/.*tests passed, [0-9][0-9]* tests failed out of \([0-9][0-9]*\).*/\1/p' | tail -1)
FAILED=$(printf '%s\n' "$out" | sed -n 's/.*tests passed, \([0-9][0-9]*\) tests failed out of [0-9][0-9]*.*/\1/p' | tail -1)
: "${TOTAL:=0}" "${FAILED:=0}"
PASSED=$(( TOTAL - FAILED ))
[ "$PASSED" -ge 0 ] || PASSED=0

# If ctest produced no parseable summary, fall back to its exit code.
if [ "$TOTAL" -eq 0 ]; then
  echo "could not parse ctest summary; using ctest exit code $rc" >&2
  [ "$rc" -eq 0 ] && { emit_ctrf "ctest" 1 0 0; exit 0; }
  emit_ctrf "ctest" 0 1 0; exit 1
fi

emit_ctrf "ctest" "$PASSED" "$FAILED" 0
