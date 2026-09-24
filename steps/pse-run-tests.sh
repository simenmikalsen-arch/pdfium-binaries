#!/bin/bash -ux
# Patched build for PDF Studio Elite: runs PDFium's tests and lists the failing
# ones in <label>-failures.txt. Test failures do not fail this script.

LABEL=${1:?}
OUT=pdfium/out

$OUT/pdfium_unittests --gtest_filter='CPDFPageContentGenerator*' \
  >"$LABEL-generator.log" 2>&1
echo "generator unit tests exit code: $?"
$OUT/pdfium_unittests --gtest_brief=1 >"$LABEL-unittests.log" 2>&1
echo "unit tests exit code: $?"
$OUT/pdfium_embeddertests --gtest_brief=1 >"$LABEL-embeddertests.log" 2>&1
echo "embedder tests exit code: $?"

tail -n 5 "$LABEL-generator.log" "$LABEL-unittests.log" "$LABEL-embeddertests.log"

grep -h '^\[  FAILED  \] [A-Za-z]' "$LABEL-unittests.log" "$LABEL-embeddertests.log" |
  sed -e 's/ (.*//' -e 's/, where .*//' | sort -u >"$LABEL-failures.txt"
exit 0
