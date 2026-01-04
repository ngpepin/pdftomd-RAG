# AGENTS

This file captures local project quirks and workflow notes for humans or coding agents.

## Project overview
- Core tool: Marker (Python) for converting documents to markdown/json/html.
- Convenience wrapper: `pdftomd.sh` in repo root for PDF-to-markdown with chunking, GPU handling, and output consolidation.

## pdftomd.sh behavior
- Splits the input PDF into 100-page chunks with `qpdf`, processes all chunks in one `marker` run to avoid repeated model loads, then merges markdown.
- Output `.md` is moved to the directory where the script is run (not the PDF directory).
- If images are not embedded, it bundles attachments into `<name>_bundle.tar.xz` and instructs the user to extract it.
- Default is GPU if available; use `-c/--cpu` to force CPU.
- Default `MARKER_WORKERS=2`; override with `-w/--workers N`.
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
