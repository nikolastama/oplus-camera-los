/*
 * camera.oemlayer.v2 session-tag wrapper (OnePlus Camera for LineageOS module).
 *
 * LineageOS's cameraserver forwards only declared session keys to the HAL. Infinity X's
 * cameraserver additionally stamps every session with the client package in the vendor tag
 * com.oplus.packageName; OnePlus's HAL (OemLayer + CHI) uses it to tell its own camera app from
 * third-party apps. Without it the OnePlus camera's session is configured as third-party (no ZSL
 * RAW queue), and its photo request then waits forever for a RAW frame.
 *
 * This library is loaded by libhardware in place of the OnePlus layer (same path,
 * /odm/lib64/hw/camera.oemlayer.v2.so). It pulls in the real layer (moved to
 * /odm/lib64/camera.oemlayer.v2.so, SONAME unchanged) as a dependency, exposes a byte copy of
 * its HMI with only common.methods->open replaced, and after a device opens redirects that
 * device's configure_streams. For sessions in OnePlus's custom operation modes (>= 0x8000, used
 * only by the OnePlus camera) it adds com.oplus.packageName = "com.oplus.camera" to the session
 * parameters if absent, then calls the original. Everything else is passed through untouched.
 */
#include <stddef.h>
#include <stdint.h>

/* ---- minimal libc / libdl / liblog / libcamera_metadata declarations ---- */
void *dlopen(const char *, int);
void *dlsym(void *, const char *);
void *memcpy(void *, const void *, size_t);
int strcmp(const char *, const char *);
int __android_log_print(int, const char *, const char *, ...);
#define RTLD_NOW 2
#define RTLD_NOLOAD 4
#define LOG_I 4
#define LOG_E 6
#define TAG "OplusCamLosWrap"

typedef struct camera_metadata camera_metadata_t;
typedef struct {
    size_t index;
    uint32_t tag;
    uint8_t type;
    size_t count;
    const void *data;
} camera_metadata_ro_entry_t;
camera_metadata_t *allocate_camera_metadata(size_t entry_capacity, size_t data_capacity);
void free_camera_metadata(camera_metadata_t *);
int append_camera_metadata(camera_metadata_t *dst, const camera_metadata_t *src);
int add_camera_metadata_entry(camera_metadata_t *, uint32_t tag, const void *data, size_t count);
int find_camera_metadata_ro_entry(const camera_metadata_t *, uint32_t tag, camera_metadata_ro_entry_t *);
size_t get_camera_metadata_entry_count(const camera_metadata_t *);
size_t get_camera_metadata_data_count(const camera_metadata_t *);
int get_camera_metadata_tag_type(uint32_t tag);
struct vendor_tag_ops;
int set_camera_metadata_vendor_ops(const struct vendor_tag_ops *);

/* ---- AOSP hardware / camera3 ABI (64-bit) ---- */
struct hw_module_t;
struct hw_device_t;
typedef struct hw_module_methods_t {
    int (*open)(const struct hw_module_t *, const char *id, struct hw_device_t **device);
} hw_module_methods_t;
typedef struct hw_module_t {
    uint32_t tag;
    uint16_t module_api_version;
    uint16_t hal_api_version;
    const char *id;
    const char *name;
    const char *author;
    hw_module_methods_t *methods;
    void *dso;
    uint64_t reserved[32 - 7];
} hw_module_t;
typedef struct hw_device_t {
    uint32_t tag;
    uint32_t version;
    struct hw_module_t *module;
    uint64_t reserved[12];
    int (*close)(struct hw_device_t *);
} hw_device_t;

typedef struct vendor_tag_ops {
    int (*get_tag_count)(const struct vendor_tag_ops *);
    void (*get_all_tags)(const struct vendor_tag_ops *, uint32_t *tag_array);
    const char *(*get_section_name)(const struct vendor_tag_ops *, uint32_t tag);
    const char *(*get_tag_name)(const struct vendor_tag_ops *, uint32_t tag);
    int (*get_tag_type)(const struct vendor_tag_ops *, uint32_t tag);
    void *reserved[8];
} vendor_tag_ops_t;

