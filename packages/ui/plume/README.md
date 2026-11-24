# `ui-plume` (`official.ui.plume`)

Opinionated dark-mode widget kit for **editors, inspectors, debug panels, and developer tooling** in `zengy`, inspired by `bevy_feathers`.

> [!NOTE]
> **`ui-plume` is built specifically for editor and tooling UIs**, where visual consistency, dense property inspection, keyboard efficiency, and crisp `0px` sharp-corner aesthetics matter more than bespoke game styling.
>
> For **in-game UIs** (HUDs, title screens, custom-styled menus), use a syntax-agnostic frontend such as `ui-markup` directly on top of `ui-core` and `ui-widgets`.

---

## Architecture & Core Concepts

`ui-plume` is layered cleanly over `ui-core` (`UiTree`, layout, clip/scroll, `DrawCommand` emission) and `ui-widgets` (`WidgetManager`, focus, pointer capture, shared `TextEditState` & `UndoHistory`).

- **Module & Capabilities**: `ui_plume.module()` registers `official.ui.plume` (`engine.ui.theme/1`), requiring `engine.ui.tree/1` and `engine.ui.widgets/1`. It inserts `UiTheme.initDark()` into `app.resources`.
- **Contextual Surface Hierarchy (`SurfaceLevel`)**:
  - `.deep` -> `.normal` -> `.higher` -> `.floating`
  - Containers (`pane`, `subPane`, `group`) step surface depth automatically so nested headers, cards, inputs, and overlays maintain clear contrast without manual color overrides.
- **Two-Pass Sync (`syncAll`)**:
  - After `mgr.update(...)`, call `ui_plume.syncAll(tree, mgr, th)` once per frame to keep stateful visuals in sync (menu item hover, list row selection, `NumberInput` editing vs drag state, `TextInput` focus/caret state, and `TreeView` ancestor dimming).
- **Shared Text Editing & Global Undo (`ui-widgets`)**:
  - Single-line `TextInput`, multiline `Textarea`, and `NumberInput` inline editing share `TextEditState` (`Ctrl+A`, `Ctrl+C`, `Ctrl+X`, `Ctrl+V`, `Ctrl+Z`, `Ctrl+Y`, `Ctrl+Shift+Z`, `Left`/`Right`/`Up`/`Down`/`Home`/`End`, `Backspace`/`Delete`).
  - `WidgetManager.undo_history` provides an extensible `UndoHistory` stack (`pushCustom` for editor-level commands + built-in widget undo/redo).
- **Headless-First**: Every widget and interaction works deterministically in headless tests without a window or GPU.

---

## Quick Start

### 1. Register Modules & Initialize Theme

```zig
const std = @import("std");
const ui_core = @import("ui_core");
const ui_widgets = @import("ui_widgets");
const ui_plume = @import("ui_plume");

// Inside your App setup / scene init:
var th = ui_plume.UiTheme.initDark();

// Root window / workspace pane (SurfaceLevel.deep -> .normal)
const root = try ui_plume.containers.pane(tree, null, &th, .{
    .direction = .row,
    .padding = 8,
    .gap = 8,
});
```

### 2. Per-Frame Update Loop

```zig
// 1. Feed input + layout to WidgetManager
mgr.update(tree, input_state, dt);

// 2. Synchronize Plume stateful styles (hover, selection, tree dimming, inputs)
ui_plume.syncAll(tree, mgr, &th);

// 3. Handle widget events
for (mgr.eventsSlice()) |ev| {
    switch (ev.payload) {
        .activate => |act| {
            // Button clicks, menu items, palette commands (act.tag)
            _ = act;
        },
        .value_changed => |val| {
            // Sliders, NumberInput, Checkbox, ToggleSwitch, Select, TextInput
            _ = val;
        },
        else => {},
    }
}

// 4. Advance time-based overlays (when used)
toast_host.update(tree, mgr, dt * 1000.0);
ui_plume.controls.overlays.syncSheetWithDt(tree, mgr, &sheet_state, dt);
```

---

## Component Guide

### Containers & Display (`ui_plume.containers`, `ui_plume.display`)

| Component | Purpose | Key APIs |
| --- | --- | --- |
| **Pane / SubPane / Group** | Nested surface hierarchy | `containers.pane`, `containers.subPane`, `containers.group` |
| **Card** | Structured container with header, body, footer | `containers.card` (returns `.root`, `.header`, `.content`, `.footer`) |
| **Heading / Label** | Styled typography | `display.heading`, `display.label` |
| **Separator** | Horizontal or vertical divider | `display.separator` |
| **Badge / Chip** | Status pills & removable filter tags | `display.badge`, `display.chip` |
| **Alert** | Semantic callouts (`.info`, `.success`, `.warning`, `.@"error"`) | `display.alert` |
| **ProgressBar & Spinner** | Determinate/indeterminate progress & loading indicator | `display.progressBar`, `display.setIndeterminateProgress`, `display.spinner`, `display.tickSpinner` |

