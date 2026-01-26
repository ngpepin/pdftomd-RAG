# AGENTS

This file captures local project quirks and workflow notes for humans or coding agents.

## Project overview
- Core tool: Marker (Python) for converting documents to markdown/json/html.
- Convenience wrapper: `pdftomd.sh` in repo root for PDF-to-markdown with chunking, GPU handling, and output consolidation.
- Install helper: `install.sh` clones/updates Marker into `./marker`, sets up the venv, and ensures `pdftomd.conf` exists (copied from `pdftomd.conf.pub` if missing) with updated `MARKER_*` and `OCR_SCRIPT` paths. Use `--force` to overwrite `pdftomd.conf` from `pdftomd.conf.pub` before updating paths.
- Update helper: `update-marker.sh` pulls the latest Marker changes only; it does not touch config or the venv. It aborts if marker has local changes and runs lightweight entrypoint/wrapper checks.

## pdftomd.sh behavior
- Splits the input PDF into 100-page chunks with `qpdf` (10 pages when `-l/--llm` is enabled), processes all chunks in one `marker` run to avoid repeated model loads, then merges markdown.
- Output `.md` is moved to the directory where the script is run (not the PDF directory).
- Defaults and tuning knobs can be overridden via `pdftomd.conf`; see `pdftomd.conf.pub` for the full list of supported parameters.
- `-o/--ocr` runs the bundled `ocr-pdf/ocr-pdf.sh` first, creating `<filename>_OCR.pdf` in the current directory and producing `<filename>_OCR.md` (OCR script output is hidden unless `-v` is set).
- When `-o/--ocr` is not used, the wrapper uses a fast PyPDF2 pass to detect OCR text layers and strip them before Marker runs. Use `-s/--strip-ocr-layer` to force stripping or `--no-strip-ocr-layer` to disable it. Detection thresholds live in `pdftomd.sh` (`OCR_DETECT_INVISIBLE_RATIO`, `OCR_DETECT_MIN_PAGE_RATIO`, `OCR_DETECT_MIN_PAGES`).
- `-l/--llm` passes `--use_llm` to Marker; copy `pdftomd.conf.pub` to `pdftomd.conf` and set `LLM_SERVICE` if you need a non-default LLM service. For OpenAI-compatible endpoints use `marker.services.openai.OpenAIService` and set `OPENAI_API_KEY`, `OPENAI_MODEL`, and `OPENAI_BASE_URL`.
- `-l/--llm` enables Marker’s LLM helper during conversion; `--clean` is a separate wrapper post-process that aggressively fixes OCR errors and appends footnote-style correction notes (original saved as `.bak`). Use `--preclean-copy` to save the pre-clean markdown as `<name>_preclean.md`. Both can be used together. Configure chunking with `MAX_TOKENS` in `pdftomd.conf`.
- When `-l/--llm` is enabled, the wrapper watches for "Rate limit error" in Marker output and will abort/retry once without `--use_llm` to avoid repeated timeouts. This depends on Marker’s log message and may be brittle if it changes; if the fallback is constantly triggered, consider disabling `-l` to avoid restart overhead.
- Marker’s LLM helper does not enforce an input token cap; it sends the full prompt and relies on the backend model for limits. Only output token limits are configurable via service settings.
- Use `remove-OCR-correction.sh` to remove the `OCR Corrections Notes` section and its footnote references from a `--clean` output (creates a `.bak` by default; `-o` writes to a new file).
- If images are not embedded, it bundles attachments into `<name>_bundle.tar.xz` and instructs the user to extract it.
- Default is GPU if available; use `-c/--cpu` to force CPU.
- Default `MARKER_WORKERS=1`; override with `-w/--workers N`.
- Output is quiet by default; use `-v/--verbose` for full logs.
- Prints total time (`HH:MM:SS`) and seconds per page (2 decimals) at the end.

## GPU and torch install
- The script checks for an NVIDIA GPU and installs CUDA-enabled torch automatically when needed.
- CUDA version is read from `nvidia-smi`; CUDA >= 12 maps to `cu121`, CUDA 11 maps to `cu118`.
- If `torch.cuda.is_available()` is still false after install, the script fails.

## Cleanup and interruptions
- Temp chunk directories and merge staging directories are cleaned on exit or interrupt.
- The script attempts to terminate any spawned marker processes on exit.

## Gotchas
- Running multiple marker processes can trigger CUDA OOM; use `-w 1` if VRAM is tight.
- Marker can print CUDA IPC warnings; these are usually non-fatal.
- If a prior run is interrupted, lingering marker processes can hold GPU memory; `nvidia-smi` should be clean before reruns.
- `MARKER_DIRECTORY` and `MARKER_VENV` must match the local install; update them if you move the repo or venv.

## Quick commands
- Validate script syntax: `bash -n pdftomd.sh`
- Run with verbose logs: `./pdftomd.sh -ve /path/to/file.pdf`
- Strip OCR correction notes: `./remove-OCR-correction.sh /path/to/file.md`
