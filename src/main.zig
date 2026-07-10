//! A minimal native-rendered Native SDK app: the view lives in
//! `app.native` (embedded into the binary, and watched for hot reload in
//! dev); this file is the logic: `Model`, `Msg`, and `update`.
//!
//! The remote page button navigates an in-app WebView pane. The local HTML
//! button opens `frontend/dist/index.html` in a separate WebView window via
//! the app's packaged `zero://app` asset origin.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const web = @import("web.zig");
const appzon = runner.app_manifest;

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_label = "main-canvas";
const window_width: f32 = 480;
const window_height: f32 = 600;

/// Local HTML is served by the app's `frontend` config (see `app.zon`):
/// `frontend.dist` is exposed under the `zero://app` asset origin, so the
/// webview loads it directly with no extra server.
const zero_app_url_prefix = "zero://app/";
const default_url = zero_app_url_prefix ++ appzon.frontend.entry;

/// Region the webview pane occupies (canvas-local; the canvas fills the window).
const webview_frame = geometry.RectF.init(0, 320, window_width, window_height - 320);

const app_permissions = [_][]const u8{
    native_sdk.security.permission_command,
    native_sdk.security.permission_view,
    native_sdk.security.permission_window,
};
const nav_origins = appzon.security.navigation.allowed_origins;

const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Counter canvas", .accessibility_label = "Counter", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
    // In-app webview pane: the model (via `web_panes`) drives its URL. The
    // `url` here is required by scene validation and is the page shown until
    // a button navigates elsewhere.
    .{ .label = "web", .kind = .webview, .parent = canvas_label, .fill = true, .url = default_url, .x = webview_frame.x, .y = webview_frame.y, .width = webview_frame.width, .height = webview_frame.height },
};
const shell_windows = [_]native_sdk.ShellWindow{
    .{
        .label = "main",
        .title = appzon.display_name,
        .width = window_width,
        .height = window_height,
        .restore_state = false,
        .views = &shell_views,
    },
};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ------------------------------------------------------------------ model

pub const Msg = union(enum) {
    increment,
    decrement,
    reset,
    open_webpage,
    open_hello,
};

pub const Model = struct {
    count: i64 = 0,
    panes_src: []const u8 = default_url,
    web_requested: bool = false,
    web_options: web.ViewOptions = .{ .url = default_url },
};

pub fn requestWeb(model: *Model, options: web.ViewOptions) void {
    model.web_options = options;
    model.web_requested = true;
}

pub fn takeWebOptions(model: *Model) web.ViewOptions {
    model.web_requested = false;
    return model.web_options;
}

pub fn update(model: *Model, msg: Msg) void {
    switch (msg) {
        .increment => model.count += 1,
        .decrement => model.count -= 1,
        .reset => {
            model.count = 0;
            model.web_requested = false;
        },
        .open_webpage => requestWeb(model, .{
            .url = "https://example.com",
            .title = "example",
        }),
        .open_hello => requestWeb(model, .{
            .url = default_url,
            .title = "hello",
        }),
    }
}

// ------------------------------------------------------------------- view

pub const AppUi = canvas.Ui(Msg);
pub const app_markup = @embedFile("app.native");

/// Drives the in-app webview pane: empty (no navigation) until a button is pressed.
fn panes(model: *const Model, out: []WebApp.WebViewPane) usize {
    if (model.panes_src.len == 0) return 0;
    out[0] = .{ .label = "web", .anchor = "web-pane", .url = model.panes_src };
    return 1;
}

// -------------------------------------------------------------------- app

const WebApp = native_sdk.UiApp(Model, Msg);

const AppWrapper = struct {
    app_state: *WebApp,
    inner: native_sdk.App,
    allocator: std.mem.Allocator,
    io: std.Io,

    fn app(self: *@This()) native_sdk.App {
        return .{
            .context = self,
            .name = self.inner.name,
            .source = self.inner.source,
            .source_fn = if (self.inner.source_fn != null) sourceFn else null,
            .scene_fn = if (self.inner.scene_fn != null) sceneFn else null,
            .start_fn = if (self.inner.start_fn != null) startFn else null,
            .event_fn = eventFn,
            .stop_fn = if (self.inner.stop_fn != null) stopFn else null,
            .replay_fn = if (self.inner.replay_fn != null) replayFn else null,
        };
    }

    fn sourceFn(context: *anyopaque) anyerror!native_sdk.WebViewSource {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.inner.webViewSource();
    }

    fn sceneFn(context: *anyopaque) anyerror!native_sdk.ShellConfig {
        const self: *@This() = @ptrCast(@alignCast(context));
        return (try self.inner.scene()).?;
    }

    fn startFn(context: *anyopaque, runtime: *native_sdk.Runtime) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        try self.inner.start(runtime);
    }

    fn eventFn(context: *anyopaque, runtime: *native_sdk.Runtime, event_value: native_sdk.Event) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        try self.inner.event(runtime, event_value);
        if (self.app_state.model.web_requested) {
            const options = takeWebOptions(&self.app_state.model);
            _ = try web.open(runtime, options);
        }
    }

    fn stopFn(context: *anyopaque, runtime: *native_sdk.Runtime) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        try self.inner.stop(runtime);
    }

    fn replayFn(context: *anyopaque, control: native_sdk.runtime.ReplayControl) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        try self.inner.replayControl(control);
    }
};

pub fn initialModel() Model {
    return .{};
}

pub fn main(init: std.process.Init) !void {
    // The app struct (and any real Model) is multi-MB: `create`
    // heap-allocates and constructs everything in place, so neither
    // ever rides the stack. Mutate `app_state.model` through the
    // pointer before running if boot state is not the default.
    const app_state = try WebApp.create(std.heap.page_allocator, .{
        .name = "nz",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update = update,
        .web_panes = panes,
        .markup = .{ .source = app_markup, .watch_path = "src/app.native", .io = init.io },
    });
    defer app_state.destroy();
    app_state.model = initialModel();
    // Wire the frontend asset source into the App value that the runner
    // consumes. This registers the `zero://app` origin so any webview in
    // the app can load local HTML from `frontend/dist/`.
    var ui_app = app_state.app();
    ui_app.source = native_sdk.frontend.productionSource(.{ .dist = appzon.frontend.dist });
    var app_wrapper = AppWrapper{ .app_state = app_state, .inner = ui_app, .allocator = std.heap.page_allocator, .io = init.io };
    const app = app_wrapper.app();

    try runner.runWithOptions(app, .{
        .app_name = appzon.name,
        .window_title = appzon.display_name,
        .bundle_id = appzon.id,
        .icon_path = appzon.icons[0],
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .restore_state = false,
        .js_window_api = false,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &nav_origins },
        },
    }, init);
}

test {
    _ = @import("tests.zig");
}
