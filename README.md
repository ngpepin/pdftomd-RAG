# PDF to Markdown Wrapper (pdftomd.sh)

`pdftomd.sh`is a RAG workflow-friendly enhancement of Marker that converts a PDF into a single markdown file. It handles GPU and PyTorch configuration, document splitting and chunking, image BASE64 embedding, LLM post-processing and cleanup, and consolidation of output

For more on Marker, see https://github.com/datalab-to/marker

## Why use the wrapper

- Splits large PDFs into chunks (100 pages by default, 25 pages when `--clean` is enabled, 10 pages when `-l/--llm` is enabled) and runs Marker once on the chunk folder (avoids repeated model loads).
- Consolidates all chunk markdown into a single `.md` file.
- Optionally embeds images as Base64 (no external asset folders needed).
- Optional text-only output that strips image links from the final markdown.
- Optional OCR pass via bundled `ocr-pdf/ocr-pdf.sh` before conversion (advanced PDF OCR pipeline script, GPU-aware via EasyOCR plugin)
- Optional LLM helper via a built-in Marker `--use_llm`.
- Automatically uses GPU when available and installs CUDA-enabled torch when needed.
- Cleans up intermediate files and attempts to stop spawned processes on exit.
- Optional supplemental LLM post-processing step with `--clean`.

The overall result can be a much cleaner more streamlined end product more suited to RAG pipeline ingestion.

## Using `pdftomd.sh` in a RAG pipeline

Run `pdftomd.sh` as the ingestion step that turns source PDFs into markdown your splitter and embedder can consume. A typical flow is:

1. (Optional) OCR the PDF with `-o` for scanned documents or rely on Marker's built-in OCR.
2. Convert to a single consolidated markdown file (and optionally embed images with `-e` or ignore images altogether with `-t`).
3. Feed the markdown into your chunker, add metadata (file name, page ranges), then index.

Example ingestion command:

```shell
./pdftomd.sh -e -o /path/to/source.pdf
```

Benefits over calling Marker directly:

- Handles large documents via chunking while keeping a single output file, which simplifies downstream chunking and metadata.
- Avoids repeated model loads by running Marker once across all chunks, improving throughput for big PDFs.
- Keeps assets self-contained with Base64 embedding or a single attachment bundle, reducing file management for ingestion jobs.
- Adds a wrapper-managed LLM cleanup pass (`--clean`) with explicit chunking via `MAX_TOKENS`, which can handle prompt-size limits and timeouts more predictably than Marker’s built-in LLM helper.
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

- `-c, --clean`: Post-process the final markdown with the configured LLM to improve readability and fix OCR errors. Creates a `.bak` of the original markdown and appends footnotes with original text. This is a wrapper-level cleanup pass and can be used together with `-l`. Note that it can result in longer conversion times.
- `--cpu`: Force CPU processing (ignore GPU even if present).
- `-e, --embed`: Embed images as Base64 in the output markdown.
- `-h, --help`: Show usage.
- `-l, --llm`: Enable Marker LLM helper (`--use_llm`) during conversion. Copy `pdftomd.conf.pub` to `pdftomd.conf` and configure credentials (e.g., `GOOGLE_API_KEY`), then optionally set `LLM_SERVICE`. For OpenAI-compatible endpoints set `LLM_SERVICE=marker.services.openai.OpenAIService` and supply `OPENAI_API_KEY`, `OPENAI_MODEL`, and `OPENAI_BASE_URL`. When `-l` is enabled, the wrapper uses smaller PDF chunks (10 pages instead of 100; this overrides the 25-page `--clean` chunk size) to reduce prompt sizes, and it will abort/retry once without `--use_llm` if it detects a "Rate limit error" in Marker output.
- `-n, --no-strip-ocr-layer`: Disable OCR text layer stripping when `-o` is not used.
- `-o, --ocr`: Run OCR via bundled `ocr-pdf/ocr-pdf.sh` before conversion (produces `<filename>_OCR.md`).
- `--preclean-copy`: Save a copy of the merged markdown (before `--clean`) as `<name>_preclean.md`.
- `-r, --recurse`: Recursively process PDFs when a directory is provided.
- `-s, --strip-ocr-layer`: Always strip OCR text layer when `-o` is not used (skips detection).
- `-t, --text`: Remove image links from the final markdown (ignores `--embed`).
- `-v, --verbose`: Show verbose output.
- `-w, --workers N`: Number of worker processes for marker (default is 1).

