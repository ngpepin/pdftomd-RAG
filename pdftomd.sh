#!/bin/bash
# shellcheck disable=SC1091
# shellcheck disable=SC2004
# shellcheck disable=SC2010
# shellcheck disable=SC2034
# shellcheck disable=SC2115
# shellcheck disable=SC2155
# shellcheck disable=SC2164

# Exit on error and propagate failures through pipes.
set -eE -o pipefail

#####
# PDF to Markdown wrapper for Marker (https://github.com/VikParuchuri/marker)
#
# - Splits the input PDF into 100-page chunks, runs Marker once on the chunk folder,
#   and merges the resulting markdown into a single output file.
# - Supports optional OCR pre-pass via the bundled ocr-pdf/ocr-pdf.sh and optional LLM helper mode via Marker.
# - Moves the final markdown to the directory where the script was invoked.
#
# Usage:
#
#  pdftomd.sh [options] <pdf_file|directory>
#
# Options:
#  -e, --embed       Embed images as Base64 in the output markdown
#  -t, --text        Remove image links from the final markdown (ignores --embed)
#  -v, --verbose     Show verbose output
#  -o, --ocr         Run OCR via bundled ocr-pdf/ocr-pdf.sh before conversion
#  -l, --llm         Enable Marker LLM helper (--use_llm)
#  -c, --cpu         Force CPU processing (ignore GPU even if present)
#  -r, --recurse     Recursively process PDFs when a directory is provided
#  --clean           Post-process markdown with the configured LLM to improve OCR/readability
#  --preclean-copy   Save a pre-clean copy of the merged markdown before LLM cleanup
#  -w, --workers N   Number of worker processes for marker
#  -h, --help        Show this help message
#
# Example:
#
#  pdftomd.sh mypdf.pdf
#
# Dependencies:
#
#  qpdf, pxz, marker (Python installation), bundled ocr-pdf/ocr-pdf.sh (for -o/--ocr)
#
# Notes:
#  - Default is GPU if available (auto-installs CUDA-enabled torch when needed).
#  - Default MARKER_WORKERS=1; adjust with -w when VRAM allows.
#####

# Set the following variables to control the behavior of the script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERBOSE=false
DEBUG=false
SHOW_MARKER_OUTPUT=false                                        # Set to true to see the output of the marker command
SKIP_TO_ASSEMBLY=false                                          # Set to true to skip the processing of the PDF chunks and directly assemble the markdown files
MARKER_DIRECTORY="/home/npepin/Projects/marker"                 # Change this to the directory where marker is installed
MARKER_VENV="venv"                                              # Name of the virtual environment directory in the marker directory
MARKER_RESULTS="$MARKER_DIRECTORY/$MARKER_VENV/lib/python3.10/" # Directory where marker results are stored
MARKER_RESULTS+="site-packages/conversion_results"
MARKER_WORKERS=1     # Worker processes for marker CLI
CONVERT_BASE64=false # Set to true to convert image links in the markdown files to Base64-encoded images
STRIP_IMAGE_LINKS=false # Set to true to remove image links from the final markdown
FORCE_CPU=false
RECURSE_DIR=false
CLEAN_MARKDOWN=false
PRECLEAN_COPY=false
USE_OCR=false
OCR_SCRIPT="$SCRIPT_DIR/ocr-pdf/ocr-pdf.sh"
OCR_OPTIONS="-aq" # Options to pass to the OCR script
USE_LLM=false
LLM_SERVICE=""

# source the configuration file if it exists
CONFIG_FILE="$SCRIPT_DIR/pdftomd.conf"
if [ -f "$CONFIG_FILE" ]; then
	# shellcheck source=/dev/null
	source "$CONFIG_FILE"
else
	OPENAI_API_KEY="..."
	OPENAI_MODEL="gpt-4.1"
	OPENAI_BASE_URL="https://api.openai.com/v1"
fi
# DO NOT MODIFY BELOW THIS LINE
# ----------------------------------------------

# Print CLI usage and options.
print_usage() {
	cat <<EOF
Usage: pdftomd.sh [options] <pdf_file|directory>

Options:
  -e, --embed       Embed images as Base64 in the output markdown
  -t, --text        Remove image links from the final markdown (ignores --embed)
  -v, --verbose     Show verbose output
  -o, --ocr         Run OCR via bundled ocr-pdf/ocr-pdf.sh before conversion
                    (Note that Marker will perform OCR on images if needed)
  -l, --llm         Enable Marker LLM helper (--use_llm)
  -c, --cpu         Force CPU processing (ignore GPU even if present)
  -r, --recurse     Recursively process PDFs when a directory is provided
  --clean           Post-process markdown with the configured LLM to improve OCR/readability
  --preclean-copy   Save a pre-clean copy of the merged markdown before LLM cleanup
  -w, --workers N   Number of worker processes for marker
  -h, --help        Show this help message

Output is moved to the directory where the script is run.
CUDA-enabled torch is installed automatically when a GPU is detected, unless -c is set.
EOF
}

source_pdf=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	-e | --embed)
		CONVERT_BASE64=true
		shift
		;;
	-t | --text)
		STRIP_IMAGE_LINKS=true
		shift
		;;
	-v | --verbose)
		VERBOSE=true
		shift
		;;
	-o | --ocr)
		USE_OCR=true
		shift
		;;
	-l | --llm)
		USE_LLM=true
		shift
		;;
	-c | --cpu)
		FORCE_CPU=true
		shift
		;;
	-r | --recurse)
		RECURSE_DIR=true
		shift
		;;
	--clean)
		CLEAN_MARKDOWN=true
		shift
		;;
	--preclean-copy)
		PRECLEAN_COPY=true
		shift
		;;
	-w | --workers)
		if [ -z "${2:-}" ] || [[ "$2" == -* ]]; then
			echo "Error: --workers requires a numeric value."
			exit 1
		fi
		MARKER_WORKERS="$2"
		shift 2
		;;
	-[a-zA-Z][a-zA-Z]*)
		short_flags="${1#-}"
		shift
		for ((i = 0; i < ${#short_flags}; i++)); do
			flag_char="${short_flags:i:1}"
			case "$flag_char" in
			e)
				CONVERT_BASE64=true
				;;
			t)
				STRIP_IMAGE_LINKS=true
				;;
			v)
				VERBOSE=true
				;;
			o)
				USE_OCR=true
				;;
			l)
				USE_LLM=true
				;;
			c)
				FORCE_CPU=true
				;;
			r)
				RECURSE_DIR=true
				;;
			w)
				echo "Error: -w requires a numeric value (use -w 2)."
				exit 1
				;;
			h)
				print_usage
				exit 0
				;;
			*)
				echo "Error: Unknown option '-$flag_char'"
				print_usage
				exit 1
				;;
			esac
		done
		;;
	-h | --help)
		print_usage
		exit 0
		;;
	--)
		shift
		break
		;;
	-*)
		echo "Error: Unknown option '$1'"
		print_usage
		exit 1
		;;
	*)
		if [ -z "$source_pdf" ]; then
			source_pdf="$1"
		else
			echo "Error: Unexpected argument '$1'"
			print_usage
			exit 1
		fi
		shift
		;;
	esac
done

if [ -z "$source_pdf" ]; then
	print_usage
	exit 1
fi

if ! [[ "$MARKER_WORKERS" =~ ^[0-9]+$ ]] || [ "$MARKER_WORKERS" -lt 1 ]; then
	echo "Error: --workers must be a positive integer."
	exit 1