```zig
const crd = try ui_plume.containers.card(tree, &th, parent_idx, .{
    .title = "Build Pipeline",
    .subtitle = "Status & quick actions",
    .level = .normal,
});
_ = try ui_plume.display.badge(tree, &th, crd.content, "v0.2.0", .accent, .higher);
_ = try ui_plume.display.alert(tree, &th, crd.content, .warning, "Warning", "Shader cache stale.", .higher);
```

### Buttons & Toggles (`ui_plume.controls.button`, `ui_plume.controls.toggles`)

- **Button**: Supports `.normal`, `.primary`, `.plain`, `.tool` variants, `RoundedCorners`, and official Lucide `IconKind` icons (`button.button`).
- **Checkbox / Radio / ToggleSwitch**: Bound to `WidgetManager` (`toggles.checkbox`, `toggles.radio`, `toggles.toggleSwitch`).
- **ToggleGroup**: Multi-select button bar (`toggles.toggleGroup`).
- **Accordion & Disclosure**: Collapsible sections (`toggles.accordion`, `toggles.disclosureToggle`).

```zig
const save_btn = try ui_plume.controls.button.button(tree, mgr, &th, parent_idx, .{
    .label = "Save",
    .icon = .check,
    .variant = .primary,
    .tag = "save_scene",
});
```

### Inputs (`ui_plume.controls.inputs`)

- **TextInput & Textarea**: Single-line (`inputs.textInput`) and multiline (`inputs.textarea`) inputs with caret rendering, text clipping/scrolling, and full `TextEditState` shortcuts.
- **Slider & RangeSlider**: Continuous slider (`inputs.slider`) and dual-thumb `[min, max]` range slider (`inputs.rangeSlider`), with arrow-key nudging when focused.
- **NumberInput & Vec3Input**: Drag-to-scrub numeric fields + click/double-click inline editing (`inputs.numberInput`, `inputs.vec3Input`).
- **Combobox**: Searchable dropdown combining a text filter with a selectable list (`inputs.combobox`).
- **KeybindInput**: Captures keyboard shortcuts + modifiers (`Ctrl`, `Shift`, `Alt`) (`inputs.keybindInput`).

```zig
const name_input = try ui_plume.controls.inputs.textInput(tree, mgr, &th, parent_idx, .{
    .initial_text = "Player",
    .placeholder = "Entity name...",
    .tag = "entity_name",
});
const notes = try ui_plume.controls.inputs.textarea(tree, mgr, &th, parent_idx, "Notes...", 72.0, 256, "notes", .higher);
const speed = try ui_plume.controls.inputs.numberInput(tree, mgr, &th, parent_idx, .{
    .value = 5.0,
    .min = 0.0,
    .max = 100.0,
    .step = 0.25,
    .tag = "move_speed",
});
```

### Overlays & Feedback (`ui_plume.controls.overlays`)

- **Select**: Dropdown selector with automatic scrolling and scrollbar when items exceed 6 rows (`overlays.select`, `overlays.syncSelect`).
- **Menu & ContextMenu**: Floating popup menus and right-click context menus (`overlays.menuTrigger`, `overlays.contextMenu`).
- **Tooltip**: Hover-delayed tooltip with automatic viewport flip (`overlays.tooltip`).
- **ToastHost**: Bottom-right stackable notifications with severity accent, optional quick-action button, Lucide close button, and auto-dismiss (`ToastHost.init`, `push`, `update`).
- **Dialog & AlertDialog**: Centered modal overlays supporting `Enter`/`Esc` and `dismiss_on_outside` (`overlays.dialog`, `overlays.alertDialog`).
- **Sheet / Drawer**: Edge-anchored sliding drawers (`left`, `right`, `bottom`) (`overlays.sheet`, `overlays.syncSheetWithDt`).
- **ListView & VirtualKeyboard**: Scrollable list (`overlays.listView`) and on-screen keyboard (`overlays.virtualKeyboard`).

```zig
var toast_host = try ui_plume.controls.overlays.ToastHost.init(tree);
try toast_host.push(tree, mgr, &th, .success, "Shader compiled", "Undo", "toast_undo", 3500.0);

const alert_dlg = try ui_plume.controls.overlays.alertDialog(
    tree,
    mgr,
    &th,
    "Delete Entity?",
    "This action cannot be undone.",
    "Delete",
    "confirm_delete",
    false, // initial visibility
);
_ = alert_dlg;
```

### Navigation & Data (`ui_plume.controls.navigation`, `ui_plume.controls.data`)

