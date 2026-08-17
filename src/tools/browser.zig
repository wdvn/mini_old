//! tools/browser.zig — Tool tự động hóa trình duyệt web.
//!
//! Sử dụng Python và Playwright để điều khiển trình duyệt.
//! Yêu cầu máy chủ phải cài đặt python3 và playwright (`pip install playwright`).
//!
//! Hỗ trợ các hành động cơ bản:
//! - goto: mở URL
//! - click: click vào selector
//! - type: gõ văn bản vào selector
//! - screenshot: chụp ảnh màn hình
//! - html: lấy nội dung HTML
//! - scroll: cuộn trang (direction, distance)
//! - drag_drop: kéo thả (selector, target_selector)
//! - exec: chạy JS (script)
//! - upload_file: upload file vào thẻ input type=file (selector, path)
//!
//! Hỗ trợ `profile_dir` (user-data-dir) để duy trì session/cookies.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");
const utils = @import("../utils.zig");
const bash = @import("bash.zig");

// Chạy một script Python lưu tạm thời
pub fn executeTool(alloc: Allocator, io: std.Io, input_json: []const u8) ![]u8 {
    const action = json.findString(input_json, "action") orelse "html";
    const url = json.findString(input_json, "url") orelse "";
    const selector = json.findString(input_json, "selector") orelse "";
    const text = json.findString(input_json, "text") orelse "";
    const profile_dir = json.findString(input_json, "profile_dir") orelse "";
    const path = json.findString(input_json, "path") orelse "/tmp/screenshot.png";
    const target_selector = json.findString(input_json, "target_selector") orelse "";
    const script = json.findString(input_json, "script") orelse "";
    const direction = json.findString(input_json, "direction") orelse "down";
    const distance = json.findString(input_json, "distance") orelse "500";

    // Escape chuỗi để tránh lỗi cú pháp Python
    const esc_action = try json.escape(alloc, action);
    defer alloc.free(esc_action);
    const esc_url = try json.escape(alloc, url);
    defer alloc.free(esc_url);
    const esc_selector = try json.escape(alloc, selector);
    defer alloc.free(esc_selector);
    const esc_text = try json.escape(alloc, text);
    defer alloc.free(esc_text);
    const esc_profile = try json.escape(alloc, profile_dir);
    defer alloc.free(esc_profile);
    const esc_path = try json.escape(alloc, path);
    defer alloc.free(esc_path);
    const esc_target = try json.escape(alloc, target_selector);
    defer alloc.free(esc_target);
    const esc_script = try json.escape(alloc, script);
    defer alloc.free(esc_script);
    const esc_direction = try json.escape(alloc, direction);
    defer alloc.free(esc_direction);
    const esc_distance = try json.escape(alloc, distance);
    defer alloc.free(esc_distance);
    
    // Khởi tạo JSON string cho params để truyền sang Python một cách an toàn
    var params_buf = utils.BufWriter.init(alloc);
    defer params_buf.deinit();
    try params_buf.print("{{\"action\":\"{s}\",\"url\":\"{s}\",\"selector\":\"{s}\",\"text\":\"{s}\",\"profile_dir\":\"{s}\",\"path\":\"{s}\",\"target_selector\":\"{s}\",\"script\":\"{s}\",\"direction\":\"{s}\",\"distance\":\"{s}\"}}", 
        .{ esc_action, esc_url, esc_selector, esc_text, esc_profile, esc_path, esc_target, esc_script, esc_direction, esc_distance });
    const params_json = params_buf.list.items;

    // Python script
    const py_script = 
        \\import sys, json
        \\try:
        \\    from playwright.sync_api import sync_playwright
        \\except ImportError:
        \\    print("Lỗi: Không tìm thấy thư viện Playwright. Vui lòng chạy: pip install playwright && playwright install chromium")
        \\    sys.exit(1)
        \\
        \\def main():
        \\    try:
        \\        params = json.loads(sys.argv[1])
        \\    except Exception as e:
        \\        print("Lỗi parse params:", e)
        \\        sys.exit(1)
        \\
        \\    action = params.get("action", "")
        \\    url = params.get("url", "")
        \\    selector = params.get("selector", "")
        \\    text = params.get("text", "")
        \\    profile_dir = params.get("profile_dir", "")
        \\    path = params.get("path", "")
        \\    target_selector = params.get("target_selector", "")
        \\    script = params.get("script", "")
        \\    direction = params.get("direction", "down")
        \\    distance = params.get("distance", "500")
        \\
        \\    with sync_playwright() as p:
        \\        if profile_dir:
        \\            browser = p.chromium.launch_persistent_context(user_data_dir=profile_dir, headless=True)
        \\            page = browser.pages[0] if browser.pages else browser.new_page()
        \\        else:
        \\            browser = p.chromium.launch(headless=True)
        \\            page = browser.new_page()
        \\        
        \\        if url:
        \\            try:
        \\                page.goto(url, timeout=30000)
        \\            except Exception as e:
        \\                print(f"Lỗi khi tải trang: {e}")
        \\
        \\        try:
        \\            if action == 'click' and selector:
        \\                page.locator(selector).click(timeout=10000)
        \\                print("Đã click vào", selector)
        \\            elif action == 'type' and selector:
        \\                page.locator(selector).fill(text, timeout=10000)
        \\                print("Đã gõ văn bản vào", selector)
        \\            elif action == 'screenshot':
        \\                page.screenshot(path=path, full_page=True)
        \\                print("Đã lưu ảnh màn hình tại", path)
        \\            elif action == 'html':
        \\                pass
        \\            elif action == 'goto':
        \\                pass
        \\            elif action == 'scroll':
        \\                dist = int(distance) if distance.isdigit() else 500
        \\                sign = -1 if direction == 'up' else 1
        \\                page.evaluate(f"window.scrollBy(0, {sign * dist})")
        \\                print(f"Đã cuộn trang {direction} {dist}px")
        \\            elif action == 'drag_drop' and selector and target_selector:
        \\                page.drag_and_drop(selector, target_selector, timeout=10000)
        \\                print(f"Đã kéo {selector} thả vào {target_selector}")
        \\            elif action == 'exec' and script:
        \\                res = page.evaluate(script)
        \\                print(f"Kết quả thực thi JS:\n{res}")
        \\            elif action == 'upload_file' and selector and path:
        \\                page.locator(selector).set_input_files(path, timeout=10000)
        \\                print(f"Đã tải file {path} lên selector {selector}")
        \\            else:
        \\                print(f"Hành động không xác định hoặc thiếu tham số: {action}")
        \\        except Exception as e:
        \\            print(f"Lỗi khi thực hiện hành động '{action}': {e}")
        \\        
        \\        if action == 'html' or action == 'goto':
        \\            print(page.content())
        \\            
        \\        browser.close()
        \\
        \\if __name__ == '__main__':
        \\    main()
    ;

    // Ghi script tạm ra file
    const script_path = "/tmp/mini_browser_skill.py";
    var file = try std.Io.Dir.cwd().createFile(io, script_path, .{ .truncate = true });
    try file.writeStreamingAll(io, py_script);
    file.close(io);

    // Chạy python script
    var cmd_buf = utils.BufWriter.init(alloc);
    defer cmd_buf.deinit();
    // Wrap sys.argv[1] trong dấu nháy đơn. Vì JSON string của ta không chứa nháy đơn, nên an toàn.
    try cmd_buf.print("python3 {s} '{s}'", .{ script_path, params_json });
    
    // Tạo mảng byte array với input command
    var input_json_bash = utils.BufWriter.init(alloc);
    defer input_json_bash.deinit();
    try input_json_bash.print("{{\"command\":\"{s}\"}}", .{cmd_buf.list.items});

    // Gọi executeTool của bash.zig (nó đã handle stderr, timeout, etc.)
    return bash.executeTool(alloc, io, input_json_bash.list.items);
}
