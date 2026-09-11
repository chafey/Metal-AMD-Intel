// iokit-dump: walk the IORegistry from GPU-relevant roots and dump decoded
// properties for triage and for building the tables in
// docs/hardware/mpx-cards.md. See tools/iokit-dump/README.md.
//
// Default roots are AMD (vendor 0x1002) IOPCIDevices; --all widens to every
// IOPCIDevice. Numeric properties are printed as `decimal (0xhex)`; PCI id
// keys are conventionally hex; binary blobs are a length plus a short hex
// preview. Output is either an indented tree or JSON (one object per PCI
// root, children nested).

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define AMD_VENDOR_ID 0x1002u
#define MAX_DICT_ENTRIES 1024

typedef struct {
    bool all;         // don't filter PCI devices to AMD vendor
    bool json;        // JSON output instead of an indented tree
    const char *name; // only dump subtrees containing a node name substring
    const char *key;  // only print properties whose name contains this
    int blob_preview; // bytes of binary properties to hexdump
} options_t;

static options_t opts = {false, false, NULL, NULL, 16};

// ---------------------------------------------------------------------------
// Small CF helpers
// ---------------------------------------------------------------------------

static bool cf_number_get(CFTypeRef value, uint64_t *out) {
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID()) return false;
    return CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, out);
}

static bool cf_to_cstr(CFStringRef str, char *buf, CFIndex size) {
    return str && CFStringGetCString(str, buf, size, kCFStringEncodingUTF8);
}

static bool key_wanted(const char *key) {
    return opts.key == NULL || strstr(key, opts.key) != NULL;
}

// Read a PCI-style numeric property. IOKit stores these as raw little-endian
// Data blobs (e.g. vendor-id <00021000> == 0x1002); some drivers publish
// OSNumber instead. Handle both.
static bool read_numeric_property(io_registry_entry_t entry, const char *key,
                                  uint64_t *out) {
    CFStringRef cfkey = CFStringCreateWithCString(kCFAllocatorDefault, key,
                                                  kCFStringEncodingUTF8);
    if (!cfkey) return false;
    CFTypeRef value = IORegistryEntryCreateCFProperty(
        entry, cfkey, kCFAllocatorDefault, 0);
    CFRelease(cfkey);
    if (!value) return false;
    bool ok = false;
    if (CFGetTypeID(value) == CFDataGetTypeID()) {
        CFDataRef data = (CFDataRef)value;
        CFIndex len = CFDataGetLength(data);
        if (len >= 1 && len <= 8) {
            const UInt8 *bytes = CFDataGetBytePtr(data);
            uint64_t v = 0;
            for (CFIndex i = 0; i < len; i++) v |= (uint64_t)bytes[i] << (8 * i);
            *out = v;
            ok = true;
        }
    } else {
        ok = cf_number_get(value, out);
    }
    CFRelease(value);
    return ok;
}

static void indent(int depth) {
    for (int i = 0; i < depth; i++) fputs("  ", stdout);
}

static void entry_name(io_registry_entry_t entry, char *buf, size_t size) {
    if (IORegistryEntryGetName(entry, buf) != KERN_SUCCESS)
        snprintf(buf, size, "?");
}

// ---------------------------------------------------------------------------
// Text (tree) output
// ---------------------------------------------------------------------------

static void dump_value_text(CFTypeRef value, int depth);

static bool key_is_pci_id(const char *key) {
    static const char *ids[] = {
        "vendor-id", "device-id", "revision-id", "subsystem-vendor-id",
        "subsystem-id", "class-code", "prog-spec", "header-type",
    };
    for (size_t i = 0; i < sizeof ids / sizeof *ids; i++) {
        if (strcmp(key, ids[i]) == 0) return true;
    }
    return false;
}

// For PCI id keys stored as LE Data blobs, append the decoded value next to
// the raw rendering (numbers already print as hex, so skip those).
static void print_pci_id_note(CFTypeRef value) {
    if (CFGetTypeID(value) != CFDataGetTypeID()) return;
    CFDataRef data = (CFDataRef)value;
    CFIndex len = CFDataGetLength(data);
    if (len < 1 || len > 8) return;
    const UInt8 *bytes = CFDataGetBytePtr(data);
    uint64_t n = 0;
    for (CFIndex i = 0; i < len; i++) n |= (uint64_t)bytes[i] << (8 * i);
    printf("   # little-endian: 0x%llx", (unsigned long long)n);
}