fi

start_directory=$(pwd)
source_pdf=$(realpath "$source_pdf")

if [ -d "$source_pdf" ]; then
	if [ "$RECURSE_DIR" = false ]; then
		log "Directory detected; processing PDFs in '$source_pdf' (non-recursive)."
	else
		log "Directory detected; processing PDFs in '$source_pdf' recursively."
	fi
	process_directory "$source_pdf"
fi

if [ ! -f "$source_pdf" ]; then
	echo "Error: PDF file not found: $source_pdf"
	exit 1
fi

start_time=$(date +%s)
if [ "$VERBOSE" = true ]; then
	DEBUG=true
	SHOW_MARKER_OUTPUT=true
else
	DEBUG=false
	SHOW_MARKER_OUTPUT=false
fi

if [ "$USE_OCR" = true ]; then
	echo "Running external EasyOCR script on $(basename "$source_pdf")"
	if [ ! -x "$OCR_SCRIPT" ]; then
		echo "Error: EasyOCR script not found or not executable: $OCR_SCRIPT" >&2
		exit 1
	fi
	source_base="$(basename "$source_pdf")"
	source_base_no_ext="${source_base%.*}"
	ocr_output_pdf="$start_directory/${source_base_no_ext}_OCR.pdf"
	# Build OCR command safely to preserve paths with spaces.
	ocr_cmd=("$OCR_SCRIPT")
	if declare -p OCR_OPTIONS >/dev/null 2>&1 && declare -p OCR_OPTIONS | grep -q 'declare -a'; then
		ocr_cmd+=("${OCR_OPTIONS[@]}")
	elif [ -n "${OCR_OPTIONS:-}" ]; then
		read -r -a ocr_opts_array <<<"$OCR_OPTIONS"
		ocr_cmd+=("${ocr_opts_array[@]}")
	fi
	ocr_cmd+=("$source_pdf")
	if [ "$VERBOSE" = true ]; then
		(cd "$start_directory" && "${ocr_cmd[@]}")
	else
		(cd "$start_directory" && "${ocr_cmd[@]}" >/dev/null 2>&1)
	fi
	if [ ! -f "$ocr_output_pdf" ]; then
		echo "Error: OCR output not found: $ocr_output_pdf" >&2
		exit 1
	fi
	source_pdf=$(realpath "$ocr_output_pdf")
fi

if [ "$USE_LLM" = true ] && [ -z "$LLM_SERVICE" ]; then
	if [ -n "$OPENAI_API_KEY" ] && [ "$OPENAI_API_KEY" != "..." ]; then
		LLM_SERVICE="marker.services.openai.OpenAIService"
	fi
fi

echo "Converting PDF: $(basename "$source_pdf")"

ext=".pdf"
extmd=".md"
directory="${source_pdf%/*}"
source_no_dir="${source_pdf##*/}"
source_no_ext="${source_pdf%.*}"
source_stem="${source_no_dir%.*}"
output_split_files="${source_no_ext}_${ext}" # Pattern of split files to be generated by qpdf
output_md_files="${source_no_ext}_${extmd}"  # Pattern of markdown files generated by Marker
consolidated_md_name="${source_stem}${extmd}"
consolidated_md_file="$directory/$consolidated_md_name" # Final consolidated markdown file
attachments_dirs=()
chunk_archives=()
chunk_dir=""
temp_merge_dir=""
marker_pid=""
marker_log=""
marker_config_json=""

#
# FUNCTIONS
# ----------------------------------------------

# Log only when verbose mode is enabled.
log() {
	if [ "$VERBOSE" = true ]; then
		echo "$@"
	fi
}

# Build CLI args for re-invoking this script on multiple PDFs.
build_cli_options() {
	local opts=()
	if [ "$CONVERT_BASE64" = true ]; then
		opts+=("-e")
	fi
	if [ "$STRIP_IMAGE_LINKS" = true ]; then
		opts+=("-t")
	fi
	if [ "$VERBOSE" = true ]; then
		opts+=("-v")
	fi
	if [ "$USE_OCR" = true ]; then
		opts+=("-o")
	fi
	if [ "$USE_LLM" = true ]; then
		opts+=("-l")
	fi
	if [ "$FORCE_CPU" = true ]; then
		opts+=("-c")
	fi
	if [ "$RECURSE_DIR" = true ]; then
		opts+=("-r")
	fi
	if [ "$CLEAN_MARKDOWN" = true ]; then
		opts+=("--clean")
	fi
	if [ "$PRECLEAN_COPY" = true ]; then
		opts+=("--preclean-copy")
	fi
	if [ -n "${MARKER_WORKERS:-}" ]; then
		opts+=("-w" "$MARKER_WORKERS")
	fi
	printf '%s\n' "${opts[@]}"
}