- **Menubar**: Top-level application menu bar with hover-switchable dropdowns (`navigation.menubar`, `navigation.menubarMenu`).
- **Breadcrumb**: Hierarchical path navigation (`navigation.breadcrumb`).
- **CommandPalette**: Fuzzy-searchable `Ctrl+K` action launcher (`navigation.commandPalette`).
- **Table / DataGrid**: Typed columns (`TableOptions`), sortable headers, row hover/selection, and vertical scroll (`data.table`).

```zig
const cols = [_]ui_plume.controls.data.TableColumn{
    .{ .title = "Entity", .width = 110 },
    .{ .title = "System", .width = 90 },
    .{ .title = "ms", .width = 48, .align_right = true },
};
const rows = [_][]const []const u8{
    &.{ "Player", "Physics", "0.42" },
    &.{ "Camera", "Render3D", "1.18" },
};
_ = try ui_plume.controls.data.table(tree, mgr, &th, parent_idx, &cols, &rows, .{
    .height = 140,
    .sortable = true,
}, "perf_table");
```

### Color Picker (`ui_plume.controls.color_picker`)

- **ColorSwatch**, **ColorSlider**, **ColorPlane**, **ColorWheel**, **ColorSwatchGrid** (24 persistent recent slots), and full **ColorInput** (Wheel / RGB / HSL modes + RGBA numeric inputs).

### Editor Tooling (`ui_plume.controls.tooling`)

- **TabStrip**, **SplitPane**, **DockPanel**, and **TreeView** (`tooling.treeItemEx` with `TreeItemOptions`, Lucide icons, and visibility eye toggle with ancestor dimming via `tooling.syncTreeRow`).

```zig
const player_row = try ui_plume.controls.tooling.treeItemEx(tree, mgr, &th, tree_root, "Player", .{
    .depth = 1,
    .expanded = true,
    .has_children = true,
    .icon = .sliders_horizontal,
    .show_visibility = true,
    .visible = true,
}, "node_player");
_ = player_row;
```

---

## Visual Showcase & Tests

Run the full interactive 4-column showcase (Inspector, Controls Gallery, Overlays, Table, and Scene Tree):

### 1. Register Modules & Initialize Theme

```zig
const std = @import("std");
const ui_core = @import("ui_core");
const ui_widgets = @import("ui_widgets");
const ui_plume = @import("ui_plume");

// Inside your App setup / scene init:
var th = ui_plume.UiTheme.initDark();

// Root window / workspace pane (SurfaceLevel.deep -> .normal)
const root = try ui_plume.containers.pane(tree, null, &th, .{
    .direction = .row,
    .padding = 8,
    .gap = 8,
});
```

### 2. Per-Frame Update Loop

```zig
// 1. Feed input + layout to WidgetManager
mgr.update(tree, input_state, dt);

// 2. Synchronize Plume stateful styles (hover, selection, tree dimming, inputs)
ui_plume.syncAll(tree, mgr, &th);

// 3. Handle widget events
for (mgr.eventsSlice()) |ev| {
    switch (ev.payload) {
        .activate => |act| {
            // Button clicks, menu items, palette commands (act.tag)
            _ = act;
        },
        .value_changed => |val| {
            // Sliders, NumberInput, Checkbox, ToggleSwitch, Select, TextInput
            _ = val;
        },
        else => {},
    }
}

// 4. Advance time-based overlays (when used)
toast_host.update(tree, mgr, dt * 1000.0);
ui_plume.controls.overlays.syncSheetWithDt(tree, mgr, &sheet_state, dt);
```

---

## Component Guide

### Containers & Display (`ui_plume.containers`, `ui_plume.display`)

| Component | Purpose | Key APIs |
| --- | --- | --- |
| **Pane / SubPane / Group** | Nested surface hierarchy | `containers.pane`, `containers.subPane`, `containers.group` |
| **Card** | Structured container with header, body, footer | `containers.card` (returns `.root`, `.header`, `.content`, `.footer`) |
| **Heading / Label** | Styled typography | `display.heading`, `display.label` |
| **Separator** | Horizontal or vertical divider | `display.separator` |
| **Badge / Chip** | Status pills & removable filter tags | `display.badge`, `display.chip` |
| **Alert** | Semantic callouts (`.info`, `.success`, `.warning`, `.@"error"`) | `display.alert` |
| **ProgressBar & Spinner** | Determinate/indeterminate progress & loading indicator | `display.progressBar`, `display.setIndeterminateProgress`, `display.spinner`, `display.tickSpinner` |

