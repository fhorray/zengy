//! Default Module Bundle (`official.default_modules`).
//!
//! Provides an ergonomic, Bevy-inspired `registerDefaultModules(app)` helper
//! that composes the standard optional packages (`window`, `graphics`, `ui-core`,
//! `assets`, `scene`, `scripting-host`, `toml_format`, `json_format`) in one call
//! while keeping `src/core/` completely free of optional dependencies.

const engine = @import("engine");
const window = @import("window");
const graphics = @import("graphics");
const ui_core = @import("ui_core");
const assets = @import("assets");
const scene = @import("scene");
const scripting_host = @import("scripting_host");
const toml_format = @import("toml_format");
const json_format = @import("json_format");
const camera = @import("camera");
const input = @import("input");
const input_haptics = @import("input_haptics");
const state = @import("state");
const audio = @import("audio");

/// Registers the standard suite of optional engine modules on `app`.
pub fn registerDefaultModules(app: *engine.App) !void {
    try app.registerModule(window.module());
    try app.registerModule(graphics.module());
    try app.registerModule(ui_core.module());
    try app.registerModule(assets.module());
    try app.registerModule(scene.module());
    try app.registerModule(scripting_host.module());
    try app.registerModule(toml_format.module());
    try app.registerModule(json_format.module());
    try app.registerModule(camera.module());
    try app.registerModule(input.module());
    try app.registerModule(input_haptics.module());
    try app.registerModule(state.module());
    try app.registerModule(audio.module());
}
