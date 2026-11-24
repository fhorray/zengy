# `text` (`official.text`)

Embedded 8x8 ASCII bitmap font atlas and text measurement package (`official.text`).

## Features

- **Zero external font dependencies**: Ships an embedded 8x8 ASCII (`32..126`) bitmap atlas (`128x48` pixels, 16x6 grid) without requiring `SDL3_ttf` or external `.ttf` files.
- **Layout & GPU emission**: Provides glyph UV lookup, text bounding measurement, and quad emission for GPU text rendering.
