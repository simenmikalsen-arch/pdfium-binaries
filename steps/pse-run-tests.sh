#!/bin/bash -ux
# Patched build for PDF Studio Elite: runs PDFium's tests and lists the failing
# ones in <label>-failures.txt. Test failures do not fail this script.

LABEL=${1:?}
OUT=pdfium/out/Release
SHARDS=4

$OUT/pdfium_unittests --gtest_filter='CPDFPageContentGenerator*' \
  >"$LABEL-generator.log" 2>&1
echo "generator unit tests exit code: $?"
timeout 20m $OUT/pdfium_unittests --gtest_brief=1 >"$LABEL-unittests.log" 2>&1
echo "unit tests exit code: $?"

# The embedder tests run in parallel shards, each with a time limit; a shard
# that times out is listed as a failure (with the test it was running).
for ((i = 0; i < SHARDS; i++)); do
  (
    GTEST_TOTAL_SHARDS=$SHARDS GTEST_SHARD_INDEX=$i timeout 40m \
      $OUT/pdfium_embeddertests >"$LABEL-embeddertests-$i.log" 2>&1
    code=$?
    echo "embedder tests shard $i exit code: $code"
    if [ $code -eq 124 ]; then
      echo "[  FAILED  ] TIMEOUT in shard $i: $(grep '^\[ RUN      \]' "$LABEL-embeddertests-$i.log" | tail -n 1)" \
        >>"$LABEL-embeddertests-$i.log"
    fi
  ) &
done
wait

tail -n 3 "$LABEL"-*.log

grep -h '^\[  FAILED  \] [A-Za-z]' "$LABEL-unittests.log" "$LABEL"-embeddertests-*.log |
  sed -e 's/ ([0-9]* ms)$//' -e 's/, where .*//' | sort -u >"$LABEL-failures.txt"
exit 0
