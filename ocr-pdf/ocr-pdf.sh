#!/usr/bin/env bash
# shellcheck disable=SC2016
: '
ocr-pdf.sh — Advanced PDF OCR Pipeline Script (GPU-aware via EasyOCR plugin)

DESCRIPTION:
  Processes PDF files to produce searchable PDFs using OCR, with optional page reversal,
  blank page detection/removal, deskewing, autorotation, and robust file size optimization.

GPU NOTES:
  - Upstream ocrmypdf/tesseract does NOT have a --use-cuda flag.
  - GPU acceleration is achieved via the OCRmyPDF-EasyOCR plugin + PyTorch CUDA in the venv.
  - Use --no-gpu to force CPU mode regardless of GPU presence.
  - In GPU mode, default worker count is -j 8 (tunable via OCR_GPU_JOBS).

VENV:
  - The script activates a Python venv before running, and deactivates it on exit or Ctrl-C.
  - Default venv path: ~/venvs/ocr-gpu
  - Override with env var OCR_VENV=/path/to/venv

USAGE:
  ./ocr-pdf.sh [options] input.pdf


OPTIONS:
  -r, --reverse        Reverse page order before processing.
  -l LANGS             Specify OCR languages (default: eng+fra+spa+lat).
  -a, --autorotate     Enable autorotation of pages.
  -s, --shrink         Force aggressive compression.
  -q, --quiet          Suppress non-error output.
  (Short options -a, -q, -s can be stacked, e.g. -asq)
  --no-deskew          Disable deskewing.
  --debug              Enable debug output.
  --no-color           Disable colored output.
  --keep-temp          Retain temporary files after processing.
  --no-gpu             Force CPU mode (ignore GPU even if present).

ENVIRONMENT VARIABLES (override defaults):
  OCR_VENV             Path to venv to activate (default: $HOME/venvs/ocr-gpu).
  BLANK_THRESHOLD      Mean value threshold for blank page detection (default: 0.995).
  BLANK_DETECT_DPI     DPI for blank page detection rendering (default: 150).
  OCR_LANGS_DEFAULT    Default OCR languages (default: eng+fra+spa+lat).
  OCR_OPTIMIZE_LEVEL   Optimization level for OCR output (0..3, default: 1).
  SIZE_INFLATE_FACTOR  Output/input size ratio to trigger aggressive compression (default: 1.75).
  JPEG_QUALITY_LOSSY   JPEG quality for lossy compression (default: 85).
  PNG_QUALITY_LOSSY    PNG quality for lossy compression (default: 75).
  GS_PROFILE           Ghostscript profile for fallback compression (default: /ebook).
  OCR_GPU_JOBS         In GPU mode, default worker count (default: 8).
  OCR_CPU_JOBS         In CPU mode, default worker count (default: nproc).

DEPENDENCIES (system):
  - qpdf
  - poppler-utils (pdftoppm)
  - imagemagick (identify)
  - tesseract-ocr
  - ghostscript (optional but recommended)
  - (venv) ocrmypdf
  - (venv) OCRmyPDF-EasyOCR plugin (recommended for GPU)

OUTPUT:
  Produces <input>_OCR.pdf in the same directory as the input.
'

set -euo pipefail

###################################
### Tunables (overridable via env)
BLANK_THRESHOLD="${BLANK_THRESHOLD:-0.995}"
BLANK_DETECT_DPI="${BLANK_DETECT_DPI:-150}"
OCR_LANGS_DEFAULT="${OCR_LANGS_DEFAULT:-eng+fra+spa+lat}"
OCR_OPTIMIZE_LEVEL="${OCR_OPTIMIZE_LEVEL:-1}"
SIZE_INFLATE_FACTOR="${SIZE_INFLATE_FACTOR:-1.75}"
JPEG_QUALITY_LOSSY="${JPEG_QUALITY_LOSSY:-85}"
PNG_QUALITY_LOSSY="${PNG_QUALITY_LOSSY:-75}"
GS_PROFILE="${GS_PROFILE:-/ebook}"
OCR_GPU_JOBS="${OCR_GPU_JOBS:-8}"
OCR_CPU_JOBS="${OCR_CPU_JOBS:-}"

