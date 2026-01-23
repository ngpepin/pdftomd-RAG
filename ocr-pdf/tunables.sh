###################################
### Tunables (overridable via env) ###
BLANK_THRESHOLD="${BLANK_THRESHOLD:-0.995}"      # [0..1] mean ≥ threshold => blank
BLANK_DETECT_DPI="${BLANK_DETECT_DPI:-150}"      # DPI for blank detection renders
OCR_LANGS_DEFAULT="${OCR_LANGS_DEFAULT:-eng+fra+lat}"    # e.g., eng+fra
OCR_OPTIMIZE_LEVEL="${OCR_OPTIMIZE_LEVEL:-1}"    # 0..3 (3 = more aggressive)
SIZE_INFLATE_FACTOR="${SIZE_INFLATE_FACTOR:-1.75}" # trigger aggressive shrink if out/in > this
JPEG_QUALITY_LOSSY="${JPEG_QUALITY_LOSSY:-85}"   # 100..1
PNG_QUALITY_LOSSY="${PNG_QUALITY_LOSSY:-75}"     # 100..1
GS_PROFILE="${GS_PROFILE:-/ebook}"                 # Ghostscript profile: /screen /ebook /printer