## Output behaviour

- Output is moved to the directory where the script is run.
- When `-o/--ocr` is used, the OCR pass writes `<filename>_OCR.pdf` in the current directory and the final markdown is named `<filename>_OCR.md`.
- When images are not embedded, the script creates an archive (`*_bundle.tar.xz`) with attachment directories and prints a reminder to extract it.
- When `-t/--text` is used, image links are removed from the final markdown and no attachment bundle is created.
- At the end, the script prints total conversion time (HH:MM:SS) and time per page (seconds, 2 decimals).

## Configuration

Copy `pdftomd.conf.pub` to `pdftomd.conf`, edit the values for your environment, and keep `pdftomd.conf` out of version control.
All tweakable defaults (paths, OCR stripping thresholds, LLM settings, etc.) can be overridden in `pdftomd.conf`; `pdftomd.conf.pub` contains the full list of supported parameters with defaults.

`OCR_OPTIONS` can be set as a Bash array for clarity, for example:

```bash
OCR_OPTIONS=(-a -q)
```

Common flags:
- `-a`: autorotate pages
- `-q`: quiet output

`MAX_TOKENS` controls the chunking size for `--clean`. Set it to the approximate context window of your LLM.

## OCR note

Marker already performs OCR on images during conversion, so `-o/--ocr` is optional. The bundled `ocr-pdf/ocr-pdf.sh` is a separate pre-processing pipeline that uses OCRmyPDF + Tesseract (optionally via the EasyOCR plugin for GPU) and adds steps like blank-page detection/removal, deskewing, autorotation, and size optimization before Marker runs. Use it if you want to experiment with alternate OCR engines/languages or extra pre-processing on scanned PDFs.  In general, Marker's built-in OCR does a better job, however. 

When `-o/--ocr` is enabled, the wrapper passes `--disable_ocr` to Marker so it does not override the pre-processed OCR layer. When `-o/--ocr` is not used, the wrapper forces Marker OCR and strips existing OCR text layers to prefer Marker’s own OCR.

When `-o/--ocr` is not used, the wrapper performs a fast PyPDF2 pass to **detect** OCR text layers and, if detected, physically strips text objects from the input PDF before running Marker. This helps prevent stale OCR layers from being reused. The pass uses the Marker venv and will install PyPDF2 there if missing.

Use `-s/--strip-ocr-layer` to force stripping without detection, or `-n/--no-strip-ocr-layer` to disable the stripping step. Detection thresholds are configurable in `pdftomd.sh` via `OCR_DETECT_INVISIBLE_RATIO`, `OCR_DETECT_MIN_PAGE_RATIO`, and `OCR_DETECT_MIN_PAGES`.

## LLM note

`-l/--llm` tells Marker to use its LLM helper during conversion. Marker does not enforce an input token cap for this helper; it sends the full prompt and relies on the backend model’s limits. `--clean` is a separate, wrapper-driven post-processing step that is more aggressive about fixing OCR errors and adds footnotes for traceability; it also chunk-splits the markdown based on `MAX_TOKENS` in `pdftomd.conf`.

When `-l` is enabled, the wrapper monitors Marker output for "Rate limit error" and will abort and then retry calling Marker without the `--use_llm` option to see if that works.  This stops Marker from timing out repeatedly and, after quite some time has elapsed, ultimately erroring out. This detection is string-based and could be brittle if Marker’s log messaging changes.

If the fallback keeps triggering (and time is being lost restarting the conversion), consider dropping `-l` while keeping `--clean`: the wrapper’s cleanup pass handles chunking more predictably, and still delivers improved readability after conversion.

## Removing OCR Corrections Notes

If you want to strip the `--clean` footnotes and the `OCR Corrections Notes` section, use the bundled helper:

```shell
./remove-OCR-correction.sh /path/to/file.md
```

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

https://github.com/datalab-to/marker

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