### Venv
VENV_PATH="${OCR_VENV:-$HOME/venvs/ocr-gpu}"
VENV_ACTIVATED=0
OCRmypdf_BIN=""   # set after venv activation

### Logging / UX
QUIET=0; DEBUG=0; COLOR=1; KEEP_TEMP=0
REVERSE=0; AUTOROTATE=0; DESKEW=1; FORCE_SHRINK=0
FORCE_CPU=0

if [[ ! -t 1 || -n "${NO_COLOR:-}" ]]; then COLOR=0; fi
c_reset='' c_dim='' c_green='' c_yellow='' c_red='' c_blue=''
if [[ $COLOR -eq 1 ]]; then
  c_reset=$'\033[0m'; c_dim=$'\033[2m'; c_green=$'\033[32m'
  c_yellow=$'\033[33m'; c_red=$'\033[31m'; c_blue=$'\033[34m'
fi
ts(){ date +"%Y-%m-%d %H:%M:%S"; }
log(){  [[ $QUIET -eq 1 ]] && return; echo -e "${c_dim}[$(ts)]${c_reset} $*"; }
info(){ [[ $QUIET -eq 1 ]] && return; echo -e "${c_dim}[$(ts)]${c_reset} ${c_blue}INFO${c_reset}  $*"; }
ok(){   [[ $QUIET -eq 1 ]] && return; echo -e "${c_dim}[$(ts)]${c_reset} ${c_green}OK${c_reset}    $*"; }
warn(){ echo -e "${c_dim}[$(ts)]${c_reset} ${c_yellow}WARN${c_reset}  $*" >&2; }
err(){  echo -e "${c_dim}[$(ts)]${c_reset} ${c_red}ERROR${c_reset} $*" >&2; }
die(){ err "$*"; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }
filesize(){ stat --format=%s "$1"; }

TOTAL_T0="$(date +%s)"

###################################
# CUDA detection + optional force CPU
CUDA_AVAILABLE=0
GPU_MODE="CPU"

detect_cuda(){
  if have nvidia-smi && nvidia-smi -L >/dev/null 2>&1; then
    CUDA_AVAILABLE=1; return
  fi
  if have nvcc && nvcc --version >/dev/null 2>&1; then
    CUDA_AVAILABLE=1; return
  fi
  if [[ -e /proc/driver/nvidia/version ]]; then
    CUDA_AVAILABLE=1; return
  fi
}

###################################
# Venv activation / cleanup
activate_venv(){
  [[ -d "$VENV_PATH" ]] || die "Venv not found: $VENV_PATH (set OCR_VENV to override)"
  [[ -f "$VENV_PATH/bin/activate" ]] || die "Venv activate script not found: $VENV_PATH/bin/activate"
  # shellcheck disable=SC1090
  source "$VENV_PATH/bin/activate"
  VENV_ACTIVATED=1

  OCRmypdf_BIN="$VENV_PATH/bin/ocrmypdf"
  [[ -x "$OCRmypdf_BIN" ]] || die "ocrmypdf not found/executable in venv: $OCRmypdf_BIN (install: pip install ocrmypdf)"
}

deactivate_venv(){
  if [[ $VENV_ACTIVATED -eq 1 ]]; then
    deactivate || true
    VENV_ACTIVATED=0
  fi
}

