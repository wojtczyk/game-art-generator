# Game Art Generator

`game-art-generator` is a macOS command-line tool that uses Apple’s `ImagePlayground.ImageCreator` API to generate gameplay artwork from a text asset file.

## License

This project is licensed under the MIT License. See [LICENSE.md](LICENSE.md).

## Requirements

- macOS 15.4 or newer
- A Mac and system configuration that support Image Playground
- An Apple toolchain that includes the `ImagePlayground` framework

## Build

From the project root:

```bash
swift build -c release
```

The executable will be created at:

```text
.build/release/game-art-generator
```

## Assets File Format

Provide a UTF-8 text file where each asset uses this format on a single line:

```text
asset_path/asset_file_name, "description prompt"
```

Rules:

- `asset_path/asset_file_name` must be a relative path and must not include a file extension.
- The description prompt must be wrapped in double quotes.
- The description prompt text inside the quotes must be 100 characters or fewer.
- Blank lines are not allowed.
- Duplicate asset paths are rejected to avoid overwriting generated files.

Example:

```text
characters/hero/idle, "brave fox adventurer standing ready with satchel and scarf"
```

## Usage

Run the tool with:

```bash
swift run game-art-generator --assets assets/example.txt --style illustration --n 2
```

Or run the release build directly:

```bash
.build/release/game-art-generator --assets assets/example.txt --style illustration --n 2
```

Parameters:

- `--assets` or `-a`: path to the asset list file
- `--style` or `-s`: Image Playground style name
- `--n` or `-n`: number of images to create per asset

When you launch the raw executable from `swift run` or `.build/...`, the tool automatically relaunches itself from a reusable `.app` wrapper at `~/Library/Application Support/GameArtGenerator/Wrapper/GameArtGenerator.app` so macOS can treat it as a foreground app. Image Playground rejects hidden or background-only processes, so keep the generator app frontmost while images are being created. Progress, the active `prompt: "..."` line, and generated-file paths are streamed back to the original terminal while the wrapper app runs.

Supported styles:

- `animation`
- `illustration`
- `sketch`

## Output Layout

Each run creates a timestamped folder in the same directory as the assets file. The folder name uses the assets filename without its extension:

```text
yyyy-mm-dd_HH.MM_inputfile-art-for-review
```

If the assets file is `assets/example.txt`, the output folder will look like:

```text
assets/2026-04-19_11.45_example-art-for-review
```

Generated images are saved as PNG files under that folder, preserving the relative asset path. For example:

```text
assets/2026-04-19_11.45_example-art-for-review/
  characters/hero/idle-1.png
  characters/hero/idle-2.png
```

## Runtime Notes

- Use the top-level CLI entrypoint (`swift run game-art-generator ...` or `.build/release/game-art-generator ...`). Do not launch the wrapper app’s `Contents/MacOS/game-art-generator` executable directly, because that bypasses the LaunchServices foreground-app setup Image Playground requires.
- The launcher reuses `~/Library/Application Support/GameArtGenerator/Wrapper/GameArtGenerator.app` across runs, in addition to creating a new review output folder beside the assets file for each generation job.

## Validation Errors

If the assets file is malformed, the tool prints a descriptive error that includes:

- the invalid line number
- the reason the line failed validation
- the original line content

This lets you fix every reported line before retrying the generation run.
