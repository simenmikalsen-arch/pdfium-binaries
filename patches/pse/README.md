# Patched build for PDF Studio Elite

Three patches, applied in order by `steps/03-patch.sh` for every target. The DLL is marked by
`patches/win/resources.rc` (`FileDescription` names the patches, `ProductVersion` suffix `-pse2`;
`FileVersion` stays the numeric PDFium version). Everything else is identical to the upstream
bblanchon/pdfium-binaries build.

## 0001 - GenerateContent performance

`0001-generatecontent-perf.patch` modifies PDFium's
`core/fpdfapi/edit/cpdf_pagecontentgenerator.cpp` and `.h` (plus its unit test) so that
`FPDFPage_GenerateContent()` is no longer quadratic in the number of image/form XObjects on a page:

1. `RealizeResource()` resumes the search for a free `FX<type><n>` name where the previous search
   for that type stopped, instead of starting from 1 for every object.
2. `ProcessImage()` / `ProcessForm()` keep an object's existing resource name when the page's
   resource dictionary still maps that name to the same XObject, instead of adding a new name
   (this also stops the `/Fm0` -> `/FXX1` renaming and the resource-dictionary growth on every edit).
3. `FindKeysToRestore()` looks keys up in a `std::set` instead of a linear search.

Rendering output is unchanged.

The same change is being prepared for upstream PDFium; drop this patch once it lands there.

`.github/workflows/pse-tests.yml` builds `pdfium_unittests` and `pdfium_embeddertests` on Linux
before and after applying the patch and fails on new test failures.

Build for a new PDFium release: rebase this branch onto the new bblanchon tag
(`chromium/NNNN`), then run the "Build one" workflow with `branch=chromium/NNNN`,
`version=<major>.0.NNNN.0`, `target_os=win`, `target_cpu=x64`.

## 0002 - popup-lazy-appearance (render bloat, https://crbug.com/42270200)

Every `CPDF_AnnotList` construction - every render call with `FPDF_ANNOT`, every form-fill page view -
creates a Popup annotation for each markup annotation with `/Contents`, and `CPDF_Annot`'s constructor
generated the popup's appearance at once: a new indirect appearance stream and a new indirect font
dictionary per markup per render call, never referenced, kept in memory until the document is closed and
written by every full save (5,000 commented markups: +3.1 MB per render call and about 0.8 s of the call).
`0002-popup-lazy-appearance.patch` changes `core/fpdfdoc/cpdf_annot.cpp` so that a Popup's appearance is
generated only when it is drawn (only while it is open), which `DrawAppearance()` / `DrawInContext()`
already do on demand. New tests: `CPDFAnnotListTest.CreatePopupAnnotAddsNoObjectsToDocument` (unit),
`FPDFAnnotEmbedderTest.RenderAddsNoPopupObjectsToDocument` (embedder). `FPDFAnnotEmbedderTest.Bug1206`
asserted the bug (`EXPECT_GT` with a TODO saying the size should be equal); it now expects equal sizes.

## 0003 - save-reachable-objects

A full (non-incremental) save already wrote only the PARSED objects that are reachable from the trailer,
but every NEW object - including unreferenced ones, e.g. an appearance stream that was replaced or removed -
was written. `0003-save-reachable-objects.patch` changes `core/fpdfapi/edit/cpdf_creator.cpp` and `.h`:

* A full save writes only the new objects that are reachable from the trailer, too (the reachable set is
  computed once and shared with the parsed objects, so it costs nothing extra for a parsed document).
* The same for documents without a parser (`FPDF_CreateNewDocument()`, e.g. with imported pages from
  split / combine / `FPDF_ImportPages`): reachable from `/Root` and `/Info`, the two entries such a
  trailer has.
* The trailer's `/Encrypt` reference of a DIRECT encryption dictionary (one written directly in the file's trailer,
  or the one `InitID()` re-creates for a revision 2/3 document without a trailer `/ID`) names the object number it
  was actually written as (`last_obj_num_`), not `GetLastObjNum() + 1`: the two differ once unreferenced new objects
  are skipped, and the saved file's `/Encrypt` would point nowhere.

Incremental saves are unchanged (they write every new object). New embedder tests:
`FPDFSaveEmbedderTest.SaveSkipsUnreferencedNewObjects`, `.SaveNewDocSkipsUnreferencedNewObjects`,
`.SaveImportedPagesSkipsReplacedAppearances`, `CPDFSecurityHandlerEmbedderTest.SaveWithUnreferencedNewObjectVersion3`.

`.github/workflows/pse-tests.yml` requires all of the new tests, `Bug1206` and 0001's `KeepXObjectNames` to pass, and
no test that passes without the patches to fail with them. Upstream `main` (2026-09-24) still has both problems.