```zig
const crd = try ui_plume.containers.card(tree, &th, parent_idx, .{
    .title = "Build Pipeline",
    .subtitle = "Status & quick actions",
    .level = .normal,
});
_ = try ui_plume.display.badge(tree, &th, crd.content, "v0.2.0", .accent, .higher);
_ = try ui_plume.display.alert(tree, &th, crd.content, .warning, "Warning", "Shader cache stale.", .higher);
```

### Buttons & Toggles (`ui_plume.controls.button`, `ui_plume.controls.toggles`)

- **Button**: Supports `.normal`, `.primary`, `.plain`, `.tool` variants, `RoundedCorners`, and official Lucide `IconKind` icons (`button.button`).
- **Checkbox / Radio / ToggleSwitch**: Bound to `WidgetManager` (`toggles.checkbox`, `toggles.radio`, `toggles.toggleSwitch`).
- **ToggleGroup**: Multi-select button bar (`toggles.toggleGroup`).
- **Accordion & Disclosure**: Collapsible sections (`toggles.accordion`, `toggles.disclosureToggle`).

```zig
const save_btn = try ui_plume.controls.button.button(tree, mgr, &th, parent_idx, .{
    .label = "Save",
    .icon = .check,
    .variant = .primary,
    .tag = "save_scene",
});
```

### Inputs (`ui_plume.controls.inputs`)

- **TextInput & Textarea**: Single-line (`inputs.textInput`) and multiline (`inputs.textarea`) inputs with caret rendering, text clipping/scrolling, and full `TextEditState` shortcuts.
- **Slider & RangeSlider**: Continuous slider (`inputs.slider`) and dual-thumb `[min, max]` range slider (`inputs.rangeSlider`), with arrow-key nudging when focused.
- **NumberInput & Vec3Input**: Drag-to-scrub numeric fields + click/double-click inline editing (`inputs.numberInput`, `inputs.vec3Input`).
- **Combobox**: Searchable dropdown combining a text filter with a selectable list (`inputs.combobox`).
- **KeybindInput**: Captures keyboard shortcuts + modifiers (`Ctrl`, `Shift`, `Alt`) (`inputs.keybindInput`).

### Overlays & Feedback (`ui_plume.controls.overlays`)

- **Select**: Dropdown selector with automatic scrolling and scrollbar when items exceed 6 rows (`overlays.select`, `overlays.syncSelect`).
- **Menu & ContextMenu**: Floating popup menus and right-click context menus (`overlays.menuTrigger`, `overlays.contextMenu`).
- **Tooltip**: Hover-delayed tooltip with automatic viewport flip (`overlays.tooltip`).
- **ToastHost**: Bottom-right stackable notifications with severity accent, optional quick-action button, Lucide close button, and auto-dismiss (`ToastHost.init`, `push`, `update`).
- **Dialog & AlertDialog**: Centered modal overlays supporting `Enter`/`Esc` and `dismiss_on_outside` (`overlays.dialog`, `overlays.alertDialog`).
- **Sheet / Drawer**: Edge-anchored sliding drawers (`left`, `right`, `bottom`) (`overlays.sheet`, `overlays.syncSheetWithDt`).
- **ListView & VirtualKeyboard**: Scrollable list (`overlays.listView`) and on-screen keyboard (`overlays.virtualKeyboard`).

### Navigation & Data (`ui_plume.controls.navigation`, `ui_plume.controls.data`)

- **Menubar**: Top-level application menu bar with hover-switchable dropdowns (`navigation.menubar`, `navigation.menubarMenu`).
- **Breadcrumb**: Hierarchical path navigation (`navigation.breadcrumb`).
- **CommandPalette**: Fuzzy-searchable `Ctrl+K` action launcher (`navigation.commandPalette`).
- **Table / DataGrid**: Typed columns (`TableOptions`), sortable headers, row hover/selection, and vertical scroll (`data.table`).

### Color Picker (`ui_plume.controls.color_picker`)

- **ColorSwatch**, **ColorSlider**, **ColorPlane**, **ColorWheel**, **ColorSwatchGrid** (24 persistent recent slots), and full **ColorInput** (Wheel / RGB / HSL modes + RGBA numeric inputs).

### Editor Tooling (`ui_plume.controls.tooling`)

- **TabStrip**, **SplitPane**, **DockPanel**, and **TreeView** (`tooling.treeItemEx` with `TreeItemOptions`, Lucide icons, and visibility eye toggle with ancestor dimming via `tooling.syncTreeRow`).

---

## Visual Showcase & Tests

Run the full interactive 4-column showcase (Inspector, Controls Gallery, Overlays, Table, and Scene Tree):

```sh
zig build run-visual-plume
```

Source: [examples/visual-plume/main.zig](../../../examples/visual-plume/main.zig)

Run the headless test suite (including `ui-plume` widget and layout tests):

```sh
zig build test --summary all
```
