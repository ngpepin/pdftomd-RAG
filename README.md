# PDF to Markdown Wrapper (pdftomd.sh)

`pdftomd.sh`is a RAG workflow-friendly enhancement of Marker that converts a PDF into a single markdown file. It handles GPU and PyTorch configuration, document splitting and chunking, image BASE64 embedding, and consolidation of output.

## Why use the wrapper

- Splits large PDFs into chunks and runs Marker once on the chunk folder (avoids repeated model loads).
- Consolidates all chunk markdown into a single `.md` file.
- Optionally embeds images as Base64 (no external asset folders needed).
- Optional text-only output that strips image links from the final markdown.
- Optional OCR pass via bundled `ocr-pdf/ocr-pdf.sh` before conversion.
- Optional LLM helper via Marker `--use_llm`.
- Automatically uses GPU when available and installs CUDA-enabled torch when needed.
- Cleans up intermediate files and attempts to stop spawned processes on exit.

## Using `pdftomd.sh` in a RAG pipeline

Run `pdftomd.sh` as the ingestion step that turns source PDFs into markdown your splitter and embedder can consume. A typical flow is:

1. (Optional) OCR the PDF with `-o` for scanned documents.
2. Convert to a single consolidated markdown file (and optionally embed images with `-e`).
3. Feed the markdown into your chunker, add metadata (file name, page ranges), then index.

Example ingestion command:

```shell
./pdftomd.sh -e -o /path/to/source.pdf
```

Benefits over calling Marker directly:

- Handles large documents via chunking while keeping a single output file, which simplifies downstream chunking and metadata.
- Avoids repeated model loads by running Marker once across all chunks, improving throughput for big PDFs.
- Keeps assets self-contained with Base64 embedding or a single attachment bundle, reducing file management for ingestion jobs.
- Provides operational glue (GPU detection, torch install, cleanup on exit, consistent output location) so pipeline orchestration is simpler.

## Quick start

```shell
./pdftomd.sh /path/to/file.pdf
```

You can also pass a directory to process all PDFs inside it sequentially:

```shell
./pdftomd.sh /path/to/folder
```

Add `-r/--recurse` to include PDFs in subdirectories:

```shell
./pdftomd.sh -r /path/to/folder
```

This produces `file.md` in the current directory. If you are not embedding images, it also produces a `file_bundle.tar.xz` archive with attachments.

## Options

- `-e, --embed`: Embed images as Base64 in the output markdown.
- `-t, --text`: Remove image links from the final markdown (ignores `--embed`).
- `-v, --verbose`: Show verbose output.
- `-o, --ocr`: Run OCR via bundled `ocr-pdf/ocr-pdf.sh` before conversion (produces `<filename>_OCR.md`).
- `-l, --llm`: Enable Marker LLM helper (`--use_llm`). Copy `pdftomd.conf.pub` to `pdftomd.conf` and configure credentials (e.g., `GOOGLE_API_KEY`), then optionally set `LLM_SERVICE`. For OpenAI-compatible endpoints set `LLM_SERVICE=marker.services.openai.OpenAIService` and supply `OPENAI_API_KEY`, `OPENAI_MODEL`, and `OPENAI_BASE_URL`.
- `-c, --cpu`: Force CPU processing (ignore GPU even if present).
- `-w, --workers N`: Number of worker processes for marker (default is 1).
- `-h, --help`: Show usage.
- `--clean`: Post-process the final markdown with the configured LLM to improve readability and fix OCR errors. Creates a `.bak` of the original markdown and appends footnotes with original text.

## Output behaviour

- Output is moved to the directory where the script is run.
- When `-o/--ocr` is used, the OCR pass writes `<filename>_OCR.pdf` in the current directory and the final markdown is named `<filename>_OCR.md`.
- When images are not embedded, the script creates an archive (`*_bundle.tar.xz`) with attachment directories and prints a reminder to extract it.
- When `-t/--text` is used, image links are removed from the final markdown and no attachment bundle is created.
- At the end, the script prints total conversion time (HH:MM:SS) and time per page (seconds, 2 decimals).

## Configuration

Copy `pdftomd.conf.pub` to `pdftomd.conf`, edit the values for your environment, and keep `pdftomd.conf` out of version control.

`OCR_OPTIONS` can be set as a Bash array for clarity, for example:

```bash
OCR_OPTIONS=(-a -q)
```

Common flags:
- `-a`: autorotate pages
- `-q`: quiet output

`MAX_TOKENS` controls the chunking size for `--clean`. Set it to the approximate context window of your LLM.

## OCR note

Marker already performs OCR on images during conversion, so `-o/--ocr` is optional. The bundled `ocr-pdf/ocr-pdf.sh` is a separate pre-processing pipeline that uses OCRmyPDF + Tesseract (optionally via the EasyOCR plugin for GPU) and adds steps like blank-page detection/removal, deskewing, autorotation, and size optimization before Marker runs. Use it if you want to experiment with alternate OCR engines/languages or extra pre-processing on scanned PDFs.

When `-o/--ocr` is enabled, the wrapper passes `--disable_ocr` to Marker so it does not override the pre-processed OCR layer. When `-o/--ocr` is not used, the wrapper forces Marker OCR and strips existing OCR text layers to prefer Marker’s own OCR.

## Requirements

- `qpdf` and `pxz`
- Marker installed in the configured `MARKER_DIRECTORY` with an active venv
- Bundled `ocr-pdf/ocr-pdf.sh` (required for `-o/--ocr`)
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

Marker converts documents to markdown, JSON, and HTML with a focus on speed and layout fidelity.

- Supports PDFs plus common office and web formats (PPTX, DOCX, XLSX, HTML, EPUB, images)
- Preserves structure for tables, forms, equations, inline math, links, references, and code blocks
- Extracts images and reduces layout artifacts like headers and footers
- Extensible with custom formatting and post-processing logic
- Optional LLM-assisted mode for higher accuracy on complex layouts
- Runs on GPU, CPU, or MPS with batch-friendly processing

## Performance

Marker is designed for high throughput and strong accuracy. Reported benchmarks show it outperforming many hosted services and other open source tools.

Batch runs are substantially faster than single-page serial processing, with a reported peak throughput around 122 pages per second on an H100 (about 0.18 seconds per page across 22 processes).

## Hybrid Mode

For the highest accuracy, pass the `--use_llm` flag to combine Marker with an LLM. This improves table structure, multi-page table merging, inline math, and form value extraction.
