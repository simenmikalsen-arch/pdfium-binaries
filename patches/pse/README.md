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

## 0002 - editing fidelity SPIKE (branch pse/editing-fidelity-spike only, not for release)

`0002-generatecontent-fidelity-spike.patch` (on top of 0001) is the prototype of option 2 of the PDF Studio Elite
module 19 feasibility spike (docs/EDITING-FIDELITY-SPIKE.md in that repository): it makes
`FPDFPage_GenerateContent()` keep more of what it regenerates - `Tc`/`Tw`, Type3 fonts (and a text object's
existing font resource name), DeviceCMYK colours, coloured patterns, shading objects (`sh`), inline images (written as
image XObjects), the miter limit, and the ExtGState resources an object was parsed with (soft masks, overprint). Two new
unit tests. The DLL says `-pse2spike` in its ProductVersion.
