# PDF to Markdown Wrapper (pdftomd.sh)

`pdftomd.sh`is a RAG workflow-friendly enhancement of Marker that converts a PDF into a single markdown file. It handles GPU and PyTorch configuration, document splitting and chunking, image BASE64 embedding, and consolidation of output.

## Why use the wrapper

- Splits large PDFs into chunks and runs Marker once on the chunk folder (avoids repeated model loads).
- Consolidates all chunk markdown into a single `.md` file.
- Optionally embeds images as Base64 (no external asset folders needed).
- Optional OCR pass via `ocr-pdf.sh` before conversion.
- Optional LLM helper via Marker `--use_llm`.
- Automatically uses GPU when available and installs CUDA-enabled torch when needed.
- Cleans up intermediate files and attempts to stop spawned processes on exit.

## Quick start

```shell
./pdftomd.sh /path/to/file.pdf
```

This produces `file.md` in the current directory. If you are not embedding images, it also produces a `file_bundle.tar.xz` archive with attachments.

## Options

- `-e, --embed`: Embed images as Base64 in the output markdown.
- `-v, --verbose`: Show verbose output.
- `-o, --ocr`: Run OCR via `ocr-pdf.sh` before conversion (produces `<filename>_OCR.md`).
- `-l, --llm`: Enable Marker LLM helper (`--use_llm`). Configure credentials per Marker (e.g., `GOOGLE_API_KEY`) and optionally set `LLM_SERVICE` in `pdftomd.conf`. For OpenAI-compatible endpoints set `LLM_SERVICE=marker.services.openai.OpenAIService` and supply `OPENAI_API_KEY`, `OPENAI_MODEL`, and `OPENAI_BASE_URL`.
- `-c, --cpu`: Force CPU processing (ignore GPU even if present).
- `-w, --workers N`: Number of worker processes for marker (default is 1).
- `-h, --help`: Show usage.

## Output behaviour

- Output is moved to the directory where the script is run.
- When `-o/--ocr` is used, the OCR pass writes `<filename>_OCR.pdf` in the current directory and the final markdown is named `<filename>_OCR.md`.
- When images are not embedded, the script creates an archive (`*_bundle.tar.xz`) with attachment directories and prints a reminder to extract it.
- At the end, the script prints total conversion time (HH:MM:SS) and time per page (seconds, 2 decimals).

## Requirements

- `qpdf` and `pxz`
- Marker installed in the configured `MARKER_DIRECTORY` with an active venv
- `ocr-pdf.sh` from the `OCR_PDF` repository (required for `-o/--ocr`)
- NVIDIA driver installed if you want GPU (torch will be auto-installed in the venv)

## Updating Marker without breaking `pdftomd.sh`

These steps keep the local `pdftomd.sh` customizations intact while pulling upstream Marker changes (assuming Marker has not changed significantly).

1. Fetch upstream changes:
   ```shell
   git fetch origin
   ```
2. Review local changes:
   ```shell
   git status -sb
   git diff
   ```
3. Merge upstream:
   ```shell
   git merge origin/main
   ```
4. Re-apply local edits if needed (focus on):
   - `pdftomd.sh` custom logic (GPU auto-install, single marker run, output moving).
   - `AGENTS.md` and README additions.
5. Verify that marker entrypoints are unchanged:
   ```shell
   rg -n "\\[tool.poetry.scripts\\]" pyproject.toml
   ```
   Ensure `marker` and `marker_single` still point to the same scripts.
6. Validate the wrapper script:
   ```shell
   bash -n pdftomd.sh
   ./pdftomd.sh -h
   ```
7. (Optional) Smoke test on a small PDF:
   ```shell
   ./pdftomd.sh -e path/to/small.pdf
   ```

## Troubleshooting

- CUDA OOM with multiple workers: reduce to `-w 1`.
- If a run is interrupted, stale marker processes may hold GPU memory. Check with `nvidia-smi`.
- If Marker reports conversion errors (e.g., CUDA OOM), the script exits non-zero even if marker itself returns 0.

# Appendix: About Marker

see https://github.com/datalab-to/marker for up-to-date writeup on Marker.  The following backgrounder may be out of date.

Marker converts documents to markdown, JSON, and HTML quickly and accurately.

- Converts PDF, image, PPTX, DOCX, XLSX, HTML, EPUB files in all languages
- Formats tables, forms, equations, inline math, links, references, and code blocks
- Extracts and saves images
- Removes headers/footers/other artifacts
- Extensible with your own formatting and logic
- Optionally boost accuracy with LLMs
- Works on GPU, CPU, or MPS

## Performance

<img src="data/images/overall.png" width="800px"/>

Marker benchmarks favorably compared to cloud services like Llamaparse and Mathpix, as well as other open source tools.

The above results are running single PDF pages serially.  Marker is significantly faster when running in batch mode, with a projected throughput of 122 pages/second on an H100 (.18 seconds per page across 22 processes).

See [below](#benchmarks) for detailed speed and accuracy benchmarks, and instructions on how to run your own benchmarks.

## Hybrid Mode

For the highest accuracy, pass the `--use_llm` flag to use an LLM alongside marker.  This will do things like merge tables across pages, handle inline math, format tables properly, and extract values from forms.  It can use any gemini or ollama model.  By default, it uses `gemini-2.0-flash`.  See [below](#llm-services) for details.

Here is a table benchmark comparing marker, gemini flash alone, and marker with use_llm:

<img src="data/images/table.png" width="400px"/>

As you can see, the use_llm mode offers higher accuracy than marker or gemini alone.

