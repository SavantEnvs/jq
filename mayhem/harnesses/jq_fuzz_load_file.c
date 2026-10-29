// Same code path as tests/jq_fuzz_load_file.c (jv_load_file, both raw and non-raw), but the scratch
// file lives under $TMPDIR (mkstemp) instead of a hardcoded /tmp/libfuzzer.<pid>.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#include "jv.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  const char *tmpdir = getenv("TMPDIR");
  char filename[4096];
  snprintf(filename, sizeof(filename), "%s/jqfuzzXXXXXX", tmpdir && *tmpdir ? tmpdir : "/tmp");
  int fd = mkstemp(filename);
  if (fd < 0) {
    return 0;
  }
  FILE *fp = fdopen(fd, "wb");
  if (!fp) {
    close(fd);
    unlink(filename);
    return 0;
  }
  fwrite(data, size, 1, fp);
  fclose(fp);

  jv data1 = jv_load_file(filename, 1);
  jv_free(data1);
  jv data2 = jv_load_file(filename, 0);
  jv_free(data2);

  unlink(filename);
  return 0;
}