typedef struct camera_module {
    hw_module_t common;
    int (*get_number_of_cameras)(void);
    int (*get_camera_info)(int, void *);
    /* QTI extended layout follows (get_session_characteristics, construct_default_request_settings_V2,
     * set_callbacks, get_vendor_tag_ops, ...); not accessed here, the whole object is copied */
} camera_module_t;

typedef struct camera3_stream_configuration {
    uint32_t num_streams;
    void **streams;
    uint32_t operation_mode;
    const camera_metadata_t *session_parameters;
} camera3_stream_configuration_t;

struct camera3_device;
typedef struct camera3_device_ops {
    int (*initialize)(const struct camera3_device *, const void *callback_ops);
    int (*configure_streams)(const struct camera3_device *, camera3_stream_configuration_t *);
} camera3_device_ops_t;
typedef struct camera3_device {
    hw_device_t common;
    camera3_device_ops_t *ops;
    void *priv;
} camera3_device_t;

/* ---- wrapper state ---- */
#define HMI_SIZE 400 /* size of the real layer's HMI object (checked at build time) */
__attribute__((visibility("default"), aligned(16))) unsigned char HMI[HMI_SIZE];

static const camera_module_t *g_real;
static void (*g_get_vendor_tag_ops)(vendor_tag_ops_t *);
static hw_module_methods_t g_methods;
static int (*g_real_open)(const struct hw_module_t *, const char *, struct hw_device_t **);
static int (*g_real_configure)(const struct camera3_device *, camera3_stream_configuration_t *);
static uint32_t g_pkg_tag;
static int g_pkg_tag_state; /* 0 unknown, 1 found, -1 not available */
static camera_metadata_t *g_last; /* kept alive until the next configure */

static const char kPkg[] = "com.oplus.camera";
static vendor_tag_ops_t g_vtops; /* filled by the real layer; outlives every use */

/* add_camera_metadata_entry needs the tag's type. If no vendor tag ops are registered in this
 * process, register the real layer's own ops (the same table the HAL serves to cameraserver). */
static int add_pkg(camera_metadata_t *m) {
    if (add_camera_metadata_entry(m, g_pkg_tag, kPkg, sizeof(kPkg)) == 0) return 0;
    if (get_camera_metadata_tag_type(g_pkg_tag) < 0 && g_vtops.get_tag_type) {
        __android_log_print(LOG_I, TAG, "registering OnePlus vendor tag ops for metadata");
        set_camera_metadata_vendor_ops((const struct vendor_tag_ops *)&g_vtops);
        return add_camera_metadata_entry(m, g_pkg_tag, kPkg, sizeof(kPkg));
    }
    return -1;
}

static void find_pkg_tag(void) {
    if (g_pkg_tag_state) return;
    g_pkg_tag_state = -1;
    if (!g_get_vendor_tag_ops) {
        __android_log_print(LOG_E, TAG, "OemLayer::get_vendor_tag_ops not exported");
        return;
    }
    vendor_tag_ops_t *ops_p = &g_vtops;
    g_get_vendor_tag_ops(ops_p);
#define ops (*ops_p)
    if (!ops.get_tag_count || !ops.get_all_tags || !ops.get_section_name || !ops.get_tag_name) return;
    int n = ops.get_tag_count(&ops);
    if (n <= 0 || n > 65536) return;
    static uint32_t tags[65536];
    ops.get_all_tags(&ops, tags);
    for (int i = 0; i < n; i++) {
        const char *s = ops.get_section_name(&ops, tags[i]);
        const char *t = ops.get_tag_name(&ops, tags[i]);
        if (s && t && !strcmp(s, "com.oplus") && !strcmp(t, "packageName")) {
            g_pkg_tag = tags[i];
            g_pkg_tag_state = 1;
            __android_log_print(LOG_I, TAG, "com.oplus.packageName = 0x%x", g_pkg_tag);
            return;
        }
    }
    __android_log_print(LOG_E, TAG, "vendor tag com.oplus.packageName not found");
#undef ops
}