static void dump_data_text(CFDataRef data) {
    size_t len = (size_t)CFDataGetLength(data);
    const UInt8 *bytes = CFDataGetBytePtr(data);
    size_t show = len < (size_t)opts.blob_preview ? len : (size_t)opts.blob_preview;
    printf("<%zu bytes:", len);
    for (size_t i = 0; i < show; i++) printf(" %02x", bytes[i]);
    printf("%s>", len > show ? " ..." : "");
}

static void dump_dict_text(CFDictionaryRef dict, int depth) {
    printf("{\n");
    CFIndex total = CFDictionaryGetCount(dict);
    const void *keys[MAX_DICT_ENTRIES], *vals[MAX_DICT_ENTRIES];
    if (total > MAX_DICT_ENTRIES) total = MAX_DICT_ENTRIES;
    CFDictionaryGetKeysAndValues(dict, keys, vals);
    for (CFIndex i = 0; i < total; i++) {
        char keybuf[256] = "";
        cf_to_cstr((CFStringRef)keys[i], keybuf, sizeof keybuf);
        if (!*keybuf || !key_wanted(keybuf)) continue;
        indent(depth + 1);
        printf("%s = ", keybuf);
        dump_value_text((CFTypeRef)vals[i], depth + 1);
        if (key_is_pci_id(keybuf))
            print_pci_id_note((CFTypeRef)vals[i]);
        putchar('\n');
    }
    indent(depth);
    putchar('}');
}

static void dump_value_text(CFTypeRef value, int depth) {
    CFTypeID type = CFGetTypeID(value);
    char buf[4096];
    if (type == CFStringGetTypeID()) {
        if (cf_to_cstr((CFStringRef)value, buf, sizeof buf))
            printf("\"%s\"", buf);
        else
            fputs("<non-utf8 string>", stdout);
    } else if (type == CFBooleanGetTypeID()) {
        fputs(CFBooleanGetValue((CFBooleanRef)value) ? "Yes" : "No", stdout);
    } else if (type == CFNumberGetTypeID()) {
        uint64_t n;
        if (cf_number_get(value, &n))
            printf("%llu (0x%llx)", (unsigned long long)n, (unsigned long long)n);
        else
            fputs("<number?>", stdout);
    } else if (type == CFDataGetTypeID()) {
        dump_data_text((CFDataRef)value);
    } else if (type == CFArrayGetTypeID()) {
        CFArrayRef array = (CFArrayRef)value;
        printf("[ %ld entries ]\n", (long)CFArrayGetCount(array));
        for (CFIndex i = 0; i < CFArrayGetCount(array); i++) {
            indent(depth + 1);
            dump_value_text((CFTypeRef)CFArrayGetValueAtIndex(array, i),
                            depth + 1);
            putchar('\n');
        }
    } else if (type == CFDictionaryGetTypeID()) {
        dump_dict_text((CFDictionaryRef)value, depth);
    } else {
        fputs("<unknown-type>", stdout);
    }
}

static void dump_subtree_text(io_registry_entry_t entry, int depth) {
    char name[256] = "?", cls[256] = "?";
    entry_name(entry, name, sizeof name);
    IOObjectGetClass(entry, cls);
    uint64_t entry_id = 0;
    IORegistryEntryGetRegistryEntryID(entry, &entry_id);
    indent(depth);
    printf("%s (%s) [id=0x%llx]\n", name, cls, (unsigned long long)entry_id);

    CFMutableDictionaryRef props = NULL;
    if (IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault,
                                          0) == KERN_SUCCESS &&
        props) {
        indent(depth + 1);
        dump_dict_text(props, depth + 1);
        putchar('\n');
        CFRelease(props);
    }

    io_iterator_t it;
    if (IORegistryEntryCreateIterator(entry, "IOService", 0, &it) ==
        KERN_SUCCESS) {
        io_service_t child;
        while ((child = IOIteratorNext(it))) {
            dump_subtree_text(child, depth + 1);
            IOObjectRelease(child);
        }
        IOObjectRelease(it);
    }
}

