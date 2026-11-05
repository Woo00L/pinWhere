#!/usr/bin/env python3
"""为锁定版本添加单窗、身份校验的层级命令；不改上游通用命令。"""
import pathlib
import sys

source = pathlib.Path(sys.argv[1]) / "src/message.c"
text = source.read_text()
marker = "        } else if (token_equals(command, COMMAND_WINDOW_SUB_LAYER)) {"
patch = '''        } else if (token_equals(command, "--pinwhere-layer")) {
            struct token value = get_token(&message);
            int expected_pid = 0;
            double expected_birth = 0;
            unsigned long long expected_generation = 0;
            char layer_name[16] = {0};
            int owner_connection = 0;
            pid_t actual_pid = 0;
            int layer = -1;
            if (sscanf(value.text, "%d:%lf:%llu:%15s", &expected_pid, &expected_birth, &expected_generation, layer_name) == 4) {
                if (strcmp(layer_name, "above") == 0) layer = LAYER_ABOVE;
                if (strcmp(layer_name, "normal") == 0) layer = LAYER_NORMAL;
            }
            NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:expected_pid];
            double actual_birth = app.launchDate.timeIntervalSince1970;
            if (!acting_window || layer < 0 || expected_pid <= 0 || expected_birth <= 0 ||
                acting_window->application->pid != expected_pid || acting_window->pinwhere_generation != expected_generation || !app || !app.launchDate ||
                fabs(actual_birth - expected_birth) >= 0.001 ||
                SLSGetWindowOwner(g_connection, acting_window->id, &owner_connection) != kCGErrorSuccess ||
                SLSConnectionGetPID(owner_connection, &actual_pid) != kCGErrorSuccess || actual_pid != expected_pid) {
                daemon_fail(rsp, "pinwhere: window identity changed or invalid request.\\n");
            } else if (!scripting_addition_pinwhere_set_layer(acting_window->id, expected_pid, expected_birth, layer)) {
                daemon_fail(rsp, "pinwhere: scripting addition did not accept window layer request.\\n");
            } else {
                acting_window->layer = layer;
            }
'''
if text.count(marker) != 1 or 'token_equals(command, "--pinwhere-layer")' in text:
    raise SystemExit("后端源码与预期不符，停止补丁")
source.write_text(text.replace(marker, patch + marker, 1))

# 客户端与后台使用独立 socket/lock，不能接入用户的其他 yabai 实例。
daemon = pathlib.Path(sys.argv[1]) / "src/yabai.c"
text = daemon.read_text()
for old, new in [("/tmp/yabai_%s.socket", "/tmp/pinwhere-yabai_%s.socket"),
                 ("/tmp/yabai_%s.lock", "/tmp/pinwhere-yabai_%s.lock")]:
    if text.count(old) != 1:
        raise SystemExit("后台命名空间与预期不符")
    text = text.replace(old, new)
mouse_start = '''    if (!mouse_handler_begin(&g_mouse_state, MOUSE_EVENT_MASK)) {
        error("yabai: could not start mouse handler! abort..\\n");
    }
'''
if text.count(mouse_start) != 1:
    raise SystemExit("后端鼠标启动路径与预期不符")
text = text.replace(mouse_start, "    // PinWhere uses its own explicit pin handle; no global mouse event tap.\n", 1)
daemon.write_text(text)

root = pathlib.Path(sys.argv[1])
header = root / "src/window.h"
text = header.read_text().replace("    uint32_t *volatile id_ptr;", "    uint64_t pinwhere_generation;\n    uint32_t *volatile id_ptr;", 1)
header.write_text(text)
window = root / "src/window.c"
text = window.read_text().replace("    window->id = window_id;", "    window->id = window_id;\n    window->pinwhere_generation = mach_absolute_time();", 1)
start = text.index("void window_serialize(")
head, body = text[:start], text[start:]
marker = "    if (flags & WINDOW_PROPERTY_PID) {"
body = body.replace(marker, '''    if (did_output) fprintf(rsp, ",\\n");
    fprintf(rsp, "\\t\\\"pinwhere-generation\\\":%llu", (unsigned long long)window->pinwhere_generation);
    did_output = true;

''' + marker, 1)
window.write_text(head + body)

# 独立 Dock 扩展、版本和 socket，不覆盖其他 yabai 的扩展。
for relative in ["src/yabai.c", "src/osax/common.h", "src/sa.m", "src/osax/loader.m"]:
    path = root / relative
    text = path.read_text().replace("/tmp/yabai-sa_%s.socket", "/tmp/pinwhere-sa_%s.socket")
    text = text.replace("/Library/ScriptingAdditions/yabai.osax", "/Library/ScriptingAdditions/PinWhere.osax")
    text = text.replace("com.asmvik.yabai-osax", "cn.pinwhere.osax").replace("com.asmvik.yabai-sa", "cn.pinwhere.layer-sa")
    if relative.endswith("common.h"):
        text = text.replace('"2.1.34"', '"2.1.34-pinwhere.1"')
        text = text.replace("    SA_OPCODE_HANDSHAKE", "    SA_OPCODE_PINWHERE_LAYER = 0x14,\n    SA_OPCODE_HANDSHAKE", 1)
    path.write_text(text)

sa_header = root / "src/sa.h"
sa_header.write_text(sa_header.read_text().replace("bool scripting_addition_set_layer", "bool scripting_addition_pinwhere_set_layer(uint32_t wid, pid_t expected_pid, double expected_birth, int layer);\nbool scripting_addition_set_layer", 1))
sa = root / "src/sa.m"
sa.write_text(sa.read_text().replace("bool scripting_addition_set_layer(uint32_t wid, int layer)", '''
bool scripting_addition_pinwhere_set_layer(uint32_t wid, pid_t expected_pid, double expected_birth, int layer)
{
    sa_payload_init();
    pack(wid);
    pack(expected_pid);
    pack(expected_birth);
    pack(layer);
    return sa_payload_send(SA_OPCODE_PINWHERE_LAYER);
}
bool scripting_addition_set_layer(uint32_t wid, int layer)''', 1))
payload = root / "src/osax/payload.m"
text = payload.read_text().replace("#include <Foundation/Foundation.h>", "#include <AppKit/AppKit.h>\nextern CGError SLSConnectionGetPID(int cid, pid_t *pid);", 1)
text = text.replace("    case SA_OPCODE_HANDSHAKE: {", '''    case SA_OPCODE_PINWHERE_LAYER: {
        uint32_t wid;
        pid_t expected_pid;
        double expected_birth;
        int layer;
        unpack(wid);
        unpack(expected_pid);
        unpack(expected_birth);
        unpack(layer);
        int owner = 0;
        pid_t actual_pid = 0;
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:expected_pid];
        if (wid && expected_pid > 0 && app && app.launchDate &&
            fabs(app.launchDate.timeIntervalSince1970 - expected_birth) < 0.001 &&
            (layer == kCGFloatingWindowLevelKey || layer == kCGNormalWindowLevelKey) &&
            SLSGetWindowOwner(SLSMainConnectionID(), wid, &owner) == kCGErrorSuccess &&
            SLSConnectionGetPID(owner, &actual_pid) == kCGErrorSuccess && actual_pid == expected_pid) {
            SLSSetWindowSubLevel(SLSMainConnectionID(), wid, CGWindowLevelForKey(layer));
        }
    } break;
    case SA_OPCODE_HANDSHAKE: {''', 1)
payload.write_text(text)
makefile = root / "makefile"
makefile.write_text(makefile.read_text().replace("-framework SkyLight -framework Foundation -framework Carbon", "-framework SkyLight -framework AppKit -framework Carbon", 1))
