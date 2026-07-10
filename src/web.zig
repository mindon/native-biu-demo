const std = @import("std");
const native_sdk = @import("native_sdk");
const runner = @import("runner");

const appzon = runner.app_manifest;
const frontend = .{
    .dist = appzon.frontend.dist,
    .entry = appzon.frontend.entry,
    .origin = "zero://app",
    .spa_fallback = appzon.frontend.spa_fallback,
};

pub const ViewOptions = struct {
    label: []const u8 = "",
    title: []const u8 = "web",
    url: []const u8,
    width: f32 = 640,
    height: f32 = 480,
    restore_state: bool = false,
};

const main_webview_label = "web";
const max_title_scan_bytes = 64 * 1024;

pub fn open(runtime: *native_sdk.Runtime, options: ViewOptions) anyerror!native_sdk.ShellWindow {
    try closeWindowByLabel(runtime, options.label);

    if (options.url.len == 0) return error.InvalidWindowOptions;
    const resolved_url = options.url;

    const views = [_]native_sdk.ShellView{
        .{ .label = main_webview_label, .kind = .webview, .url = resolved_url, .fill = true },
    };
    const window: native_sdk.ShellWindow = .{
        .label = if (options.label.len == 0) options.title else options.label,
        .title = options.title,
        .width = options.width,
        .height = options.height,
        .restore_state = options.restore_state,
        .views = &views,
    };

    const info = try runtime.createShellWindow(window, sourceForUrl(resolved_url));
    try runtime.focusWindow(info.id);
    return window;
}

pub fn sourceForUrl(url: []const u8) native_sdk.WebViewSource {
    const resolved_url = if (url.len > 0) url else frontend.entry;
    if (appEntryFromUrl(resolved_url)) |entry| {
        return native_sdk.frontend.productionSource(.{
            .dist = frontend.dist,
            .entry = entry,
            .origin = frontend.origin,
            .spa_fallback = frontend.spa_fallback,
        });
    }
    return native_sdk.WebViewSource.url(resolved_url);
}

fn appEntryFromUrl(url: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, url, frontend.origin)) return null;
    if (url.len == frontend.origin.len) return frontend.entry;
    if (url[frontend.origin.len] != '/') return null;
    const entry = url[frontend.origin.len + 1 ..];
    if (entry.len == 0) return frontend.entry;
    if (!isSafeAssetEntry(entry)) return frontend.entry;
    return entry;
}

fn isSafeAssetEntry(entry: []const u8) bool {
    if (std.mem.indexOfScalar(u8, entry, '\\') != null) return false;
    if (std.mem.startsWith(u8, entry, "/")) return false;
    var parts = std.mem.splitScalar(u8, entry, '/');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

fn closeWindowByLabel(runtime: *native_sdk.Runtime, label: []const u8) anyerror!void {
    if (findWindowIdByLabel(runtime, label)) |window_id| {
        try runtime.closeWindow(window_id);
    }
}

fn findWindowIdByLabel(runtime: *native_sdk.Runtime, label: []const u8) ?native_sdk.WindowId {
    var windows: [native_sdk.platform.max_windows]native_sdk.WindowInfo = undefined;
    for (runtime.listWindows(&windows)) |info| {
        if (info.open and std.mem.eql(u8, info.label, label)) return info.id;
    }
    return null;
}