WORKDIR=""
cleanup(){
  local rc=$?
  if [[ -n "${WORKDIR:-}" && -d "${WORKDIR:-}" ]]; then
    if [[ $KEEP_TEMP -eq 1 ]]; then
      warn "Keeping temp: $WORKDIR"
    else
      rm -rf "$WORKDIR" || true
    fi
  fi
  deactivate_venv

  local total_s=$(( $(date +%s) - TOTAL_T0 ))
  if [[ $rc -eq 0 ]]; then
    ok "Total end-to-end time: ${total_s}s"
  else
    warn "Total end-to-end time (before failure): ${total_s}s"
  fi
  exit $rc
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

###################################
### Parse CLI

if [[ $# -lt 1 ]]; then
  cat <<EOF
Usage: $(basename "$0") [-r|--reverse] [-l LANGS] [-a] [-s] [-q] [--autorotate] [--no-deskew] [--shrink]
                         [--quiet] [--debug] [--no-color] [--keep-temp] [--no-gpu] input.pdf
  Short options -a, -q, -s can be stacked (e.g. -asq)
EOF
  exit 1
fi


OCR_LANGS="$OCR_LANGS_DEFAULT"
INPUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--reverse)
      REVERSE=1; shift ;;
    -l)
      shift; OCR_LANGS="${1:-$OCR_LANGS_DEFAULT}"; shift ;;
    # Stackable short options: -a, -q, -s (can be combined, e.g. -asq)
    -[aqs]*)
      optstr="${1#-}"
      for ((i=0; i<${#optstr}; i++)); do
        c="${optstr:$i:1}"
        case "$c" in
          a) AUTOROTATE=1 ;;
          q) QUIET=1 ;;
          s) FORCE_SHRINK=1 ;;
          *) die "Unknown short option: -$c" ;;
        esac
      done
      shift ;;
    --autorotate)
      AUTOROTATE=1; shift ;;
    --no-deskew)
      DESKEW=0; shift ;;
    --shrink)
      FORCE_SHRINK=1; shift ;;
    --quiet)
      QUIET=1; shift ;;
    --debug)
      DEBUG=1; shift ;;
    --no-color)
      COLOR=0; c_reset=''; c_dim=''; c_green=''; c_yellow=''; c_red=''; c_blue=''; shift ;;
    --keep-temp)
      KEEP_TEMP=1; shift ;;
    --no-gpu)
      FORCE_CPU=1; shift ;;
    --)
      shift; break ;;
    -*)
      die "Unknown option: $1" ;;
    *)
      INPUT="$1"; shift ;;
  esac
done

[[ -n "${INPUT:-}" ]] || die "No input PDF provided."
[[ -r "$INPUT" ]] || die "Cannot read input: $INPUT"

base="${INPUT%.*}"
OUTPUT="${base}_OCR.pdf"

###################################
# Activate venv early (and pin ocrmypdf binary)
activate_venv

###################################
# External tool checks (system)
for t in qpdf pdftoppm identify tesseract; do
  have "$t" || die "Missing '$t'. Install: sudo apt-get install -y qpdf poppler-utils imagemagick tesseract-ocr"
done
have gs || warn "Optional 'gs' (ghostscript) not found; size fallback step will be unavailable."

# Detect EasyOCR plugin availability inside venv python
HAVE_EASYOCR_PLUGIN=0
python - <<'PY' >/dev/null 2>&1 && HAVE_EASYOCR_PLUGIN=1 || true
import ocrmypdf_easyocr  # noqa: F401
PY

detect_cuda
if [[ $FORCE_CPU -eq 1 ]]; then
  GPU_MODE="CPU (forced by --no-gpu)"
elif [[ $CUDA_AVAILABLE -eq 1 ]]; then
  GPU_MODE="CUDA"
else
  GPU_MODE="CPU"
fi

# If forcing CPU, hide GPU from torch/easyocr to ensure CPU path even if CUDA exists
if [[ $FORCE_CPU -eq 1 ]]; then
  export CUDA_VISIBLE_DEVICES=""
fi

###################################
# Temp workspace
WORKDIR="$(mktemp -d)"

###################################
# Header
log  "============================================================"
log  " PDF Searchable Pipeline"
log  " Input      : $INPUT"
log  " Output     : $OUTPUT"
log  " Reverse    : $([[ $REVERSE -eq 1 ]] && echo Yes || echo No)"
log  " Blank thr. : $BLANK_THRESHOLD (DPI=$BLANK_DETECT_DPI)"
log  " OCR langs  : $OCR_LANGS"
log  " Optimize   : $OCR_OPTIMIZE_LEVEL"
log  " GPU        : $GPU_MODE"
log  " EasyOCR    : $([[ $HAVE_EASYOCR_PLUGIN -eq 1 ]] && echo "Installed (GPU-capable)" || echo "Not installed")"
log  " Autorotate : $([[ $AUTOROTATE -eq 1 ]] && echo Yes || echo No)"
log  " Deskew     : $([[ $DESKEW -eq 1 ]] && echo Yes || echo No)"
log  " Shrink     : $([[ $FORCE_SHRINK -eq 1 ]] && echo Aggressive || echo Auto)"
log  " Venv       : $VENV_PATH"
log  " ocrmypdf   : $("$OCRmypdf_BIN" --version | head -n 1)"
log  "============================================================"

