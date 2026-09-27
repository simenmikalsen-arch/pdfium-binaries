# Patched build for PDF Studio Elite

Four patches, applied in order by `steps/03-patch.sh` for every target. The DLL is marked by
`patches/win/resources.rc` (`FileDescription` names the patches, `ProductVersion` suffix `-pse3`;
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

## 0004 - save-omits-generated-appearances

When PDFium draws an annotation that has no appearance stream (a render with `FPDF_ANNOT`, a form-fill page
view), `CPDF_Annot` generates one, writes it into the annotation dictionary as `/AP` and marks the dictionary with
`/PDFIUM_HasGeneratedAP true`. A save wrote both, so what a save wrote depended on which pages had been drawn
(a 5,000-markup sheet: 2.0 MB saved before any render, 4.4 MB after), and PDFium's private key ended up in files.
`0004-save-omits-generated-appearances.patch`:

* `CPDF_Dictionary::WriteTo()` (every save) skips `/AP` and `/PDFIUM_HasGeneratedAP` of a dictionary marked this
  way (`CPDF_Dictionary::HasGeneratedAppearance()`); the key is now `pdfium::annotation::kPDFiumHasGeneratedAP`
  in `constants/annotation_common.h`. The in-memory dictionary is untouched: drawing keeps using the appearance.
* Generating an ink or text appearance changes `/Rect` (inflated by half the border width / a 20 x 20 icon):
  `CPDF_Annot` keeps the original `/Rect` in `/PDFIUM_RectBeforeGeneratedAP`, which a save writes as `/Rect`
  (and never under its own key). Removing the generated appearance (`FPDFAnnot_SetAP(NORMAL, nullptr)`,
  `FPDFAnnot_SetBorder()`, `FPDFAnnot_SetFontColor()`) restores it, so the next generation starts from the same
  dictionary instead of inflating an ink annotation again; `FPDFAnnot_SetRect()` drops it (the caller's `/Rect`
  is saved).
* Drawing a free text annotation no longer adds an `/AcroForm` to a document that has none, nor a fallback font
  to the document's `/DR`: the appearance refers to its font directly. `FPDFAnnotEmbedderTest.SetFontColor` relied on
  that side effect (it read the font colour of a free text without `/DA` from the `/AcroForm` that drawing had added);
  it now expects no colour until `FPDFAnnot_SetFontColor()` sets one.
* The reachable-object traversal of a full save (`GetObjectsWithReferences()`, 0003's `/Info` traversal) does not
  follow such an `/AP`, so the generated streams (and the fonts only they use) are not written either.
  `GetObjectsWithMultipleReferences()` (used by the content generator) still follows it.
* `FPDFAnnot_SetAP()` for the normal mode and `FPDFAnnot_AppendObject()` / `UpdateObject()` / `RemoveObject()`
  remove the mark: an appearance the caller set or changed is the annotation's own and is saved.
* New experimental API (`public/fpdf_annot.h`): `FPDFAnnot_GenerateAP()` generates the normal appearance from the
  dictionary now, the way drawing would, as the annotation's own appearance (saved);
  `FPDFAnnot_MarkGeneratedAP(annot, generated)` marks or unmarks the current appearance as generated.

A dictionary that already carries the mark when the document is loaded (written by an earlier PDFium-based save)
is treated the same way: its `/AP` is PDFium's regenerable cache and is not written. New embedder tests:
`FPDFAnnotEmbedderTest.SaveOmitsGeneratedAppearances`, `.GenerateAPIsSaved`, `.MarkGeneratedAPAndSetAP`,
`.SaveKeepsRectOfGeneratedInkAppearance`, `.DrawingFreeTextAddsNoAcroForm`,
`.SaveOmitsGeneratedAppearanceOfNewAnnotation`.
