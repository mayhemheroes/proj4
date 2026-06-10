#!/usr/bin/env bash
#
# proj4/mayhem/build.sh — build OSGeo/PROJ's single OSS-Fuzz harness as a sanitized libFuzzer
# target (+ a standalone reproducer), with PROJ itself instrumented.
#
#   proj_crs_to_crs_fuzzer — splits the input blob into TWO lines (source_crs\ndest_crs), each a
#     CRS/PROJ-string / WKT / EPSG definition, and calls proj_create_crs_to_crs(src, dst) then
#     proj_destroy/proj_cleanup. The fuzzed surface is PROJ's CRS-string / WKT / proj-string PARSER
#     and the proj.db (sqlite) CRS lookup it drives. Inputs are NOT binary grids — they are
#     newline-separated text CRS definitions (see mayhem/testsuite + mayhem/proj_crs_to_crs_fuzzer.dict).
#
# proj.db (sqlite) MUST be present at runtime for parsing to reach the CRS factory: the harness's
# LLVMFuzzerInitialize sets PROJ_DATA to the binary's own directory (argv[0] dir). We therefore
# generate proj.db at build time and copy it (plus the proj-data files PROJ ships) next to each
# binary under /mayhem so the lookup resolves with no external mount.
#
# Build contract comes from the org base ENV (CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/
# STANDALONE_FUZZ_MAIN). We compile libproj WITH $SANITIZER_FLAGS so the parser/factory code
# (not just the harness) is instrumented. TIFF/CURL are OFF (grid-network/geotiff features the CRS
# parser does not need) to keep deps to just sqlite3 + a C++ toolchain.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS: DWARF ≤ 3 required for Mayhem triage (clang-19 plain -g emits DWARF-5). `:=` keeps
# an explicit override; we always emit this for harness + standalone + library compiles.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

OUT="${OUT:-/mayhem}"
mkdir -p "$OUT"
HARNESS_SRC="$SRC/test/fuzzers/proj_crs_to_crs_fuzzer.cpp"

# ── 1) Configure + build libproj (static) WITH sanitizers ──────────────────────────────────────
# Instrument the library so the fuzzed parser/CRS-factory code is sanitized, not just the harness.
# TIFF/CURL OFF: the crs_to_crs parser doesn't need geotiff grids or network grid fetch.
# Coverage instrumentation for the LIBRARY: linking a libFuzzer harness against a plain .a only
# instruments the harness, so the fuzzer sees `cov: 2` and never explores PROJ. Compile libproj with
# `-fsanitize=fuzzer-no-link` (adds SanitizerCoverage edge/cmp tracking WITHOUT pulling in a second
# libFuzzer main) on top of $SANITIZER_FLAGS so the parser/factory edges feed the fuzzer.
COV_FLAG="-fsanitize=fuzzer-no-link"
# When sanitizers are explicitly disabled (empty SANITIZER_FLAGS via --build-arg), skip coverage too.
[ -n "$SANITIZER_FLAGS" ] || COV_FLAG=""
# $DEBUG_FLAGS comes AFTER $SANITIZER_FLAGS so -gdwarf-3 overrides any -g implicit in sanitizer flags.
LIB_BUILD_FLAGS="$SANITIZER_FLAGS $COV_FLAG $DEBUG_FLAGS"

BUILD="$SRC/mayhem-build"
rm -rf "$BUILD"; mkdir -p "$BUILD"
cmake -S "$SRC" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=None \
  -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_APPS=OFF \
  -DBUILD_TESTING=OFF \
  -DENABLE_TIFF=OFF \
  -DENABLE_CURL=OFF \
  -DCMAKE_C_COMPILER="$CC" \
  -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$LIB_BUILD_FLAGS" \
  -DCMAKE_CXX_FLAGS="$LIB_BUILD_FLAGS"

# Build libproj + generate proj.db. proj.db comes from the `generate_proj_db` target (an ALL
# target in data/CMakeLists.txt); build it EXPLICITLY since `--target proj` alone won't pull it in.
cmake --build "$BUILD" --target proj generate_proj_db -j"$MAYHEM_JOBS"

# Locate the just-built static libproj and generated proj.db.
LIBPROJ="$(find "$BUILD" -name 'libproj.a' | head -1)"
[ -n "$LIBPROJ" ] || { echo "ERROR: libproj.a not found in $BUILD" >&2; exit 1; }
PROJ_DB="$(find "$BUILD" -name 'proj.db' | head -1)"
[ -n "$PROJ_DB" ] || { echo "ERROR: proj.db not generated in $BUILD" >&2; exit 1; }
echo "libproj: $LIBPROJ"
echo "proj.db: $PROJ_DB"

# ── 2) Stage the PROJ data (incl. proj.db) next to the binaries ────────────────────────────────
# The harness sets PROJ_DATA to argv[0]'s directory, so proj.db must live there. Both binaries land
# in $OUT, so a single proj.db in $OUT serves both.
cp "$PROJ_DB" "$OUT/proj.db"
# Ship the shipped proj-data resource files too (proj.ini, ellipsoids, etc.) — harmless if unused.
cp -f "$SRC"/data/*.tif "$OUT"/ 2>/dev/null || true
for f in proj.ini world other.extra; do
  [ -f "$SRC/data/$f" ] && cp -f "$SRC/data/$f" "$OUT"/ || true
done

# ── 3) Build the harness twice: libFuzzer (-> $OUT/<name>) + standalone reproducer ─────────────
INCS="-I$SRC/src -I$SRC/include"
# sqlite3 + pthread are the only external link deps once TIFF/CURL are off.
LINK_LIBS="-lsqlite3 -lpthread"

echo "Building proj_crs_to_crs_fuzzer (libFuzzer)"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++17 -fvisibility=hidden $INCS \
    "$HARNESS_SRC" $LIB_FUZZING_ENGINE "$LIBPROJ" $LINK_LIBS \
    -o "$OUT/proj_crs_to_crs_fuzzer"

# Standalone reproducer: the harness file ITSELF provides main() under -DSTANDALONE (no libFuzzer
# runtime), reading one input file. STANDALONE_FUZZ_MAIN is unused here because the harness is
# self-contained; we just compile with -DSTANDALONE.
echo "Building proj_crs_to_crs_fuzzer-standalone"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++17 -DSTANDALONE -fvisibility=hidden $INCS \
    "$HARNESS_SRC" "$LIBPROJ" $LINK_LIBS \
    -o "$OUT/proj_crs_to_crs_fuzzer-standalone"

echo "build.sh complete:"
ls -la "$OUT/proj_crs_to_crs_fuzzer" "$OUT/proj_crs_to_crs_fuzzer-standalone" "$OUT/proj.db" 2>&1 || true
