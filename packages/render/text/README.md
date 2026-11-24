# `text` (`official.text`)

Embedded proportional TrueType font atlas (`FiraSans-Regular.ttf`), official Lucide icon atlas (`lucide.ttf`), and 8x8 ASCII bitmap fallback (`official.text`).

## Features

- **Anti-aliased proportional TTF text (`TtfAtlas`)**: Bakes embedded `FiraSans-Regular.ttf` (SIL Open Font License 1.1) via `stb_truetype` into a `512x512` RGBA8 atlas with proportional glyph advances (`measureText`, `emitTextQuads`).
- **Official Lucide Icons (`IconAtlas`)**: Bakes embedded `lucide.ttf` (ISC License) for all `graphics.IconKind` codepoints (`LUCIDE_ICON_CODEPOINTS`) with tight alpha-trimmed glyph bounds (`makeIconQuad`).
- **8x8 ASCII bitmap fallback (`FONT_8X8`)**: Zero-dependency `128x48` monochrome bitmap atlas for ASCII `32..126`.
- **No external runtime files**: All font assets are embedded at compile time (`@embedFile`) without requiring `SDL3_ttf`.
