# AGENTS.md

Guidance for agents working in this repository.

## Project Overview

- This is a Swift Package Manager macOS CLI named `game-art-generator`.
- The tool uses Apple `ImagePlayground.ImageCreator` to generate gameplay artwork from a text asset list.
- The main entrypoint is `Sources/GameArtGenerator/main.swift`.

## Repository Layout

- `Package.swift`: SwiftPM package definition.
- `Sources/GameArtGenerator/main.swift`: CLI parsing, asset validation, wrapper-app relaunch, foreground activation, and image generation.
- `README.md`: user-facing build and usage documentation. Keep it in sync with behavior changes.
- `LICENSE.md`: MIT license.
- `assets/example.txt`: valid sample asset list for a side scroller game.

## Runtime Constraints

- Image Playground requires the generator to run as a visible foreground macOS app.
- The top-level CLI relaunches itself through a reusable wrapper app at:
  `~/Library/Application Support/GameArtGenerator/Wrapper/GameArtGenerator.app`
- Do not invoke the wrapper executable inside `Contents/MacOS/` directly. Use the top-level CLI entrypoint instead.
- Headless, SSH, hidden, or background-only execution contexts can fail even when the code is otherwise correct.

## CLI Behavior To Preserve

- Required parameters:
  - `--assets` / `-a`
  - `--style` / `-s`
  - `--n` / `-n`
- Supported styles are currently `animation`, `illustration`, and `sketch`.
- The asset list format is one asset per line:
  `asset_path/asset_file_name, "description prompt"`
- Validation should continue to report descriptive line-numbered errors for malformed input.
- Description prompts must be wrapped in double quotes and stay limited to 100 characters inside the quotes.
- Duplicate asset paths should be rejected to prevent overwrites.
- Output should be written beside the assets file under a timestamped folder named:
  `yyyy-mm-dd_HH.MM_inputfile-art-for-review/`

## Build And Verification

- Debug build:
  `swift build`
- Release build:
  `swift build -c release`
- Typical manual run:
  `.build/release/game-art-generator --assets assets/example.txt --style illustration --n 2`
- When verifying generation behavior, use a real interactive macOS desktop session and keep the app frontmost while images are being created.

## Change Guidelines

- Prefer keeping the project dependency-free beyond Apple frameworks already in use.
- If you change CLI flags, validation rules, output layout, wrapper behavior, or runtime requirements, update `README.md` in the same change.
- Generated review folders and Swift build artifacts are intentionally ignored by `.gitignore`.
- Keep user-facing terminal errors clear and actionable; this tool is often run from the command line without additional UI.
