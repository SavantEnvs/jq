#!/usr/bin/env bash
#
# mayhem/build.sh — build jq's libFuzzer harnesses (sanitized, DWARF 3), their -standalone
# reproducers, and the normal-flags jq used by mayhem/test.sh. Runs in /mayhem as `mayhem`,
# offline: oniguruma is the in-tree vendor/oniguruma submodule and autoconf/automake/libtool are
# installed in the image.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

SRC="${SRC:-/mayhem}"
cd "$SRC"

# configure and the generated sources are gitignored; (re)create them here so a `git clean -ffdX`-ed
# tree builds too. The submodule must already be in the tree.
[ -f vendor/oniguruma/src/regcomp.c ] || { echo "vendor/oniguruma is empty (submodule not checked out)" >&2; exit 1; }
autoreconf -fi

COMMON_CONFIG=(--with-oniguruma=builtin --enable-static --disable-shared --disable-docs
               --disable-valgrind --disable-maintainer-mode)

# 1) NORMAL-flags jq for the test suite (build/ is gitignored by build/.gitignore).
mkdir -p build/test
(cd build/test
 env -u CFLAGS -u LDFLAGS CC="$CC" "$SRC/configure" "${COMMON_CONFIG[@]}" \
     CFLAGS="-O2 -g $COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS"
 make -j"$MAYHEM_JOBS")

# 2) Sanitized libjq + libonig, also coverage-instrumented (fuzzer-no-link) so Mayhem/libFuzzer see
#    edges inside the library, not just in the harness. Leak detection is off during configure's
#    probe programs only.
COV_FLAGS=""
[ -z "$LIB_FUZZING_ENGINE" ] || COV_FLAGS="-fsanitize=fuzzer-no-link"
mkdir -p build/san
(cd build/san
 ASAN_OPTIONS=detect_leaks=0 CC="$CC" "$SRC/configure" "${COMMON_CONFIG[@]}" \
     CFLAGS="-O1 $SANITIZER_FLAGS $COV_FLAGS $DEBUG_FLAGS" LDFLAGS="$SANITIZER_FLAGS $COV_FLAGS"
 ASAN_OPTIONS=detect_leaks=0 make -j"$MAYHEM_JOBS")

LIBJQ="$SRC/build/san/.libs/libjq.a"
LIBONIG="$(find "$SRC/build/san" -name libonig.a | head -n1)"
[ -f "$LIBJQ" ] && [ -f "$LIBONIG" ] || { echo "missing libjq.a/libonig.a" >&2; exit 1; }
INC=(-I"$SRC/src" -I"$SRC/build/san" -I"$SRC/vendor/oniguruma/src")

# 3) Harnesses: each linked once with libFuzzer and once with the run-once standalone driver, both
#    with leak detection compiled out (mayhem/lsan_off.cc).
OBJ="$(mktemp -d)"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$OBJ/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$OBJ/standalone_main.o"

build_harness() { # <name> <source>
  local name="$1" src="$2" compiler="$CC" std=()
  case "$src" in *.cpp) compiler="$CXX" ;; esac
  $compiler -O1 $SANITIZER_FLAGS $DEBUG_FLAGS "${INC[@]}" $LIB_FUZZING_ENGINE "$src" \
      "$OBJ/lsan_off.o" "$LIBJQ" "$LIBONIG" -lm -o "/mayhem/$name"
  $compiler -O1 $SANITIZER_FLAGS $DEBUG_FLAGS "${INC[@]}" "$src" "$OBJ/standalone_main.o" \
      "$OBJ/lsan_off.o" "$LIBJQ" "$LIBONIG" -lm -o "/mayhem/$name-standalone"
}

build_harness jq_fuzz_compile        "$SRC/tests/jq_fuzz_compile.c"
build_harness jq_fuzz_execute        "$SRC/tests/jq_fuzz_execute.cpp"
build_harness jq_fuzz_fixed          "$SRC/tests/jq_fuzz_fixed.cpp"
build_harness jq_fuzz_load_file      "$SRC/mayhem/harnesses/jq_fuzz_load_file.c"
build_harness jq_fuzz_parse          "$SRC/tests/jq_fuzz_parse.c"
build_harness jq_fuzz_parse_extended "$SRC/tests/jq_fuzz_parse_extended.c"
build_harness jq_fuzz_parse_stream   "$SRC/tests/jq_fuzz_parse_stream.c"
rm -rf "$OBJ"