/* Spectra camera3_stream_t as the CamX provider builds it (offsets confirmed against the CHI
 * override, which reads format at 0x0c, usage at 0x10, data space at 0x20, use case at 0x48). */
#define STREAM_FORMAT(s)   (*(const int32_t *)((const char *)(s) + 0x0c))
#define STREAM_USAGE(s)    (*(const uint32_t *)((const char *)(s) + 0x10))
#define STREAM_W(s)        (*(const uint32_t *)((const char *)(s) + 0x04))
#define STREAM_H(s)        (*(const uint32_t *)((const char *)(s) + 0x08))
#define STREAM_USECASE(s)  (*(int64_t *)((char *)(s) + 0x48))
#define STREAM_MAXBUF(s)   (*(uint32_t *)((char *)(s) + 0x14))
#define USAGE_VIDEO_ENCODER 0x10000
/* A video-encoder surface (GraphicBufferSource) on LineageOS has no BufferQueue slot expansion,
 * so it holds at most 64 buffers, and cameraserver needs max_buffers + the encoder's own
 * undequeued buffers. In some video modes (1080p60 / stabilisation) OnePlus's HAL asks for 64,
 * which made cameraserver refuse the whole session ("Unable to set buffer count", -38): black
 * preview, then -22 on retries because the encoder surface was left connected. 42 is known to
 * work at 1080p; cap at 40. Fewer buffers only limits how many frames the HAL holds at once. */
#define ENCODER_MAX_BUFFERS 40
#define FMT_RAW16          0x20
#define USAGE_OPLUS_META   0x40      /* SurfaceDecision: "surface_key_picture_metadata" -> 0x40 */
#define USECASE_OPLUS_META 0x10002   /* advertised in android.scaler.availableStreamUseCases;
                                        the graph selector maps it to ChiStreamIntentMeta */

/* The OnePlus camera's picture-metadata surface (RAW16, consumer usage 0x40) must reach the HAL
 * with stream use case 0x10002 so the HAL writes each frame's metadata into it. Nothing on
 * LineageOS sets it, so the HAL treated it as an ordinary RAW stream and the processing stage
 * got empty metadata. Only streams with exactly that format/usage and no use case are touched. */
static void tag_meta_streams(camera3_stream_configuration_t *cfg) {
    for (uint32_t i = 0; i < cfg->num_streams; i++) {
        void *st = cfg->streams[i];
        if (!st) continue;
        __android_log_print(LOG_I, TAG, "stream %u: %ux%u fmt 0x%x usage 0x%x usecase 0x%llx", i,
                            STREAM_W(st), STREAM_H(st), STREAM_FORMAT(st), STREAM_USAGE(st),
                            (unsigned long long)STREAM_USECASE(st));
        if (STREAM_FORMAT(st) == FMT_RAW16 && (STREAM_USAGE(st) & 0xF0) == USAGE_OPLUS_META &&
            STREAM_USECASE(st) == 0) {
            STREAM_USECASE(st) = USECASE_OPLUS_META;
            __android_log_print(LOG_I, TAG, "stream %u: picture-metadata surface, use case set to 0x%x",
                                i, USECASE_OPLUS_META);
        }
    }
}

static int configure_and_cap(const struct camera3_device *dev, camera3_stream_configuration_t *cfg) {
    uint64_t enc = 0;  /* streams the framework marked as video-encoder consumers (before the HAL
                          ORs its own producer usage into the field) */
    for (uint32_t i = 0; i < cfg->num_streams && i < 64; i++)
        if (cfg->streams[i] && (STREAM_USAGE(cfg->streams[i]) & USAGE_VIDEO_ENCODER)) enc |= 1ULL << i;
    int r = g_real_configure(dev, cfg);
    if (r == 0 && enc) {
        for (uint32_t i = 0; i < cfg->num_streams && i < 64; i++) {
            void *st = cfg->streams[i];
            if ((enc >> i & 1) && st && STREAM_MAXBUF(st) > ENCODER_MAX_BUFFERS) {
                __android_log_print(LOG_I, TAG, "stream %u (%ux%u encoder): max_buffers %u -> %u", i,
                                    STREAM_W(st), STREAM_H(st), STREAM_MAXBUF(st), ENCODER_MAX_BUFFERS);
                STREAM_MAXBUF(st) = ENCODER_MAX_BUFFERS;
            }
        }
    }
    return r;
}