process_directory() {
	local dir="$1"
	local pdfs=()
	shopt -s nullglob
	if [ "$RECURSE_DIR" = true ]; then
		mapfile -t pdfs < <(find "$dir" -type f \( -iname "*.pdf" \) | sort)
	else
		pdfs=("$dir"/*.pdf "$dir"/*.PDF)
	fi
	shopt -u nullglob
	if [ "${#pdfs[@]}" -eq 0 ]; then
		echo "Error: No PDF files found in directory: $dir" >&2
		exit 1
	fi
	mapfile -t dir_opts < <(build_cli_options)
	local failures=0
	for pdf in "${pdfs[@]}"; do
		echo "Processing PDF in directory: $(basename "$pdf")"
		if ! "$SCRIPT_DIR/pdftomd.sh" "${dir_opts[@]}" "$pdf"; then
			failures=$((failures + 1))
			echo "Warning: Failed processing $pdf" >&2
		fi
	done
	if [ "$failures" -gt 0 ]; then
		echo "Error: $failures PDF(s) failed during directory processing." >&2
		exit 1
	fi
	exit 0
}

if [ "$STRIP_IMAGE_LINKS" = true ]; then
	if [ "$CONVERT_BASE64" = true ]; then
		log "Text-only mode enabled; ignoring --embed."
	fi
	CONVERT_BASE64=false
fi

# Format seconds as HH:MM:SS.
format_duration() {
	local total_seconds="$1"
	local hours=$((total_seconds / 3600))
	local minutes=$(((total_seconds % 3600) / 60))
	local seconds=$((total_seconds % 60))
	printf "%02d:%02d:%02d" "$hours" "$minutes" "$seconds"
}

# Check marker logs for GPU VRAM exhaustion or other conversion failures.
marker_log_has_oom() {
	local log_file="$1"
	grep -Eqi "OutOfMemoryError|CUDA out of memory|CUDA error: out of memory|torch\\.cuda\\.OutOfMemoryError|CUBLAS_STATUS_ALLOC_FAILED|CUDNN_STATUS_ALLOC_FAILED|CUDNN_STATUS_NOT_SUPPORTED" "$log_file"
}

marker_log_has_failure() {
	local log_file="$1"
	grep -Eq "Error converting|Traceback|OutOfMemoryError|CUDA out of memory|CUDA error: out of memory|CUBLAS_STATUS_ALLOC_FAILED|CUDNN_STATUS_ALLOC_FAILED|CUDNN_STATUS_NOT_SUPPORTED" "$log_file"
}

report_marker_failure() {
	local log_file="$1"
	local exit_code="${2:-1}"
	local header="Error: marker failed"
	if [ -n "$exit_code" ] && [ "$exit_code" -ne 0 ]; then
		header="$header (exit code $exit_code)."
	else
		header="$header."
	fi
	echo "$header" >&2
	if [ -n "$log_file" ] && [ -f "$log_file" ] && marker_log_has_oom "$log_file"; then
		echo "Detected GPU VRAM exhaustion in Marker output." >&2
		echo "Tip: Try -c (CPU), reduce workers with -w 1, or re-run with -v for details." >&2
	else
		echo "Marker reported conversion failures. Re-run with -v for details." >&2
	fi
}

# Trap handler for unexpected errors.
on_error() {
	local exit_code=$?
	local line_no="$1"
	echo "Error: command failed at line $line_no (exit code $exit_code)." >&2
	cleanup_temp
	exit "$exit_code"
}

# Cleanup temp dirs and terminate marker subprocesses.
cleanup_temp() {
	# Ensure marker subprocesses are stopped before removing temp directories.
	if [ -n "$marker_pid" ] && kill -0 "$marker_pid" 2>/dev/null; then
		log "Stopping marker process $marker_pid"
		pkill -TERM -P "$marker_pid" >/dev/null 2>&1 || true
		kill "$marker_pid" >/dev/null 2>&1 || true
		sleep 2
		pkill -KILL -P "$marker_pid" >/dev/null 2>&1 || true
		kill -9 "$marker_pid" >/dev/null 2>&1 || true
	fi

		if [ -n "$chunk_dir" ] && command -v pgrep >/dev/null 2>&1; then
			marker_pids=$(pgrep -f "marker .*${chunk_dir}" || true)
		if [ -n "$marker_pids" ]; then
			log "Stopping marker processes for $chunk_dir"
			kill $marker_pids >/dev/null 2>&1 || true
			sleep 2
			kill -9 $marker_pids >/dev/null 2>&1 || true
		fi
	fi

	if [ -n "$chunk_dir" ] && [ -d "$chunk_dir" ]; then
		rm -rf "$chunk_dir"
	fi
	if [ -n "$temp_merge_dir" ] && [ -d "$temp_merge_dir" ]; then
		rm -rf "$temp_merge_dir"
	fi
	if [ -n "$marker_log" ] && [ -f "$marker_log" ]; then
		rm -f "$marker_log"
	fi
	if [ -n "$marker_config_json" ] && [ -f "$marker_config_json" ]; then
		rm -f "$marker_config_json"
	fi
}

trap 'on_error $LINENO' ERR
trap cleanup_temp INT TERM HUP QUIT EXIT

# Run a command quietly unless verbose is enabled.
run_quiet() {
	if [ "$VERBOSE" = true ]; then
		"$@"
	else
		"$@" >/dev/null 2>&1
	fi
}

# Ensure a command exists, installing via apt-get if missing.
ensure_dependency() {
	local command_name="$1"
	local package_name="$2"
	local sudo_cmd=""

	if command -v "$command_name" >/dev/null 2>&1; then
		return 0
	fi

	if ! command -v apt-get >/dev/null 2>&1; then
		echo "Error: apt-get not available to install '$package_name'." >&2
		exit 1
	fi

	if command -v sudo >/dev/null 2>&1; then
		sudo_cmd="sudo"
	fi

	log "Installing missing dependency: $package_name"
	run_quiet $sudo_cmd apt-get update
	if ! run_quiet $sudo_cmd apt-get install -y "$package_name"; then
		echo "Error: Failed to install dependency '$package_name'." >&2
		exit 1
	fi
}

# Detect NVIDIA GPU presence via nvidia-smi or device nodes.
has_nvidia_gpu() {
	if command -v nvidia-smi >/dev/null 2>&1; then
		if nvidia-smi -L >/dev/null 2>&1; then
			return 0
		fi
	fi

	if [ -e /proc/driver/nvidia/version ] || [ -e /dev/nvidia0 ]; then
		return 0
	fi

	return 1
}

# Extract CUDA version from nvidia-smi output.
get_cuda_version_from_nvidia_smi() {
	if ! command -v nvidia-smi >/dev/null 2>&1; then
		return 1
	fi

	nvidia-smi 2>/dev/null | awk -F 'CUDA Version: ' '
        /CUDA Version/ {
            split($2, a, " ")
            print a[1]
            exit
        }
    '
}

# Map CUDA major version to a torch wheel tag.
map_cuda_version_to_torch_tag() {
	local cuda_version="$1"
	local major="${cuda_version%%.*}"

	if [ "$major" -ge 12 ]; then
		echo "cu121"
		return 0
	fi

	if [ "$major" -eq 11 ]; then
		echo "cu118"
		return 0
	fi

	echo ""
}

# Check whether torch.cuda.is_available() returns true.
torch_cuda_available() {
	python3 <<'PY' >/dev/null 2>&1
import sys
try:
    import torch
    sys.exit(0 if torch.cuda.is_available() else 1)
except Exception:
    sys.exit(1)
PY
}

# Install CUDA-enabled torch if a GPU is present and CUDA is available.
install_gpu_torch_if_needed() {
	local cuda_version=""
	local torch_cuda_tag=""

	# Auto-install CUDA-enabled torch when a GPU is available unless CPU is forced.
	if [ "$FORCE_CPU" = true ]; then
		log "CPU mode enabled; skipping CUDA-enabled torch install."
		return 0
	fi

	if ! has_nvidia_gpu; then
		log "No NVIDIA GPU detected; skipping CUDA-enabled torch install."
		return 0
	fi

	if torch_cuda_available; then
		log "CUDA-enabled torch already available."
		return 0
	fi

	cuda_version="$(get_cuda_version_from_nvidia_smi)"
	if [ -z "$cuda_version" ]; then
		log "Unable to determine CUDA version via nvidia-smi; skipping torch install."
		return 0
	fi

	torch_cuda_tag="$(map_cuda_version_to_torch_tag "$cuda_version")"
	if [ -z "$torch_cuda_tag" ]; then
		log "Unsupported CUDA version '$cuda_version'; skipping torch install."
		return 0
	fi

	log "Installing CUDA-enabled torch ($torch_cuda_tag) based on CUDA $cuda_version."
	if ! run_quiet python3 -m pip install --upgrade --force-reinstall --no-cache-dir torch --index-url "https://download.pytorch.org/whl/$torch_cuda_tag"; then
		echo "Error: Failed to install CUDA-enabled torch ($torch_cuda_tag)." >&2
		exit 1
	fi

	if ! torch_cuda_available; then
		echo "Error: CUDA-enabled torch install completed, but torch.cuda.is_available() is still false." >&2
		exit 1
	fi
}

# Set TORCH_DEVICE based on GPU availability and overrides.
configure_torch_device() {
	local cuda_available=false

	# Honor CPU override even if CUDA is available.
	if [ "$FORCE_CPU" = true ]; then
		export TORCH_DEVICE="cpu"
		log "CPU mode enabled; forcing TORCH_DEVICE=cpu."
		return 0
	fi

	if has_nvidia_gpu && torch_cuda_available; then
		cuda_available=true
	fi

	if [ "$cuda_available" = true ]; then
		if [ -z "${TORCH_DEVICE:-}" ] || [ "$TORCH_DEVICE" = "cpu" ]; then
			export TORCH_DEVICE="cuda"
		fi
		log "CUDA detected; using TORCH_DEVICE=${TORCH_DEVICE:-cuda}."
	else
		if [ "${TORCH_DEVICE:-}" = "cuda" ]; then
			export TORCH_DEVICE="cpu"
		fi
		log "CUDA not available; using CPU."
	fi
}

# Function to convert image links in a Markdown file to Base64-encoded images
# Replace local image links in markdown with Base64 data URIs.
convert_md_to_base64() {
	local input_file="$1" # Quote the first parameter to handle spaces
	local output_file="${input_file%.*}.emd"

	# Check if the input file exists
	if [[ ! -f "$input_file" ]]; then
		echo "Error: Input file '$input_file' not found."
		return 1
	fi

	# Python script to replace image links with Base64-encoded images
	python3 <<EOF
import base64
import os
import re

def replace_image_links(markdown_content):
    def base64_image(match):
        image_path = (match.group(1) or "").strip()
        if not image_path:
            return match.group(0)
        if image_path.startswith(("http://", "https://", "data:")):
            return match.group(0)
        if not os.path.exists(image_path):
            return match.group(0)
        with open(image_path, "rb") as image_file:
            encoded_string = base64.b64encode(image_file.read()).decode('utf-8')
        return f"![](data:image/{image_path.split('.')[-1]};base64,{encoded_string})"
    
    pattern = re.compile(r'!\[.*?\]\((.*?)\)')
    return pattern.sub(base64_image, markdown_content)

with open("$input_file", 'r') as file:
    content = file.read()

new_content = replace_image_links(content)

with open("$output_file", 'w') as file:
    file.write(new_content)
EOF

	log "Base64-encoded Markdown file created: $output_file"
}

# Remove image links and image reference definitions from a Markdown file.
strip_image_links_from_md() {
	local input_file="$1"

	if [[ ! -f "$input_file" ]]; then
		echo "Error: Input file '$input_file' not found."
		return 1
	fi

	python3 - "$input_file" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8", errors="ignore") as handle:
    content = handle.read()

# Remove HTML image tags.
content = re.sub(r"<img\b[^>]*>", "", content, flags=re.IGNORECASE)

# Replace inline markdown images with their alt text.
def repl_inline(match):
    alt = (match.group(1) or "").strip()
    return alt

content = re.sub(r"!\[([^\]]*)\]\(([^)]+)\)", repl_inline, content)

# Replace reference-style markdown images with their alt text.
content = re.sub(r"!\[([^\]]*)\]\[([^\]]*)\]", repl_inline, content)

# Drop reference definitions that point to common image formats or data URIs.
def is_image_ref(url):
    url = url.lower()
    if url.startswith("data:image/"):
        return True
    return re.search(r"\.(png|jpg|jpeg|gif|svg|webp|bmp|tiff)(\?|#|$)", url) is not None

lines = []
for line in content.splitlines():
    match = re.match(r"^\s*\[([^\]]+)\]:\s*(\S+)", line)
    if match and is_image_ref(match.group(2)):
        continue
    lines.append(line)

with open(path, "w", encoding="utf-8") as handle:
    handle.write("\\n".join(lines))
PY

	log "Stripped image links from markdown: $input_file"
}

# Clean markdown with an OpenAI-compatible LLM, adding footnotes with original text.
clean_markdown_with_llm() {
	local input_file="$1"

	if [[ ! -f "$input_file" ]]; then
		echo "Error: Input file '$input_file' not found."
		return 1
	fi

	missing_vars=()
	if [ -z "${OPENAI_BASE_URL:-}" ]; then
		missing_vars+=("OPENAI_BASE_URL")
	fi
	if [ -z "${OPENAI_MODEL:-}" ]; then
		missing_vars+=("OPENAI_MODEL")
	fi
	if [ -z "${OPENAI_API_KEY:-}" ] || [ "$OPENAI_API_KEY" = "..." ]; then
		missing_vars+=("OPENAI_API_KEY")
	fi
	if [ "${#missing_vars[@]}" -gt 0 ]; then
		echo "Error: --clean requires OpenAI-compatible settings in pdftomd.conf." >&2
		echo "Missing: ${missing_vars[*]}" >&2
		return 1
	fi

	if ! [[ "${MAX_TOKENS:-30000}" =~ ^[0-9]+$ ]]; then
		echo "Error: MAX_TOKENS must be a positive integer (set in pdftomd.conf)." >&2
		return 1
	fi

	OPENAI_BASE_URL="$OPENAI_BASE_URL" OPENAI_MODEL="$OPENAI_MODEL" OPENAI_API_KEY="$OPENAI_API_KEY" MAX_TOKENS="${MAX_TOKENS:-30000}" VERBOSE="$VERBOSE" \
		python3 - "$input_file" <<'PY'
import json
import os
import re
import sys
import urllib.request
import urllib.error
from typing import List

path = sys.argv[1]
verbose = os.environ.get("VERBOSE", "false").lower() == "true"
def vprint(*args, **kwargs):
    if verbose:
        print(*args, **kwargs)
base_url = os.environ.get("OPENAI_BASE_URL", "").strip()
model = os.environ.get("OPENAI_MODEL", "").strip()
api_key = os.environ.get("OPENAI_API_KEY", "").strip()
max_tokens = int(os.environ.get("MAX_TOKENS", "30000"))

if not base_url or not model or not api_key:
    raise SystemExit("Missing OPENAI_BASE_URL/OPENAI_MODEL/OPENAI_API_KEY.")

base_url = base_url.rstrip("/")
if base_url.endswith("/v1"):
    endpoint = f"{base_url}/chat/completions"
else:
    endpoint = f"{base_url}/v1/chat/completions"

vprint("Starting LLM cleanup...")
with open(path, "r", encoding="utf-8", errors="ignore") as handle:
    content = handle.read()
original_content = content

data_uri_map = {}

def replace_data_uris(text: str) -> str:
    pattern = re.compile(r"data:image/[a-zA-Z0-9.+-]+;base64,[A-Za-z0-9+/=\s]+")
    def repl(match):
        token = f"__DATA_IMAGE_TOKEN_{len(data_uri_map) + 1}__"
        data_uri_map[token] = match.group(0)
        return token
    return pattern.sub(repl, text)

def restore_data_uris(text: str) -> str:
    for token, uri in data_uri_map.items():
        text = text.replace(token, uri)
    return text

content = replace_data_uris(content)
vprint(f"Stripped {len(data_uri_map)} embedded image(s) before LLM cleanup.")
vprint(f"Chars (original/stripped): {len(original_content)}/{len(content)}")

def estimate_tokens(text: str) -> int:
    return max(1, int(len(text) / 4))

def split_chunks(text: str, budget_tokens: int) -> List[str]:
    paras = text.split("\n\n")
    chunks = []
    current = []
    current_tokens = 0
    max_chars = budget_tokens * 4
    for para in paras:
        p_tokens = estimate_tokens(para)
        if p_tokens > budget_tokens:
            # Split oversized paragraph by chars.
            if current:
                chunks.append("\n\n".join(current))
                current = []
                current_tokens = 0
            for i in range(0, len(para), max_chars):
                chunks.append(para[i : i + max_chars])
            continue
        if current and current_tokens + p_tokens > budget_tokens:
            chunks.append("\n\n".join(current))
            current = [para]
            current_tokens = p_tokens
        else:
            current.append(para)
            current_tokens += p_tokens
    if current:
        chunks.append("\n\n".join(current))
    return chunks

# Reserve space for prompt and output.
chunk_budget = max(1000, int(max_tokens * 0.45))
response_budget = max(1000, int(max_tokens * 0.45))

total_tokens = estimate_tokens(content)
vprint(f"Estimated tokens: {total_tokens} (max {max_tokens}).")
if total_tokens <= max_tokens:
    chunks = [content]
else:
    chunks = split_chunks(content, chunk_budget)
vprint(f"Chunk count: {len(chunks)} (budget {chunk_budget} tokens, response {response_budget}).")

system_prompt = (
    "You are a meticulous editor. Improve readability and correct likely OCR errors "
    "without inventing new content. Preserve markdown structure (headings, lists, code, "
    "tables, links). When you replace or remove text, insert a placeholder like [[FN1]] "
    "at the correction point and record the original text in notes. "
    "Do not alter any __DATA_IMAGE_TOKEN_n__ placeholders."
)

def build_user_prompt(text: str, index: int, total: int) -> str:
    return (
        f"Chunk {index}/{total}. Edit the markdown below.\\n\\n"
        "Rules:\\n"
        "- Preserve meaning; fix OCR errors and improve readability.\\n"
        "- Keep markdown structure.\\n"
        "- Do not alter any __DATA_IMAGE_TOKEN_n__ placeholders.\\n"
        "- For each correction/removal, insert a placeholder [[FNn]] where the change occurs.\\n"
        "- Return ONLY JSON with keys: text, notes.\\n"
        "- notes is a list of objects: {\"id\": n, \"original\": \"...\", \"reason\": \"corrected\"|\"removed\"}.\\n"
        "- Use ids starting at 1 and increment for each note in this chunk.\\n\\n"
        "Markdown:\\n"
        + text
    )

def parse_json(content_text: str):
    text = content_text.strip()
    # Strip markdown fences if present.
    if text.startswith("```"):
        fence_end = text.find("\n")
        if fence_end != -1:
            text = text[fence_end + 1 :]
        if text.endswith("```"):
            text = text[:-3]
        text = text.strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        # Try to decode the first JSON object found.
        decoder = json.JSONDecoder()
        for i, ch in enumerate(text):
            if ch == "{":
                try:
                    obj, _ = decoder.raw_decode(text[i:])
                    return obj
                except json.JSONDecodeError:
                    continue
        # Last resort: attempt from first to last brace.
        start = text.find("{")
        end = text.rfind("}")
        if start != -1 and end != -1 and end > start:
            return json.loads(text[start : end + 1])
        raise

def call_llm(text: str, index: int, total: int) -> dict:
    vprint(f"Sending chunk {index}/{total} to LLM...")
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": build_user_prompt(text, index, total)},
        ],
        "temperature": 0.2,
        "max_tokens": response_budget,
    }
    # Ask for JSON object output if the backend supports it.
    payload["response_format"] = {"type": "json_object"}
    data = json.dumps(payload).encode("utf-8")
    headers = {"Content-Type": "application/json"}
    if api_key and api_key != "...":
        headers["Authorization"] = f"Bearer {api_key}"
    req = urllib.request.Request(endpoint, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=600) as resp:
            body = resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="ignore")
        raise RuntimeError(f"LLM request failed ({e.code}): {body}") from e
    except Exception as e:
        raise RuntimeError(f"LLM request failed: {e}") from e

    response = json.loads(body)
    if "error" in response:
        raise RuntimeError(f"LLM error: {response['error']}")
    content_text = response["choices"][0]["message"]["content"]
    try:
        result = parse_json(content_text)
        vprint(f"Received chunk {index}/{total} response.")
        return result
    except Exception:
        # One retry with a stricter prompt.
        strict_payload = {
            "model": model,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": build_user_prompt(text, index, total)},
                {"role": "user", "content": "Return ONLY valid JSON. No markdown, no extra text."},
            ],
            "temperature": 0.0,
            "max_tokens": response_budget,
            "response_format": {"type": "json_object"},
        }
        data = json.dumps(strict_payload).encode("utf-8")
        req = urllib.request.Request(endpoint, data=data, headers=headers, method="POST")
        with urllib.request.urlopen(req, timeout=600) as resp:
            body = resp.read().decode("utf-8")
        response = json.loads(body)
        content_text = response["choices"][0]["message"]["content"]
        try:
            result = parse_json(content_text)
            vprint(f"Received chunk {index}/{total} response (retry).")
            return result
        except Exception:
            # Last-resort fallback: treat the response as cleaned text with no notes.
            fallback_text = content_text.strip()
            if fallback_text.startswith("```"):
                fence_end = fallback_text.find("\n")
                if fence_end != -1:
                    fallback_text = fallback_text[fence_end + 1 :]
                if fallback_text.endswith("```"):
                    fallback_text = fallback_text[:-3]
                fallback_text = fallback_text.strip()
            vprint(f"Received chunk {index}/{total} response (fallback text).")
            return {"text": fallback_text, "notes": []}

global_notes = []
global_id = 0
cleaned_chunks = []

for idx, chunk in enumerate(chunks, start=1):
    result = call_llm(chunk, idx, len(chunks))
    text_out = result.get("text", "")
    notes = result.get("notes", [])

    placeholders = re.findall(r"\\[\\[FN(\\d+)\\]\\]", text_out)
    if len(placeholders) != len(notes):
        # Best-effort: align by order.
        placeholders = re.findall(r"\\[\\[FN(\\d*)\\]\\]", text_out)

    for note in notes:
        global_id += 1
        note_id = note.get("id")
        placeholder = f"[[FN{note_id}]]"
        if placeholder in text_out:
            text_out = text_out.replace(placeholder, f"[^{global_id}]", 1)
        else:
            # Fallback: replace the first available placeholder.
            text_out = re.sub(r"\\[\\[FN\\d*\\]\\]", f"[^{global_id}]", text_out, count=1)
        original = " ".join(str(note.get("original", "")).split())
        reason = note.get("reason", "corrected")
        if reason == "removed":
            label = "Removed OCR garble"
        else:
            label = "Original text"
        global_notes.append((global_id, f"{label}: {original}"))

    cleaned_chunks.append(text_out)

cleaned = "\n\n".join(cleaned_chunks).rstrip()

missing_tokens = [t for t in data_uri_map if t not in cleaned]
if missing_tokens:
    restored = ["", "## Embedded Images (restored)", ""]
    for token in missing_tokens:
        restored.append(f"![]({data_uri_map[token]})")
    cleaned = cleaned + "\n" + "\n".join(restored)

notes_section = ["", "---", "", "# OCR Corrections Notes", ""]
if global_notes:
    for note_id, note_text in global_notes:
        notes_section.append(f"[^{note_id}]: {note_text}")
else:
    notes_section.append("No corrections were logged.")

cleaned = cleaned + "\n" + "\n".join(notes_section) + "\n"
cleaned = restore_data_uris(cleaned)
vprint("Restored embedded images after LLM cleanup.")

backup = path + ".bak"
with open(backup, "w", encoding="utf-8") as handle:
    handle.write(original_content)
with open(path, "w", encoding="utf-8") as handle:
    handle.write(cleaned)

print(f"Cleaned markdown written to: {path}")
print(f"Backup of original markdown saved to: {backup}")
vprint("LLM cleanup complete.")
PY
}

# Function to generate a unique filename by appending a counter if the file already exists
# Create a unique filename by appending (n) when needed.
get_unique_filename() {
	local filename="$1"

	local base_name="${filename%.*}"  # Remove the last extension
	local extension="${filename##*.}" # Get the last extension
	local counter=1
	local new_filename="$filename"

	# Check if the file already exists
	if [[ -e "$filename" ]]; then
		# Extract the true basename (before the first extension)
		local true_base_name="${filename%%.*}"
		local remaining_ext="${filename#*.}"

		# Check if the true basename already contains a counter in the format (n)
		if [[ "$true_base_name" =~ \((.*)\)$ ]]; then
			# Extract the existing counter and increment it
			counter=$((${BASH_REMATCH[1]} + 1))
			true_base_name="${true_base_name%(*}" # Remove the existing counter
		fi

		# Construct the new filename with the incremented counter
		new_filename="${true_base_name}(${counter}).${remaining_ext}"

		# Recursively call the function to handle cases where the new filename also exists
		new_filename=$(get_unique_filename "$new_filename")
	fi

	echo "$new_filename"
}

# Function to create a compressed archive of a file using tar and pxz
# Create a tar.xz archive from a file or directory.
parch_func() {
	local input_file="$1"

	local candidate_name="$input_file.tar.xz"
	local target_name="$(get_unique_filename "$candidate_name")"
	local tarball_name="${target_name%.*}"
	tar -cf "$tarball_name" -C "$(dirname "$input_file")" "$(basename "$input_file")"
	pxz -zef "$tarball_name"
	echo "$target_name"
}

if [ "$DEBUG" = true ]; then
	echo "Source PDF: $source_pdf"
	echo "Directory: $directory"
	echo "Split Filenames: $output_split_files"
fi

ensure_dependency "qpdf" "qpdf"
ensure_dependency "pxz" "pxz"
page_count=$(qpdf --show-npages "$source_pdf" 2>/dev/null || true)
if ! [[ "$page_count" =~ ^[0-9]+$ ]]; then
	page_count=""
fi

#
# SPLIT PDF INTO CHUNKS
# ----------------------------------------------

chunk_pages=100
if [ "$USE_LLM" = true ]; then
	chunk_pages=25
fi

log ""
log "Splitting '$source_no_dir' into ${chunk_pages}-page chunks for processing by Marker"
cd "$directory" || exit

if [ "$SKIP_TO_ASSEMBLY" = false ]; then
	run_quiet qpdf --split-pages="$chunk_pages" "$source_pdf" "$output_split_files"
fi

# Get the list of the resulting chunked PDF files
start_name="${output_split_files##*/}"
start_name="${start_name%.*}"

# Create an array of the chunked PDF filenames
mapfile -t file_array < <(ls "$directory" | grep "^$start_name" | grep "$ext$" | sort -t'-' -k2,2n)

# Display the list of chunked PDF filenames
if [ "$DEBUG" = true ]; then
	echo "Chunked PDF files:"
	for i in "${!file_array[@]}"; do
		echo "${file_array[$i]}"
	done
fi

#
# PROCESS PDF CHUNKS WITH MARKER (PYTHON)
# ----------------------------------------------

if [ "$SKIP_TO_ASSEMBLY" = false ]; then
	chunk_dir=$(mktemp -d)
	for file in "${file_array[@]}"; do
		mv -f "$directory/$file" "$chunk_dir/"
	done

	# Activate the virtual environment
	cd "$MARKER_DIRECTORY" || exit
	source "$MARKER_VENV/bin/activate"
	install_gpu_torch_if_needed
	configure_torch_device

	log "Begin processing chunks with Marker to create markdown files.  This may take a while..."
	if [ "$SHOW_MARKER_OUTPUT" = true ]; then
		echo "----------------------------------------------------------------------------------------------------------------------------------------------------------------"
	fi

	# Run marker once for the chunk folder to avoid per-chunk model reloads.
	marker_use_llm_original="$USE_LLM"
	marker_fallback_used=false
	while true; do
		if [ -n "$marker_config_json" ] && [ -f "$marker_config_json" ]; then
			rm -f "$marker_config_json"
			marker_config_json=""
		fi

		marker_extra_args=(--timeout=240)
		if [ "$USE_LLM" = true ]; then
			marker_extra_args+=(--use_llm)
		fi
		if [ -n "$LLM_SERVICE" ]; then
			marker_extra_args+=(--llm_service "$LLM_SERVICE")
		fi
		if [ "$USE_LLM" = true ] && [ "$LLM_SERVICE" = "marker.services.openai.OpenAIService" ]; then
			if [ -n "$OPENAI_API_KEY" ] && [ "$OPENAI_API_KEY" != "..." ]; then
				marker_extra_args+=(--openai_api_key "$OPENAI_API_KEY")
			fi
			if [ -n "$OPENAI_MODEL" ] && [ "$OPENAI_MODEL" != "..." ]; then
				marker_extra_args+=(--openai_model "$OPENAI_MODEL")
			fi
			if [ -n "$OPENAI_BASE_URL" ] && [ "$OPENAI_BASE_URL" != "..." ]; then
				marker_extra_args+=(--openai_base_url "$OPENAI_BASE_URL")
			fi
		fi
		if [ "$USE_OCR" = true ]; then
			marker_extra_args+=(--disable_ocr)
		else
			marker_config_json="$(mktemp)"
			cat >"$marker_config_json" <<'JSON'
{"force_ocr": true, "strip_existing_ocr": true}
JSON
			marker_extra_args+=(--config_json "$marker_config_json")
		fi
		cmd="marker '$chunk_dir' --output_dir '$MARKER_RESULTS' --workers $MARKER_WORKERS --timeout=240"
		if [ "$USE_LLM" = true ]; then
			cmd="$cmd --use_llm"
		fi
		if [ -n "$LLM_SERVICE" ]; then
			cmd="$cmd --llm_service '$LLM_SERVICE'"
		fi
		if [ "$USE_LLM" = true ] && [ "$LLM_SERVICE" = "marker.services.openai.OpenAIService" ]; then
			if [ -n "$OPENAI_API_KEY" ] && [ "$OPENAI_API_KEY" != "..." ]; then
				cmd="$cmd --openai_api_key '[redacted]'"
			fi
			if [ -n "$OPENAI_MODEL" ] && [ "$OPENAI_MODEL" != "..." ]; then
				cmd="$cmd --openai_model '$OPENAI_MODEL'"
			fi
			if [ -n "$OPENAI_BASE_URL" ] && [ "$OPENAI_BASE_URL" != "..." ]; then
				cmd="$cmd --openai_base_url '$OPENAI_BASE_URL'"
			fi
		fi
		if [ "$USE_OCR" = true ]; then
			cmd="$cmd --disable_ocr"
		elif [ -n "$marker_config_json" ]; then
			cmd="$cmd --config_json '$marker_config_json'"
		fi
		marker_log="$(mktemp)"
		marker_timeout_flag="$(mktemp)"
		rm -f "$marker_timeout_flag"
		monitor_pid=""
		if [ "$SHOW_MARKER_OUTPUT" = true ]; then
			echo "Running Marker command: $cmd"
			(
				marker "$chunk_dir" --output_dir "$MARKER_RESULTS" --workers "$MARKER_WORKERS" "${marker_extra_args[@]}" 2>&1 | tee "$marker_log"
			) &
		else
			(
				marker "$chunk_dir" --output_dir "$MARKER_RESULTS" --workers "$MARKER_WORKERS" "${marker_extra_args[@]}" >"$marker_log" 2>&1
			) &
		fi
		marker_pid=$!

		if [ "$USE_LLM" = true ]; then
			(
				tail -n +1 -F "$marker_log" 2>/dev/null | while read -r line; do
					if [[ "$line" == *"Rate limit error"* ]]; then
						echo "$line" >"$marker_timeout_flag"
						pkill -TERM -P "$marker_pid" >/dev/null 2>&1 || true
						kill "$marker_pid" >/dev/null 2>&1 || true
						break
					fi
				done
			) &
			monitor_pid=$!
		fi

		if wait "$marker_pid"; then
			marker_status=0
		else
			marker_status=$?
		fi
		marker_pid=""

		if [ -n "$monitor_pid" ]; then
			kill "$monitor_pid" >/dev/null 2>&1 || true
			wait "$monitor_pid" >/dev/null 2>&1 || true
		fi

		if [ -f "$marker_timeout_flag" ] && [ "$USE_LLM" = true ] && [ "$marker_fallback_used" = false ]; then
			rm -f "$marker_timeout_flag"
			marker_fallback_used=true
			log "Detected marker rate limit error; retrying without --use_llm."
			USE_LLM=false
			continue
		fi
		rm -f "$marker_timeout_flag"

		if [ "$marker_status" -ne 0 ]; then
			report_marker_failure "$marker_log" "$marker_status"
			exit "$marker_status"
		fi
		# Convert failures can be logged even if marker exits 0; detect and fail fast.
		if marker_log_has_failure "$marker_log"; then
			report_marker_failure "$marker_log" 1
			exit 1
		fi
		break
	done
	USE_LLM="$marker_use_llm_original"

	if [ "$SHOW_MARKER_OUTPUT" = true ]; then
		echo "----------------------------------------------------------------------------------------------------------------------------------------------------------------"
	fi
	log "Completed processing PDF chunks to turn them into markdown files"
fi

# Iterate through the files in numerical order
for i in "${!file_array[@]}"; do

	file="${file_array[$i]}"
	# file_path_esc=$(printf "%q" "$file_path")
	# file_path_esc=$(printf "%q" "$file_path_esc")
	num="${file##*_-}"
	num="${num%%-*}"
	log "Processing file: $file; starts with page $num"

	if [ "$SKIP_TO_ASSEMBLY" = false ]; then
		# Chane to the directory where the markdown file + pictures are stored
		file_no_ext="${file%.*}"
		output_md_file_path="$MARKER_RESULTS/$file_no_ext"
		cd "$output_md_file_path"

		if [ "$DEBUG" = true ]; then
			echo "Marker output directory: $output_md_file_path"
		fi

		if [ $CONVERT_BASE64 = true ]; then
			if [ "$DEBUG" = true ]; then
				echo "Embeding images as Base64 into the markdown file $file_no_ext$extmd"
			fi

			# Convert the image links in the markdown file into Base64-encoded images to eleminated all external dependencies
			convert_md_to_base64 "$file_no_ext$extmd"
			if [ "$DEBUG" = true ]; then
				echo "Saving original version with extension .bak"
			fi
			mv -f "$file_no_ext$extmd" "${file_no_ext}.bak${extmd}"
			mv -f "${file_no_ext}.emd" "$file_no_ext$extmd"

			# Move the markdown file to the original directory
			if [ "$DEBUG" = true ]; then
				echo "Moving the markdown file to $directory"
			fi
			mv -f "$file_no_ext$extmd" "$directory"
			cd "../"
			parent_dir="$(pwd)"

			# Create a compressed archive of Marker's output directory
			if [ "$DEBUG" = true ]; then
				echo "Compressing and archiving the output directory $parent_dir/$file_no_ext"
			fi
			image_archive="$(parch_func "$file_no_ext")"

			# Move the compressed archive(.tar.xz) to the original directory as a backup
			if [ "$DEBUG" = true ]; then
				echo "Moving the archive $image_archive to directory $directory"
				echo "Removing the directory $parent_dir/$file_no_ext"
			fi
			mv -f "$image_archive" "$directory"
			chunk_archives+=("$directory/$(basename "$image_archive")")
			rm -rf "$parent_dir/$file_no_ext"

		else
			if [ "$DEBUG" = true ]; then
				echo "Markdown File: $file_no_ext$extmd"
			fi

			# create a 8 character hash with the markdown
			# file name to use as a unique identifier in the attachment directory name
			hash=$(echo "$file_no_ext" | md5sum | cut -c 1-8)

			# determine the first 16 character of the filename without spaces or other characters
			abbrev_fname=$(echo "$file_no_ext" | tr -d '[:punct:]' | tr -d ' ' | cut -c 1-16)

			attachments_dir="attachments_${abbrev_fname}${hash}"
			mkdir "$attachments_dir"
			if [ "$DEBUG" = true ]; then
				echo "Attachment directory: $attachments_dir"
			fi

			# temporarily move the markdown file to a temp directory
			temp_md_dir=$(mktemp -d)
			mv -f "$file_no_ext$extmd" "$temp_md_dir"

			# move all remaining files to the attachments directory
			shopt -s dotglob nullglob
			for asset in *; do
				if [ "$asset" = "$attachments_dir" ]; then
					continue
				fi
				mv -f "$asset" "$attachments_dir/"
			done
			shopt -u dotglob nullglob

			# move the markdown file back to the Marker output directory
			mv -f "$temp_md_dir/$file_no_ext$extmd" "$output_md_file_path"
			# delete temp directory
			rm -fr "$temp_md_dir"

			# change all links in the markdown file to point to the attachments directory
			sed -i -E "s|!\\[([^]]*)\\]\\(([^)]+)\\)|![\\1](${attachments_dir}/\\2)|g" "$file_no_ext$extmd"

			# move the markdown file to the original directory where the PDF file is located
			if [ "$DEBUG" = true ]; then
				echo "Moving the markdown file to $directory"
			fi
			mv -f "$file_no_ext$extmd" "$directory"

			# move the attachments directory to the original directory where the PDF file is located
			if [ "$DEBUG" = true ]; then
				echo "Moving the attachments directory to $directory"
			fi
			mv -f "$attachments_dir" "$directory"
			attachments_dirs+=("$attachments_dir")

		fi
	fi

done

#
# MERGE MD FILES INTO ONE
# ----------------------------------------------

log ""
log "Merging markdown files into one"
start_name="${output_md_files##*/}"
start_name="${start_name%.*}"

shopt -s nullglob
mapfile -t file_array_md < <(
	for f in "$directory/${start_name}-"*.md; do
		basename "$f"
	done | sort -t'-' -k2,2n
)
shopt -u nullglob
if [ "${#file_array_md[@]}" -eq 0 ]; then
	echo "Error: No chunk markdown files found for prefix ${start_name}-" >&2
	exit 1
fi

# Display the list of chunked MD files
if [ "$DEBUG" = true ]; then
	for i in "${!file_array_md[@]}"; do
		#     file_array_q[$i]="'${file_array[$i]}'"
		echo "${file_array_md[$i]}"
	done
fi

# Iteratively use 'cat' to append the contents of the MD chunks into the consolidated MD output file
cd "$directory" || exit
temp_dir=$(mktemp -d)
temp_merge_dir="$temp_dir"
touch "$consolidated_md_file"
for i in "${!file_array_md[@]}"; do

	file="${file_array_md[$i]}"
	file_path="$directory/$file"
	if [ "$DEBUG" = true ]; then
		num=$(echo "'$file'" | awk -F'_-' '{print $2}' | awk -F'-' '{print $1}')
		echo "Processing file: $file (starts with page $num)"
	fi
	cat "$file_path" >>"$consolidated_md_file"
	echo "" >>"$consolidated_md_file"

	# move the consolidated markdown archive to the temp directory
	if [ $CONVERT_BASE64 = true ]; then
		mv -f "$file_path" "$temp_dir"
		archive_file="${file_path%.*}.tar.xz"
		if [ -f "$archive_file" ]; then
			mv -f "$archive_file" "$temp_dir"
		else
			log "Missing chunk archive for $(basename "$file_path"); skipping."
		fi
	else
		rm -f "$file_path"
	fi
done

# Create a compressed archive of the consolidated markdown archives
full_archive=""
if [ $CONVERT_BASE64 = true ]; then
	full_archive_dir="${temp_dir%/*}"
	cd "$full_archive_dir" || exit
	full_archive="$(parch_func "$temp_dir")"
	mv -f "$full_archive" "$directory"
	rm -rf "$temp_dir"
	temp_merge_dir=""
else
	rm -rf "$temp_dir"
	temp_merge_dir=""
fi
cd "$directory" || exit

#
# ARCHIVE CONSOLIDATED OUTPUT WITH ATTACHMENTS (IF NEEDED)
# ----------------------------------------------

bundle_archive=""
bundle_archive_created=false
if [ "$CONVERT_BASE64" = false ] && [ "$STRIP_IMAGE_LINKS" = false ]; then
	# Collect attachment directories referenced in the consolidated markdown file.
	if [ -f "$consolidated_md_file" ]; then
		mapfile -t attachment_refs < <(grep -o 'attachments_[^)/]*' "$consolidated_md_file" | sort -u)
		if [ "${#attachment_refs[@]}" -gt 0 ]; then
			mapfile -t attachments_dirs < <(printf '%s\n' "${attachments_dirs[@]}" "${attachment_refs[@]}" | sort -u)
		fi
	fi

	filtered_dirs=()
	for dir in "${attachments_dirs[@]}"; do
		if [ -d "$directory/$dir" ]; then
			filtered_dirs+=("$dir")
		fi
	done
	attachments_dirs=("${filtered_dirs[@]}")
	unset filtered_dirs

	# Bundle attachments only when images are not embedded.
	if [ "${#attachments_dirs[@]}" -gt 0 ]; then
		bundle_candidate="$directory/${source_stem}_bundle.tar.xz"
		bundle_target="$(get_unique_filename "$bundle_candidate")"
		bundle_tar="${bundle_target%.*}"
		tar -cf "$bundle_tar" -C "$directory" "${attachments_dirs[@]}"
		pxz -zef "$bundle_tar"
		bundle_archive="$bundle_target"
		bundle_archive_created=true
	fi
fi

#
# CLEANUP
# ----------------------------------------------

# Delete the split PDF files
if [ -n "$chunk_dir" ] && [ -d "$chunk_dir" ]; then
	rm -rf "$chunk_dir"
	chunk_dir=""
else
	for i in "${!file_array[@]}"; do
		file="${file_array[$i]}"
		file_path="$directory/$file"
		rm -f "$file_path"
	done
fi

log "Completed merging markdown files into $consolidated_md_name"

#
# MOVE OUTPUTS TO START DIRECTORY AND CLEANUP
# ----------------------------------------------

md_target="$start_directory/$consolidated_md_name"
bundle_archive_name=""
if [ -n "$bundle_archive" ]; then
	bundle_archive_name="$(basename "$bundle_archive")"
fi

	if [ "$directory" != "$start_directory" ]; then
		if [ -e "$md_target" ] && [ "$consolidated_md_file" -ef "$md_target" ]; then
			md_target="$consolidated_md_file"
		else
			if [ -e "$md_target" ]; then
				backup_md_target="$(get_unique_filename "${md_target}.bak")"
				mv -f "$md_target" "$backup_md_target"
				log "Existing output backed up to $backup_md_target"
			fi
			mv -f "$consolidated_md_file" "$md_target"
		fi
		if [ -n "$bundle_archive" ] && [ -f "$bundle_archive" ]; then
			mv -f "$bundle_archive" "$start_directory"
		fi
	else
	md_target="$consolidated_md_file"
fi

if [ "${#attachments_dirs[@]}" -gt 0 ]; then
	if [ "$STRIP_IMAGE_LINKS" = true ]; then
		for dir in "${attachments_dirs[@]}"; do
			if [ -d "$directory/$dir" ]; then
				rm -rf "$directory/$dir"
			fi
			if [ "$directory" != "$start_directory" ] && [ -d "$start_directory/$dir" ]; then
				rm -rf "$start_directory/$dir"
			fi
		done
	elif [ "$bundle_archive_created" = true ]; then
		for dir in "${attachments_dirs[@]}"; do
			rm -rf "$directory/$dir"
		done
	elif [ "$directory" != "$start_directory" ]; then
		for dir in "${attachments_dirs[@]}"; do
			if [ -d "$directory/$dir" ]; then
				mv -f "$directory/$dir" "$start_directory"
			fi
		done
	fi
fi

if [ "$STRIP_IMAGE_LINKS" = true ]; then
	strip_image_links_from_md "$md_target"
fi

if [ "$PRECLEAN_COPY" = true ]; then
	preclean_target="${md_target%.md}_preclean.md"
	cp -f "$md_target" "$preclean_target"
	echo "Saved pre-clean copy: $(basename "$preclean_target")"
fi

if [ "$CLEAN_MARKDOWN" = true ]; then
	clean_markdown_with_llm "$md_target"
fi

if [ "${#chunk_archives[@]}" -gt 0 ]; then
	for archive in "${chunk_archives[@]}"; do
		if [ -f "$archive" ]; then
			rm -f "$archive"
		fi
	done
fi

if [ -n "$full_archive" ]; then
	full_archive_path="$directory/$(basename "$full_archive")"
	if [ -f "$full_archive_path" ]; then
		rm -f "$full_archive_path"
	fi
fi

# Deactivate the virtual environment and return to the directory which was the current directory when the script started
deactivate
cd "$start_directory" || exit
echo "Output markdown: $(basename "$md_target")"
if [ "$bundle_archive_created" = true ]; then
	if [ -n "$bundle_archive_name" ] && [ -f "$bundle_archive_name" ]; then
		echo "Output archive: $bundle_archive_name"
		echo "Note: Extract the archive in this directory for images to display properly."
	else
		echo "Warning: Attachment archive was created but is not in the current directory."
	fi
fi
end_time=$(date +%s)
elapsed_seconds=$((end_time - start_time))
elapsed_formatted=$(format_duration "$elapsed_seconds")
echo "Total time: $elapsed_formatted"
if [ -n "$page_count" ]; then
	per_page_seconds=$(awk -v total="$elapsed_seconds" -v pages="$page_count" 'BEGIN { if (pages > 0) printf "%.2f", total / pages; else print "" }')
	if [ -n "$per_page_seconds" ]; then
		echo "Time per page: ${per_page_seconds}s"
	fi
fi
echo "Script completed."

# ----------------------------------------------