CURRENT="$INPUT"

###################################
### Step 1: Reverse (optional)
if [[ $REVERSE -eq 1 ]]; then
  info "Step 1/3: Reversing page order with qpdf…"
  _t0=$SECONDS
  REV_OUT="$WORKDIR/reversed.pdf"
  qpdf --empty --pages "$CURRENT" z-1 -- "$REV_OUT"
  ok "Reversed pages -> $REV_OUT ($((SECONDS-_t0))s)"
  CURRENT="$REV_OUT"
else
  info "Step 1/3: Reverse step skipped."
fi

###################################
### Step 2: Blank-page detection & removal
info "Step 2/3: Detecting and removing blank pages (threshold=$BLANK_THRESHOLD)…"
_t0=$SECONDS

PAGECOUNT="$(qpdf --show-npages "$CURRENT" 2>/dev/null || echo 0)"
[[ "$PAGECOUNT" =~ ^[0-9]+$ ]] || die "Could not determine page count."
log "Total pages: $PAGECOUNT"

log "Rendering pages at ${BLANK_DETECT_DPI} DPI for scoring…"
pdftoppm -gray -r "$BLANK_DETECT_DPI" "$CURRENT" "$WORKDIR/page" >/dev/null

page_img(){
  local i="$1" c
  for c in "" "0" "00" "000"; do [[ -f "$WORKDIR/page-${c}${i}.pgm" ]] && { echo "$WORKDIR/page-${c}${i}.pgm"; return 0; }; done
  for c in "" "0" "00" "000"; do [[ -f "$WORKDIR/page-${c}${i}.ppm" ]] && { echo "$WORKDIR/page-${c}${i}.ppm"; return 0; }; done
  return 1
}

keep_pages=(); removed_pages=()
scores_file="$WORKDIR/blank_scores.tsv"
echo -e "page\tmean" > "$scores_file"

for ((i=1;i<=PAGECOUNT;i++)); do
  img="$(page_img "$i" || true)"
  if [[ -z "$img" ]]; then
    warn "Page $i: render missing; keeping to be safe."
    keep_pages+=("$i"); echo -e "$i\tNA" >> "$scores_file"; continue
  fi
  mean="$(identify -format "%[fx:mean]" "$img" 2>/dev/null || true)"
  if [[ -z "$mean" ]]; then
    warn "Page $i: identify failed; keeping."
    keep_pages+=("$i"); echo -e "$i\tFAIL" >> "$scores_file"; continue
  fi
  if awk -v m="$mean" -v t="$BLANK_THRESHOLD" 'BEGIN{exit !(m < t)}'; then
    keep_pages+=("$i"); [[ $DEBUG -eq 1 ]] && log "Page $i score=$mean (keep)"
  else
    removed_pages+=("$i"); [[ $DEBUG -eq 1 ]] && log "Page $i score=$mean (blank)"
  fi
  echo -e "$i\t$mean" >> "$scores_file"
done

