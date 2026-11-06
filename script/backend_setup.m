// PinWhere 的首次设置入口。探测不修改系统；写操作必须由 App 内按钮触发管理员认证。
#include <IOKit/IOKitLib.h>

static NSString *pinwhere_saved_boot_arguments(void)
{
    io_registry_entry_t entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/options");
    if (!entry) return nil;
    CFTypeRef value = IORegistryEntryCreateCFProperty(entry, CFSTR("boot-args"), kCFAllocatorDefault, 0);
    IOObjectRelease(entry);
    if (!value) return @"";
    NSString *result = nil;
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        result = [NSString stringWithString:(NSString *)value];
    } else if (CFGetTypeID(value) == CFDataGetTypeID()) {
        NSData *data = (NSData *)value;
        result = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
        result = [result stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithRange:NSMakeRange(0, 1)]];
    }
    CFRelease(value);
    return result;
}

static bool pinwhere_has_boot_flag(NSString *arguments)
{
    return [[arguments componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
            containsObject:@"-arm64e_preview_abi"];
}

static bool pinwhere_extension_ready(void)
{
    struct passwd *pw = getpwuid(getuid());
    if (!pw) return false;
    snprintf(g_sa_socket_file, sizeof(g_sa_socket_file), SA_SOCKET_PATH_FMT, pw->pw_name);
    uint32_t attributes = 0;
    char version[SA_SOCKET_BUFF_LEN] = {0};
    return scripting_addition_request_handshake(version, &attributes) &&
           string_equals(version, OSAX_VERSION) &&
           (attributes & scripting_addition_required_attrib()) == scripting_addition_required_attrib();
}

static int pinwhere_setup_status(void)
{
    @autoreleasepool {
        uint32_t config = 0;
        bool config_known = csr_get_active_config(&config) == 0;
        bool boot_enabled = true;
#ifdef __arm64__
        boot_enabled = scripting_addition_is_arm64e_enabled();
#endif
        NSDictionary *status = @{
            @"schema": @1,
            @"sipCompatible": (config_known && scripting_addition_is_sip_friendly()) ? @YES : @NO,
            @"nvramProtectionDisabled": (config_known && (config & 0x40) != 0) ? @YES : @NO,
            @"bootArgumentEnabled": boot_enabled ? @YES : @NO,
            @"bootArgumentConfigured": pinwhere_has_boot_flag(pinwhere_saved_boot_arguments()) ? @YES : @NO,
            @"accessibilityGranted": AXIsProcessTrusted() ? @YES : @NO,
            @"extensionInstalled": scripting_addition_check() == 0 ? @YES : @NO,
            @"extensionReady": pinwhere_extension_ready() ? @YES : @NO
        };
        NSData *json = [NSJSONSerialization dataWithJSONObject:status options:0 error:nil];
        if (!json) return 1;
        fwrite(json.bytes, 1, json.length, stdout);
        fputc('\n', stdout);
        return 0;
    }
}

static int pinwhere_enable_boot_argument(void)
{
    @autoreleasepool {
        uint32_t config = 0;
        if (!is_root() || csr_get_active_config(&config) != 0 || !(config & 0x40)) return 1;
        NSString *previous = pinwhere_saved_boot_arguments();
        // 无法读取时绝不按空值覆盖，保留用户已有启动参数。
        if (!previous) return 1;
        if (pinwhere_has_boot_flag(previous)) return 0;
        NSString *updated = previous.length ? [previous stringByAppendingString:@" -arm64e_preview_abi"] : @"-arm64e_preview_abi";
        NSTask *task = [[[NSTask alloc] init] autorelease];
        task.executableURL = [NSURL fileURLWithPath:@"/usr/sbin/nvram"];
        task.arguments = @[[ @"boot-args=" stringByAppendingString:updated ]];
        if (![task launchAndReturnError:nil]) return 1;
        [task waitUntilExit];
        return task.terminationStatus;
    }
}

static int pinwhere_load_extension(void)
{
    if (!is_root()) return 1;
    // 安装可能重启 Dock。等待 Dock 恢复后再次加载，整个操作只触发一次管理员认证。
    for (int attempt = 0; attempt < 3; ++attempt) {
        int result = scripting_addition_load();
        if (result != 0) return result;
        usleep(1000000);
        char version[SA_SOCKET_BUFF_LEN] = {0};
        uint32_t attributes = 0;
        if (scripting_addition_set_socket_path() && scripting_addition_request_handshake(version, &attributes) &&
            string_equals(version, OSAX_VERSION) &&
            (attributes & scripting_addition_required_attrib()) == scripting_addition_required_attrib()) return 0;
        usleep(1000000);
    }
    return 1;
}

static int pinwhere_reload_extension(void)
{
    // 有恢复记录时只加载已匹配的现有文件，不重新安装或主动重启 Dock。
    if (!is_root() || !scripting_addition_is_sip_friendly() || scripting_addition_check() != 0) return 1;
    if (!mach_loader_inject_payload() || !scripting_addition_set_socket_path()) return 1;
    uint32_t attributes = 0;
    char version[SA_SOCKET_BUFF_LEN] = {0};
    return scripting_addition_request_handshake(version, &attributes) && string_equals(version, OSAX_VERSION) &&
           (attributes & scripting_addition_required_attrib()) == scripting_addition_required_attrib() ? 0 : 1;
}
