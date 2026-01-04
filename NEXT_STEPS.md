# NEXT_STEPS

This guide outlines best practices for positioning the `pdftomd.sh` wrapper relative to the upstream Marker repository and contributing the work back to the community.

## Goal

- Keep local wrapper enhancements stable and maintainable.
- Minimize merge conflicts with upstream Marker changes.
- Provide a clear contribution path (PR or separate repo) depending on how the upstream maintainers want to receive the work.

## Recommended path (default): Fork + PR

This is the standard open-source contribution workflow and keeps the wrapper changes close to Marker while still reviewable.

1. **Fork the upstream repo**
   - Create a fork on GitHub (e.g., `yourname/marker`).
   - Add remotes locally:
     ```shell
     git remote add upstream https://github.com/VikParuchuri/marker.git
     git remote add origin https://github.com/yourname/marker.git
     ```

2. **Create a feature branch**
   ```shell
   git checkout -b pdftomd-wrapper
   ```

3. **Keep changes scoped and documented**
   - Ensure `pdftomd.sh`, `README.md`, `AGENTS.md`, and `NEXT_STEPS.md` are clear and well-commented.
   - Avoid modifying core Marker logic unless necessary.

4. **Validate behavior**
   - Run a smoke test:
     ```shell
     ./pdftomd.sh -e /path/to/small.pdf
     ```
   - If GPU is present, run with default settings and confirm torch installs (if needed).

5. **Commit changes**
   ```shell
   git add pdftomd.sh README.md AGENTS.md NEXT_STEPS.md
   git commit -m "Add robust pdftomd.sh wrapper and docs"
   ```

6. **Rebase onto upstream main before opening PR**
   ```shell
   git fetch upstream
   git rebase upstream/main
   ```

7. **Push and open PR**
   ```shell
   git push origin pdftomd-wrapper
   ```
   - Open a PR to `VikParuchuri/marker:main`.
   - Provide a short summary and include usage examples.

## Alternative path: Separate wrapper repo

If upstream maintainers prefer to keep Marker minimal, host the wrapper separately.

1. **Create a new repo** (e.g., `marker-wrapper` or `pdftomd-wrapper`).
2. **Add Marker as a submodule or dependency**
   - Submodule option:
     ```shell
     git submodule add https://github.com/VikParuchuri/marker.git vendor/marker
     ```
   - Dependency option: install Marker via `pip install marker-pdf` and document required version.
3. **Copy `pdftomd.sh` and docs** into the wrapper repo.
4. **Add a pinned Marker version** in docs or a `requirements.txt`.
5. **Tag releases** for compatibility with upstream Marker versions.

## Branch strategy for long-term maintenance

- Maintain a long-lived `pdftomd-wrapper` branch in your fork.
- Periodically merge/rebase upstream changes into that branch:
  ```shell
  git fetch upstream
  git checkout pdftomd-wrapper
  git rebase upstream/main
  ```
- Resolve conflicts in `pdftomd.sh` and `README.md` only.

## Contribution checklist

- [ ] Wrapper runs with `-e` and without `-v` (quiet mode).
- [ ] GPU detection and auto-install work on NVIDIA systems.
- [ ] CPU override works with `-c`.
- [ ] `README.md` is wrapper-first; Marker details are in appendix.
- [ ] `AGENTS.md` captures gotchas and operational notes.
- [ ] `NEXT_STEPS.md` explains contribution path.

## Suggested PR notes

- Explain why the wrapper exists (batch conversion, output consolidation, GPU handling).
- Highlight that it does not change core Marker code paths.
- Note that it is optional for users; Marker CLI still works as-is.

