# Third-party license review — incomplete

The project Apache-2.0 license applies only to original code that the copyright holder is entitled to license. It does not replace third-party licenses.

## Included font

Noto Sans SC Regular and Semibold are included in `app/assets/fonts/`. The associated license is retained as `app/assets/fonts/OFL-NotoSansSC.txt` and must accompany redistributed font files.

## PyMuPDF: release blocker requiring a decision or implementation change

The current backend dependency list includes PyMuPDF, and source files directly import it:

- `server/app/services/textbook_service.py`
- `server/app/providers/vision/cloud_vision.py`

Upstream offers AGPL and commercial licensing. Merely including an Apache-2.0 LICENSE does not remove the obligations of this dependency. Before an Apache-2.0-only application release, review replacement with a compatible PDF implementation or obtain an appropriate commercial license. Alternatively, distribution of a covered combined work must satisfy the applicable AGPL obligations; this would not be a simple Apache-2.0-only distribution.

Upstream license information: https://pymupdf.readthedocs.io/en/latest/about.html#license-and-copyright

## Remaining review

Python and Flutter direct/transitive dependencies, Qwen model licenses, generated platform components, and any redistributed FFmpeg build remain to be checked for the exact versions and distribution contents. No model weights or FFmpeg executables are included in this candidate source copy.

This document is a preparation note, not a completed license audit.