if [[ ${#keep_pages[@]} -eq 0 ]]; then
  warn "All pages appear blank; retaining page 1 as a safeguard."
  keep_pages=(1)
fi

if [[ ${#removed_pages[@]} -gt 0 ]]; then
  log "Removing ${#removed_pages[@]} blank page(s): ${removed_pages[*]}"
  NONBLANK_PDF="$WORKDIR/nonblank.pdf"
  keep_csv="$(IFS=,; echo "${keep_pages[*]}")"
  qpdf --empty --pages "$CURRENT" "$keep_csv" -- "$NONBLANK_PDF"
  CURRENT="$NONBLANK_PDF"
else
  log "No blank pages removed."
fi

ok "Blank-page pass complete in $((SECONDS-_t0))s."
[[ $DEBUG -eq 1 ]] && info "Per-page scores saved: $scores_file"

###################################
### Step 3: Clean, deskew, OCR (+ size guard)
info "Step 3/3: Clean + OCR with ocrmypdf…"
_t0=$SECONDS
OCR_TMP="$WORKDIR/ocr_out.pdf"

CPU_CORES="$(command -v nproc >/dev/null 2>&1 && nproc || echo 2)"
[[ -z "$CPU_CORES" || "$CPU_CORES" -lt 1 ]] && CPU_CORES=1

if [[ -n "$OCR_CPU_JOBS" ]]; then
  CPU_JOBS="$OCR_CPU_JOBS"
else
  CPU_JOBS="$CPU_CORES"
fi

if [[ $GPU_MODE == "CUDA" ]]; then
  JOBS="$OCR_GPU_JOBS"
else
  JOBS="$CPU_JOBS"
fi

OCR_VERBOSE=(); [[ $QUIET -eq 0 ]] && OCR_VERBOSE=(-v 1)

# IMPORTANT:
# - Do NOT pass -s (it is --skip-text) when using --force-ocr.
# - Keep -c (clean) and optionally -d (deskew).
OCR_FLAGS=(
  --output-type pdf
  -O "$OCR_OPTIMIZE_LEVEL"
  -j "$JOBS"
  --tesseract-timeout 120
  -l "$OCR_LANGS"
  -c
)

# Your desired behavior: always OCR regardless of Tagged PDF / existing text
OCR_FLAGS+=( --force-ocr )

[[ $DESKEW -eq 1 ]] && OCR_FLAGS+=( -d )
[[ $AUTOROTATE -eq 1 ]] && OCR_FLAGS+=( -r )

# If EasyOCR plugin is present, use sandwich renderer (required for plugin)
if [[ $HAVE_EASYOCR_PLUGIN -eq 1 ]]; then
  OCR_FLAGS+=( --pdf-renderer=sandwich )
fi

OLD_PATH="$PATH"; export PATH="/usr/local/bin:/usr/bin:/bin"
"$OCRmypdf_BIN" "${OCR_FLAGS[@]}" "${OCR_VERBOSE[@]}" "$CURRENT" "$OCR_TMP"
export PATH="$OLD_PATH"
ok "OCR pass complete in $((SECONDS-_t0))s."

# Size guard — compare against the post-blank-removal input ($CURRENT)
INPUT_BYTES="$(filesize "$CURRENT")"
OUTPUT_BYTES="$(filesize "$OCR_TMP")"
ratio=""
if [[ "$INPUT_BYTES" -gt 0 ]]; then
  ratio=$(awk -v o="$OUTPUT_BYTES" -v i="$INPUT_BYTES" 'BEGIN{printf "%.3f", o/i}')
fi

SHRINK_NOW=0
if [[ $FORCE_SHRINK -eq 1 ]]; then
  SHRINK_NOW=1
elif [[ -n "$ratio" ]]; then
  if awk -v r="$ratio" -v f="$SIZE_INFLATE_FACTOR" 'BEGIN{exit !(r>f)}'; then
    SHRINK_NOW=1
  fi
fi

if [[ $SHRINK_NOW -eq 1 ]]; then
  warn "Output is $(printf "%.2f" "${ratio:-1}")× input (threshold ${SIZE_INFLATE_FACTOR}×). Trying aggressive compression…"
  _t1=$SECONDS
  OCR_SMALL="$WORKDIR/ocr_out_small.pdf"

  OCR_FLAGS_SMALL=(
    --output-type pdf
    -O 3
    -j "$JOBS"
    --tesseract-timeout 120
    -l "$OCR_LANGS"
    -c
    --force-ocr
    --jpeg-quality "$JPEG_QUALITY_LOSSY"
    --png-quality "$PNG_QUALITY_LOSSY"
  )
  [[ $DESKEW -eq 1 ]] && OCR_FLAGS_SMALL+=( -d )
  [[ $AUTOROTATE -eq 1 ]] && OCR_FLAGS_SMALL+=( -r )
  [[ $HAVE_EASYOCR_PLUGIN -eq 1 ]] && OCR_FLAGS_SMALL+=( --pdf-renderer=sandwich )

  if have jbig2; then
    OCR_FLAGS_SMALL+=( --jbig2-lossy )
  else
    info "Optional 'jbig2' not found — install 'jbig2enc' for better B/W compression."
  fi

  set +e
  OLD_PATH="$PATH"; export PATH="/usr/local/bin:/usr/bin:/bin"
  "$OCRmypdf_BIN" "${OCR_FLAGS_SMALL[@]}" "${OCR_VERBOSE[@]}" "$CURRENT" "$OCR_SMALL"
  rc=$?
  export PATH="$OLD_PATH"
  set -e

  if [[ $rc -eq 0 ]]; then
    if [[ "$(filesize "$OCR_SMALL")" -lt "$OUTPUT_BYTES" ]]; then
      mv -f "$OCR_SMALL" "$OCR_TMP"
      ok "Aggressive pass produced a smaller file ($((SECONDS-_t1))s)."
      OUTPUT_BYTES="$(filesize "$OCR_TMP")"
    else
      rm -f "$OCR_SMALL"
      ok "Aggressive pass not smaller; keeping original OCR result ($((SECONDS-_t1))s)."
    fi
  else
    warn "Aggressive recompress pass failed; keeping original OCR result."
  fi
fi

# Optional Ghostscript fallback if still larger and gs exists
if have gs && [[ -n "$ratio" ]]; then
  if awk -v o="$OUTPUT_BYTES" -v i="$INPUT_BYTES" -v f="$SIZE_INFLATE_FACTOR" 'BEGIN{exit !((o/i)>f)}'; then
    warn "Attempting Ghostscript re-compress (${GS_PROFILE}) as final fallback…"
    _t2=$SECONDS
    GS_OUT="$WORKDIR/gs_out.pdf"
    set +e
    gs -sDEVICE=pdfwrite -dCompatibilityLevel=1.6 -dPDFSETTINGS="$GS_PROFILE" \
       -dNOPAUSE -dQUIET -dBATCH -sOutputFile="$GS_OUT" "$OCR_TMP"
    gs_rc=$?
    set -e
    if [[ $gs_rc -eq 0 && -f "$GS_OUT" && "$(filesize "$GS_OUT")" -lt "$(filesize "$OCR_TMP")" ]]; then
      mv -f "$GS_OUT" "$OCR_TMP"
      ok "Ghostscript reduced size ($((SECONDS-_t2))s)."
    else
      [[ -f "$GS_OUT" ]] && rm -f "$GS_OUT"
      info "Ghostscript did not reduce size or failed; keeping previous output."
    fi
  fi
fi

# Finalize
_t3=$SECONDS
mv -f "$OCR_TMP" "$OUTPUT"
ok "Wrote output: $OUTPUT ($((SECONDS-_t3))s)"

log  "============================================================"
log  "Done."
log  "Reversed        : $([[ $REVERSE -eq 1 ]] && echo Yes || echo No)"
log  "Pages (in)      : $PAGECOUNT"
log  "Pages removed   : ${#removed_pages[@]}"
log  "Pages (out)     : ${#keep_pages[@]}"
log  "Blank threshold : $BLANK_THRESHOLD @ ${BLANK_DETECT_DPI} DPI"
log  "OCR languages   : $OCR_LANGS"
log  "Optimize level  : $OCR_OPTIMIZE_LEVEL"
log  "Workers (-j)    : $JOBS"
[[ -n "$ratio" ]] && log "Size ratio      : ${ratio}× (out/in vs post-blank input)"
[[ $DEBUG -eq 1 ]] && log "Scores TSV      : $scores_file"
[[ $KEEP_TEMP -eq 1 ]] && log "Temp kept       : $WORKDIR"
log  "============================================================"
