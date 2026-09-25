# Patched build for PDF Studio Elite: GenerateContent performance

`0001-generatecontent-perf.patch` modifies PDFium's
`core/fpdfapi/edit/cpdf_pagecontentgenerator.cpp` and `.h` (plus its unit test) so that
`FPDFPage_GenerateContent()` is no longer quadratic in the number of image/form XObjects on a page:

1. `RealizeResource()` resumes the search for a free `FX<type><n>` name where the previous search
   for that type stopped, instead of starting from 1 for every object.
2. `ProcessImage()` / `ProcessForm()` keep an object's existing resource name when the page's
   resource dictionary still maps that name to the same XObject, instead of adding a new name
   (this also stops the `/Fm0` -> `/FXX1` renaming and the resource-dictionary growth on every edit).
3. `FindKeysToRestore()` looks keys up in a `std::set` instead of a linear search.

Rendering output is unchanged. `steps/03-patch.sh` applies the patch for every target;
`patches/win/resources.rc` marks the DLL (`FileDescription`, `ProductVersion` suffix `-pse1`).
Everything else is identical to the upstream bblanchon/pdfium-binaries build.

The same change is being prepared for upstream PDFium; drop this patch once it lands there.

`.github/workflows/pse-tests.yml` builds `pdfium_unittests` and `pdfium_embeddertests` on Linux
before and after applying the patch and fails on new test failures.

Build for a new PDFium release: rebase this branch onto the new bblanchon tag
(`chromium/NNNN`), then run the "Build one" workflow with `branch=chromium/NNNN`,
`version=<major>.0.NNNN.0`, `target_os=win`, `target_cpu=x64`.

## 0002 + 0003 - popup / render bloat SPIKE (branch pse/popup-bloat-spike only, not for release)

Prototypes for the PDF Studio Elite render-bloat spike (docs/RENDER-BLOAT-SPIKE.md in that repository). Every
`CPDF_AnnotList` construction (every render call with `FPDF_ANNOT`) creates a Popup annotation for each markup with
`/Contents`, and `CPDF_Annot`'s constructor generated its appearance at once: a new appearance stream and a new font
dictionary per markup per render call, never referenced, but written by every full save.

* `0002-popup-lazy-appearance-spike.patch`: a Popup's appearance is generated only when it is drawn (open), which
  `DrawAppearance()` / `DrawInContext()` already do on demand. One new unit test, one new embedder test.
* `0003-save-reachable-objects-spike.patch`: a full (non-incremental) save of a parsed document writes only the NEW
  objects that are reachable from the trailer, exactly as it already does for the parsed ones (the reachability set is
  computed once and shared). One new embedder test.

The DLL says `-pse1bloatspike` in its ProductVersion.