// ---------------------------------------------------------------------------
// JSON output
// ---------------------------------------------------------------------------

static void json_escape(const char *s) {
    putchar('"');
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        switch (*p) {
        case '"': fputs("\\\"", stdout); break;
        case '\\': fputs("\\\\", stdout); break;
        case '\n': fputs("\\n", stdout); break;
        case '\r': fputs("\\r", stdout); break;
        case '\t': fputs("\\t", stdout); break;
        default:
            if (*p < 0x20) printf("\\u%04x", *p); else putchar(*p);
        }
    }
    putchar('"');
}

static void dump_value_json(CFTypeRef value);

static void dump_dict_json(CFDictionaryRef dict) {
    putchar('{');
    CFIndex total = CFDictionaryGetCount(dict);
    const void *keys[MAX_DICT_ENTRIES], *vals[MAX_DICT_ENTRIES];
    if (total > MAX_DICT_ENTRIES) total = MAX_DICT_ENTRIES;
    CFDictionaryGetKeysAndValues(dict, keys, vals);
    bool first = true;
    for (CFIndex i = 0; i < total; i++) {
        char keybuf[256] = "";
        if (!cf_to_cstr((CFStringRef)keys[i], keybuf, sizeof keybuf) ||
            !key_wanted(keybuf))
            continue;
        if (!first) putchar(',');
        first = false;
        json_escape(keybuf);
        putchar(':');
        dump_value_json((CFTypeRef)vals[i]);
    }
    putchar('}');
}

static void dump_value_json(CFTypeRef value) {
    CFTypeID type = CFGetTypeID(value);
    char buf[4096];
    if (type == CFDictionaryGetTypeID()) {
        dump_dict_json((CFDictionaryRef)value);
    } else if (type == CFArrayGetTypeID()) {
        putchar('[');
        CFArrayRef array = (CFArrayRef)value;
        for (CFIndex i = 0; i < CFArrayGetCount(array); i++) {
            if (i) putchar(',');
            dump_value_json((CFTypeRef)CFArrayGetValueAtIndex(array, i));
        }
        putchar(']');
    } else if (type == CFDataGetTypeID()) {
        CFDataRef data = (CFDataRef)value;
        size_t len = (size_t)CFDataGetLength(data);
        const UInt8 *bytes = CFDataGetBytePtr(data);
        size_t show = len < 32 ? len : 32;
        printf("{\"length\":%zu,\"hexPreview\":\"", len);
        for (size_t i = 0; i < show; i++) printf("%02x", bytes[i]);
        printf("\"}");
    } else if (type == CFStringGetTypeID()) {
        if (cf_to_cstr((CFStringRef)value, buf, sizeof buf))
            json_escape(buf);
        else
            fputs("\"<non-utf8 string>\"", stdout);
    } else if (type == CFBooleanGetTypeID()) {
        fputs(CFBooleanGetValue((CFBooleanRef)value) ? "true" : "false",
              stdout);
    } else if (type == CFNumberGetTypeID()) {
        uint64_t n;
        if (cf_number_get(value, &n))
            printf("%llu", (unsigned long long)n);
        else
            fputs("null", stdout);
    } else {
        fputs("\"<unknown-type>\"", stdout);
    }
}

static void dump_subtree_json(io_registry_entry_t entry) {
    char name[256] = "?", cls[256] = "?";
    entry_name(entry, name, sizeof name);
    IOObjectGetClass(entry, cls);
    uint64_t entry_id = 0;
    IORegistryEntryGetRegistryEntryID(entry, &entry_id);

    printf("{\"name\":");
    json_escape(name);
    printf(",\"class\":");
    json_escape(cls);
    printf(",\"registryEntryID\":%llu", (unsigned long long)entry_id);

    printf(",\"properties\":");
    CFMutableDictionaryRef props = NULL;
    if (IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault,
                                          0) == KERN_SUCCESS &&
        props) {
        dump_dict_json(props);
        CFRelease(props);
    } else {
        fputs("{}", stdout);
    }

    printf(",\"children\":[");
    io_iterator_t it;
    bool first = true;
    if (IORegistryEntryCreateIterator(entry, "IOService", 0, &it) ==
        KERN_SUCCESS) {
        io_service_t child;
        while ((child = IOIteratorNext(it))) {
            if (!first) putchar(',');
            first = false;
            dump_subtree_json(child);
            IOObjectRelease(child);
        }
        IOObjectRelease(it);
    }
    printf("]}");
}