static int wrap_configure(const struct camera3_device *dev, camera3_stream_configuration_t *cfg) {
    if (cfg && cfg->operation_mode >= 0x8000 && cfg->streams && cfg->num_streams > 0 &&
        cfg->num_streams <= 64) {
        tag_meta_streams(cfg);
        find_pkg_tag();
        const camera_metadata_t *orig = cfg->session_parameters;
        camera_metadata_ro_entry_t e;
        int present = orig && g_pkg_tag_state == 1 &&
                      find_camera_metadata_ro_entry(orig, g_pkg_tag, &e) == 0 && e.count > 0;
        if (g_pkg_tag_state == 1 && !present) {
            size_t ec = orig ? get_camera_metadata_entry_count(orig) : 0;
            size_t dc = orig ? get_camera_metadata_data_count(orig) : 0;
            camera_metadata_t *m = allocate_camera_metadata(ec + 4, dc + 64);
            if (m && (!orig || append_camera_metadata(m, orig) == 0) &&
                add_pkg(m) == 0) {
                if (g_last) free_camera_metadata(g_last);
                g_last = m;
                cfg->session_parameters = m;
                __android_log_print(LOG_I, TAG, "op mode 0x%x: added com.oplus.packageName=%s",
                                    cfg->operation_mode, kPkg);
                int r = configure_and_cap(dev, cfg);
                cfg->session_parameters = orig;
                return r;
            }
            if (m) free_camera_metadata(m);
            __android_log_print(LOG_E, TAG, "could not add package tag, passing through");
        }
        return configure_and_cap(dev, cfg);
    }
    return g_real_configure(dev, cfg);
}

/* Device ops: OCamera3Dev allocates a private 18-slot ops table per device (operator new, freed
 * on close), so the configure_streams slot is redirected in place; nothing to undo on close. */
static int wrap_open(const struct hw_module_t *mod, const char *id, struct hw_device_t **out) {
    (void)mod;
    int r = g_real_open(&g_real->common, id, out);
    if (r == 0 && out && *out) {
        camera3_device_t *d = (camera3_device_t *)*out;
        camera3_device_ops_t *o = d->ops;
        if (o && o->configure_streams != wrap_configure) {
            if (!g_real_configure) g_real_configure = o->configure_streams;
            if (o->configure_streams == g_real_configure) {
                o->configure_streams = wrap_configure;
                __android_log_print(LOG_I, TAG, "camera %s: session hook installed", id ? id : "?");
            } else {
                __android_log_print(LOG_E, TAG, "camera %s: unexpected configure_streams %p, not hooked",
                                    id ? id : "?", (void *)o->configure_streams);
            }
        }
    }
    return r;
}

__attribute__((constructor)) static void init(void) {
    void *h = dlopen("camera.oemlayer.v2.so", RTLD_NOW | RTLD_NOLOAD);
    if (!h) h = dlopen("camera.oemlayer.v2.so", RTLD_NOW);
    g_real = h ? (const camera_module_t *)dlsym(h, "HMI") : 0;
    if (!g_real) {
        __android_log_print(LOG_E, TAG, "real OnePlus layer not found");
        return;
    }
    g_get_vendor_tag_ops = (void (*)(vendor_tag_ops_t *))dlsym(h, "_ZN8OemLayer18get_vendor_tag_opsEP14vendor_tag_ops");
    memcpy(HMI, g_real, HMI_SIZE);
    camera_module_t *me = (camera_module_t *)HMI;
    g_real_open = g_real->common.methods->open;
    g_methods.open = wrap_open;
    me->common.methods = &g_methods;
    __android_log_print(LOG_I, TAG, "wrapping OnePlus camera layer");
}