// ---------------------------------------------------------------------------
// Root selection
// ---------------------------------------------------------------------------

static bool subtree_has_name(io_registry_entry_t entry, const char *needle) {
    io_iterator_t it;
    bool found = false;
    if (IORegistryEntryCreateIterator(entry, "IOService",
                                      kIORegistryIterateRecursively,
                                      &it) == KERN_SUCCESS) {
        io_service_t node;
        while (!found && (node = IOIteratorNext(it))) {
            char name[256];
            entry_name(node, name, sizeof name);
            found = strstr(name, needle) != NULL;
            IOObjectRelease(node);
        }
        IOObjectRelease(it);
    }
    return found;
}

static void usage(const char *argv0) {
    fprintf(stderr,
            "usage: %s [--all] [--json] [--name <substr>] [--key <substr>]\n"
            "          [--blob <bytes>] [--help]\n"
            "\n"
            "Dumps GPU-relevant IORegistry subtrees (AMD IOPCIDevices by\n"
            "default) with decoded properties.\n"
            "  --all          include non-AMD PCI devices\n"
            "  --json         JSON output instead of an indented tree\n"
            "  --name <s>     only subtrees with a node name containing <s>\n"
            "  --key <s>      only properties whose name contains <s>\n"
            "  --blob <n>     hex-preview bytes for binary properties (16)\n",
            argv0);
}

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        const char *arg = argv[i];
        if (!strcmp(arg, "--all")) {
            opts.all = true;
        } else if (!strcmp(arg, "--json")) {
            opts.json = true;
        } else if (!strcmp(arg, "--name") && i + 1 < argc) {
            opts.name = argv[++i];
        } else if (!strcmp(arg, "--key") && i + 1 < argc) {
            opts.key = argv[++i];
        } else if (!strcmp(arg, "--blob") && i + 1 < argc) {
            opts.blob_preview = atoi(argv[++i]);
        } else if (!strcmp(arg, "--help") || !strcmp(arg, "-h")) {
            usage(argv[0]);
            return 0;
        } else {
            fprintf(stderr, "unknown argument: %s\n", arg);
            usage(argv[0]);
            return 2;
        }
    }

    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,
                                     IOServiceMatching("IOPCIDevice"),
                                     &it) != KERN_SUCCESS) {
        fprintf(stderr, "iokit-dump: cannot enumerate IOPCIDevices\n");
        return 1;
    }

    if (opts.json) fputs("{\"roots\":[", stdout);
    bool first = true;
    int dumped = 0;
    io_service_t service;
    while ((service = IOIteratorNext(it))) {
        uint64_t vendor_id = 0;
        read_numeric_property(service, "vendor-id", &vendor_id);
        if (!opts.all && vendor_id != AMD_VENDOR_ID) {
            IOObjectRelease(service);
            continue;
        }
        if (opts.name && !subtree_has_name(service, opts.name)) {
            IOObjectRelease(service);
            continue;
        }

        if (opts.json) {
            if (!first) putchar(',');
            first = false;
            dump_subtree_json(service);
        } else {
            char name[256] = "?";
            entry_name(service, name, sizeof name);
            printf("\n=== IOPCIDevice %s ===\n", name);
            dump_subtree_text(service, 0);
        }
        dumped++;
        IOObjectRelease(service);
    }
    IOObjectRelease(it);
    if (opts.json) fputs("]}\n", stdout);

    if (dumped == 0) {
        fprintf(stderr,
                "iokit-dump: no matching PCI devices found "
                "(pass --all to widen beyond AMD)\n");
        return 1;
    }
    return 0;
}
