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
 * parameters if absent, then calls the original.
 *
 * Isolation (v0.32): every camera device the provider opens is a small proxy. A device starts on
 * the OnePlus layer, as before. When a session is configured in a standard operation mode on a
 * device that hasn't run a OnePlus-mode session (any app other than the OnePlus camera), the
 * proxy closes that device and reopens the camera
 * directly on Qualcomm's HAL (camera.qcom), the path LineageOS uses without this module, and
 * clears the OnePlus callbacks the layer registered in the HAL while no OnePlus session is open.
 * Third-party apps therefore never run through OnePlus's request pipeline. Disable with
 * setprop persist.vendor.camera.oplus_los.route 0 (all sessions then stay on the OnePlus layer).
 */
#include <stddef.h>
#include <stdint.h>

/* ---- minimal libc / libdl / liblog / libcamera_metadata declarations ---- */
void *dlopen(const char *, int);
void *dlsym(void *, const char *);
void *memcpy(void *, const void *, size_t);
int strcmp(const char *, const char *);
int __android_log_print(int, const char *, const char *, ...);
void *calloc(size_t, size_t);
void free(void *);
int __system_property_get(const char *, char *);
#define RTLD_NOW 2
#define RTLD_NOLOAD 4
#define LOG_I 4
#define LOG_E 6
#define TAG "OplusCamLosWrap"
#ifdef OEMWRAP_HOST_TEST   /* tests/oemwrap_host_test.c builds the C logic on the build machine */
#define CPU_RELAX() ((void)0)
#else
#define CPU_RELAX() __asm__ volatile("yield")
#endif

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
int find_camera_metadata_entry(camera_metadata_t *, uint32_t tag, camera_metadata_ro_entry_t *);
int get_camera_metadata_ro_entry(const camera_metadata_t *, size_t index, camera_metadata_ro_entry_t *);
camera_metadata_t *clone_camera_metadata(const camera_metadata_t *);
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
static uint32_t g_pkg_tag;
static int g_pkg_tag_state; /* 0 unknown, 1 found, -1 not available */

static const char kPkg[] = "com.oplus.camera";
static vendor_tag_ops_t g_vtops; /* filled by the real layer; outlives every use */

/* Each camera device the provider opens is a proxy_t (see "per-session routing proxy" below). */
#define OPS_SLOTS 18   /* camera3_device_ops: 10 entry points + reserved[8] (QTI extensions) */
/* QTI's camera3_device_ops has one entry more than AOSP's before process_capture_request, so
 * requests arrive in slot 5, not AOSP's 4 (and every later entry is shifted by one).
 * camx.device-impl.so calls +0x28 for process_capture_request, +0x18 construct_default_request_settings,
 * +0x40 flush, +0x48 signal_stream_flush, +0x50 is_reconfiguration_required. Up to v0.38-beta the
 * wrapper hooked slot 4, which the provider never calls, so the frame-timestamp fix never saw a
 * request and passed every frame through as unknown (front-camera face shots hung). */
#define OP_PROCESS_CAPTURE_REQUEST 5
#define CB_SLOTS 16    /* camera3_callback_ops: 4 entry points; spare slots forward too */
#define REQ_RING 256   /* requests in flight are far fewer than this */
#define ADJ_RING 16
typedef struct proxy {
    camera3_device_t dev;          /* what the provider holds; dev.ops -> ops[] */
    camera3_device_t *backend;     /* offset 136: read by the trampolines */
    void *ops[OPS_SLOTS];
    const void *cb;                /* camera3_callback_ops given to initialize() */
    int is_oem, initialized;
    int oplus_owned;               /* this open ran a OnePlus-mode session (see proxy_configure) */
    char id[16];
    camera_metadata_t *session_params; /* our copy with the package tag; freed on the next
                                          configure or on close */
    /* Frame-timestamp fix for OnePlus sessions (see "Out-of-order frames" below) */
    struct {
        void *ops[CB_SLOTS];           /* the camera3_callback_ops the OnePlus layer is given */
        const void *orig;              /* offset 128: the provider's own callback ops */
    } cbw;
    int ts_lock, tsfix;
    uint8_t last_zsl, last_still;      /* from the last request that carried settings */
    uint64_t last_ts;                  /* newest shutter timestamp passed on */
    struct { uint32_t frame; uint8_t valid, exempt; } req[REQ_RING];
    struct { uint32_t frame; uint8_t valid; uint64_t orig, fixed; } adj[ADJ_RING];
    unsigned adj_next;
} proxy_t;
_Static_assert(__builtin_offsetof(camera3_device_t, ops) == 120, "camera3_device layout");
_Static_assert(__builtin_offsetof(proxy_t, backend) == 136, "proxy layout");
_Static_assert(__builtin_offsetof(proxy_t, cbw.orig) - __builtin_offsetof(proxy_t, cbw) == 128,
               "callback wrapper layout");

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
    const vendor_tag_ops_t *ops = &g_vtops;
    g_get_vendor_tag_ops(&g_vtops);
    if (!ops->get_tag_count || !ops->get_all_tags || !ops->get_section_name || !ops->get_tag_name) return;
    int n = ops->get_tag_count(ops);
    if (n <= 0 || n > 65536) return;
    static uint32_t tags[65536];
    ops->get_all_tags(ops, tags);
    for (int i = 0; i < n; i++) {
        const char *s = ops->get_section_name(ops, tags[i]);
        const char *t = ops->get_tag_name(ops, tags[i]);
        if (s && t && !strcmp(s, "com.oplus") && !strcmp(t, "packageName")) {
            g_pkg_tag = tags[i];
            g_pkg_tag_state = 1;
            __android_log_print(LOG_I, TAG, "com.oplus.packageName = 0x%x", g_pkg_tag);
            return;
        }
    }
    __android_log_print(LOG_E, TAG, "vendor tag com.oplus.packageName not found");
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
 * work at 1080p; cap at 40. Fewer buffers only limits how many frames the HAL holds at once, but
 * stabilised modes hold frames back for look-ahead, so the cap is tunable for testing 4K60/EIS:
 * setprop persist.vendor.camera.oplus_los.encbuf N (8..63; 0 = no cap; read at each configure). */
#define ENCODER_MAX_BUFFERS 40

static uint32_t encoder_cap(void) {
    char v[92] = {0};
    __system_property_get("persist.vendor.camera.oplus_los.encbuf", v);
    if (!v[0]) return ENCODER_MAX_BUFFERS;
    uint32_t n = 0;
    for (int i = 0; v[i]; i++) {
        if (v[i] < '0' || v[i] > '9' || i > 2) return ENCODER_MAX_BUFFERS;
        n = n * 10 + (uint32_t)(v[i] - '0');
    }
    if (n == 0) return 0;                       /* 0: leave the HAL's request alone */
    return (n >= 8 && n <= 63) ? n : ENCODER_MAX_BUFFERS;
}
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
    int (*real)(const struct camera3_device *, camera3_stream_configuration_t *) = dev->ops->configure_streams;
    uint64_t enc = 0;  /* streams the framework marked as video-encoder consumers (before the HAL
                          ORs its own producer usage into the field) */
    for (uint32_t i = 0; i < cfg->num_streams && i < 64; i++)
        if (cfg->streams[i] && (STREAM_USAGE(cfg->streams[i]) & USAGE_VIDEO_ENCODER)) enc |= 1ULL << i;
    int r = real(dev, cfg);
    uint32_t cap = enc ? encoder_cap() : 0;
    if (r == 0 && enc) {
        for (uint32_t i = 0; i < cfg->num_streams && i < 64; i++) {
            void *st = cfg->streams[i];
            if (!(enc >> i & 1) || !st) continue;
            if (cap && STREAM_MAXBUF(st) > cap) {
                __android_log_print(LOG_I, TAG, "stream %u (%ux%u encoder): max_buffers %u -> %u", i,
                                    STREAM_W(st), STREAM_H(st), STREAM_MAXBUF(st), cap);
                STREAM_MAXBUF(st) = cap;
            } else {
                __android_log_print(LOG_I, TAG, "stream %u (%ux%u encoder): max_buffers %u (cap %u)", i,
                                    STREAM_W(st), STREAM_H(st), STREAM_MAXBUF(st), cap);
            }
        }
    }
    return r;
}

static int oem_configure(proxy_t *p, camera3_stream_configuration_t *cfg) {
    const struct camera3_device *dev = p->backend;
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
                if (p->session_params) free_camera_metadata(p->session_params);
                p->session_params = m;
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
    return dev->ops->configure_streams(dev, cfg);
}

/* ---------------------------------------------------------------- per-session routing proxy */

/* Forward slot i to the current backend with the backend as the device argument; every argument
 * register and the stack are left untouched. A slot the backend leaves NULL returns -ENOSYS. */
#ifdef OEMWRAP_HOST_TEST
#define TRAMP(i) static void tramp_##i(void) {}
#else
#define TRAMP(i) \
    __attribute__((naked)) static void tramp_##i(void) { \
        __asm__ volatile("hint #34\n"                 /* bti c */ \
                         "ldr x16, [x0, #136]\n"      /* proxy->backend */ \
                         "ldr x17, [x16, #120]\n"     /* backend->ops */ \
                         "ldr x17, [x17, #" #i "*8]\n" \
                         "cbz x17, 1f\n" \
                         "mov x0, x16\n" \
                         "br x17\n" \
                         "1: mov x0, #-38\n" \
                         "ret\n"); }
#endif
TRAMP(0) TRAMP(1) TRAMP(2) TRAMP(3) TRAMP(4) TRAMP(5) TRAMP(6) TRAMP(7) TRAMP(8)
TRAMP(9) TRAMP(10) TRAMP(11) TRAMP(12) TRAMP(13) TRAMP(14) TRAMP(15) TRAMP(16) TRAMP(17)
static void (*const kTramp[OPS_SLOTS])(void) = {
    tramp_0, tramp_1, tramp_2, tramp_3, tramp_4, tramp_5, tramp_6, tramp_7, tramp_8,
    tramp_9, tramp_10, tramp_11, tramp_12, tramp_13, tramp_14, tramp_15, tramp_16, tramp_17};

/* Filled in by the layer when the provider initialises it (after this library loads), so they
 * are read through the layer's exported variables at use time. */
static const camera_module_t **g_camx_pp;        /* OemLayer g_camx_camera_module */
static void (**g_set_oplus_cb_pp)(const void *); /* OemLayer pSetOplusCallback (camx setter) */
static const void *g_oplus_cb;                   /* OemLayer::g_camx_oplus_callback_ops */
#define g_camx (g_camx_pp ? *g_camx_pp : (const camera_module_t *)0)
#define g_set_oplus_cb (g_set_oplus_cb_pp ? *g_set_oplus_cb_pp : (void (*)(const void *))0)
static int g_open_oem, g_open_direct;
static const void *g_cb_state = (const void *)1; /* unknown until first set */

/* The OnePlus layer registers callbacks in Qualcomm's HAL at load time. Keep them registered
 * while any OnePlus-layer device is open (or nothing is open), clear them while only directly
 * opened devices exist, as on LineageOS without the module. */
static int g_cb_lock;
static void update_oplus_callbacks(void) {
    if (!g_set_oplus_cb || !g_oplus_cb) return;
    while (__atomic_exchange_n(&g_cb_lock, 1, __ATOMIC_ACQUIRE)) CPU_RELAX();
    const void *want = (__atomic_load_n(&g_open_oem, __ATOMIC_SEQ_CST) > 0 ||
                        __atomic_load_n(&g_open_direct, __ATOMIC_SEQ_CST) == 0) ? g_oplus_cb : 0;
    int changed = want != g_cb_state;
    if (changed) {
        g_set_oplus_cb(want);
        g_cb_state = want;
    }
    __atomic_store_n(&g_cb_lock, 0, __ATOMIC_RELEASE);
    if (changed)
        __android_log_print(LOG_I, TAG, "OnePlus HAL callbacks %s", want ? "registered" : "cleared");
}

static int routing_enabled(void) {
    char v[92] = {0};
    if (!g_camx || !g_set_oplus_cb || !g_oplus_cb) return 0;
    __system_property_get("persist.vendor.camera.oplus_los.route", v);
    return !(v[0] == '0' && v[1] == 0);
}

static int open_backend(proxy_t *p, int oem, camera3_device_t **out) {
    struct hw_device_t *d = 0;
    int *cnt = oem ? &g_open_oem : &g_open_direct;
    __atomic_add_fetch(cnt, 1, __ATOMIC_SEQ_CST);
    update_oplus_callbacks();
    int r = oem ? g_real_open(&g_real->common, p->id, &d)
                : g_camx->common.methods->open(&g_camx->common, p->id, &d);
    if (r != 0 || !d) {
        __atomic_sub_fetch(cnt, 1, __ATOMIC_SEQ_CST);
        update_oplus_callbacks();
        return r ? r : -19;
    }
    *out = (camera3_device_t *)d;
    return 0;
}

static void close_backend(proxy_t *p) {
    if (!p->backend) return;
    p->backend->common.close(&p->backend->common);
    p->backend = 0;
    __atomic_sub_fetch(p->is_oem ? &g_open_oem : &g_open_direct, 1, __ATOMIC_SEQ_CST);
    update_oplus_callbacks();
}

static void adopt_backend(proxy_t *p, camera3_device_t *b, int oem) {
    p->backend = b;
    p->is_oem = oem;
    p->dev.priv = b->priv;
}

/* ---------------------------------------------------------------- out-of-order frames
 *
 * For portrait and other multi-frame shots OnePlus's HAL builds part of the burst from frames it
 * captured just before the shutter and re-stamps them a few nanoseconds after their original time,
 * so a frame's shutter timestamp can be older than the previous frame's. Android's camera service
 * (Camera3Stream::returnBuffer) then marks that frame's buffers as errors unless the request was a
 * reprocess or a ZSL still capture; the app gets 6 of 7 frames and its shutter stays busy.
 *
 * For OnePlus sessions only, the wrapper sits between the layer and the provider's callbacks and
 * raises such a timestamp to 1 ns after the previous one (readout time moved by the same amount),
 * and writes the same value into that frame's android.sensor.timestamp result, so the image and
 * its result still match. Frames the camera service exempts (reprocess, ZSL still capture) are
 * passed on unchanged, and nothing is changed while timestamps increase. Other apps' sessions run
 * on Qualcomm's HAL with the provider's own callbacks. Disable with
 * setprop persist.vendor.camera.oplus_los.tsfix 0 (read when a session starts).
 */
#define CAMERA3_MSG_SHUTTER 2
#define TAG_SENSOR_TIMESTAMP 0xE0010    /* android.sensor.timestamp */
#define TAG_CAPTURE_INTENT   0x1000D    /* android.control.captureIntent */
#define TAG_ENABLE_ZSL       0x10029    /* android.control.enableZsl */
#define INTENT_STILL_CAPTURE 2
/* Qualcomm camera3 ABI, offsets checked against camera.qcom.so's own logging of these structs */
#define MSG_TYPE(m)       (*(const int32_t *)((const char *)(m) + 0x00))
#define MSG_FRAME(m)      (*(const uint32_t *)((const char *)(m) + 0x08))
#define MSG_TS(m)         (*(uint64_t *)((char *)(m) + 0x10))
#define MSG_READOUT(m)    (*(uint64_t *)((char *)(m) + 0x18))
#define MSG_SIZE          0x20
#define REQ_FRAME(r)      (*(const uint32_t *)((const char *)(r) + 0x00))
#define REQ_SETTINGS(r)   (*(const camera_metadata_t *const *)((const char *)(r) + 0x08))
#define REQ_INPUT(r)      (*(const void *const *)((const char *)(r) + 0x10))
#define RES_FRAME(r)      (*(const uint32_t *)((const char *)(r) + 0x00))
#define RES_META(r)       (*(const camera_metadata_t **)((char *)(r) + 0x08))

static void ts_lock(proxy_t *p) { while (__atomic_exchange_n(&p->ts_lock, 1, __ATOMIC_ACQUIRE)) CPU_RELAX(); }
static void ts_unlock(proxy_t *p) { __atomic_store_n(&p->ts_lock, 0, __ATOMIC_RELEASE); }
static proxy_t *proxy_of_cb(const void *cb) { return (proxy_t *)((char *)cb - __builtin_offsetof(proxy_t, cbw)); }

static int meta_u8(const camera_metadata_t *m, uint32_t tag, uint8_t *out) {
    camera_metadata_ro_entry_t e;
    if (find_camera_metadata_ro_entry(m, tag, &e) != 0 || e.count < 1) return 0;
    *out = *(const uint8_t *)e.data;
    return 1;
}

static int tsfix_enabled(void) {
    char v[92] = {0};
    __system_property_get("persist.vendor.camera.oplus_los.tsfix", v);
    return !(v[0] == '0' && v[1] == 0);
}

/* process_capture_request (QTI slot 5): note which frames the camera service exempts */
static int proxy_request(const struct camera3_device *dev, void *req) {
    proxy_t *p = (proxy_t *)dev;
    int (*real)(const struct camera3_device *, void *) = ((void **)p->backend->ops)[OP_PROCESS_CAPTURE_REQUEST];
    if (p->is_oem && p->tsfix && req) {
        const camera_metadata_t *set = REQ_SETTINGS(req);
        uint8_t v;
        ts_lock(p);
        if (set) {   /* NULL settings repeat the previous request's */
            p->last_zsl = meta_u8(set, TAG_ENABLE_ZSL, &v) && v == 1;
            p->last_still = meta_u8(set, TAG_CAPTURE_INTENT, &v) && v == INTENT_STILL_CAPTURE;
        }
        uint32_t f = REQ_FRAME(req);
        p->req[f % REQ_RING].frame = f;
        p->req[f % REQ_RING].valid = 1;
        p->req[f % REQ_RING].exempt = REQ_INPUT(req) || (p->last_zsl && p->last_still);
        ts_unlock(p);
    }
    return real(p->backend, req);
}

static void cb_notify(const void *cb, const void *msg) {
    proxy_t *p = proxy_of_cb(cb);
    void (*real)(const void *, const void *) = ((void *const *)p->cbw.orig)[1];
    if (!msg || MSG_TYPE(msg) != CAMERA3_MSG_SHUTTER) { real(p->cbw.orig, msg); return; }
    uint32_t f = MSG_FRAME(msg);
    uint64_t ts = MSG_TS((void *)msg), prev = 0, fixed = 0;
    ts_lock(p);
    int known = p->req[f % REQ_RING].valid && p->req[f % REQ_RING].frame == f;
    int exempt = known && p->req[f % REQ_RING].exempt;
    if (known) p->req[f % REQ_RING].valid = 0;
    if (known && !exempt && ts != 0) {
        if (p->last_ts && ts <= p->last_ts) {
            prev = p->last_ts;
            fixed = prev + 1;
            unsigned i = p->adj_next++ % ADJ_RING;
            p->adj[i].frame = f; p->adj[i].orig = ts; p->adj[i].fixed = fixed; p->adj[i].valid = 1;
            p->last_ts = fixed;
        } else {
            p->last_ts = ts;
        }
    }
    ts_unlock(p);
    if (!fixed) { real(p->cbw.orig, msg); return; }
    uint64_t copy[MSG_SIZE / 8];
    memcpy(copy, msg, MSG_SIZE);
    MSG_TS(copy) = fixed;
    if (MSG_READOUT(copy)) MSG_READOUT(copy) += fixed - ts;
    __android_log_print(LOG_I, TAG, "camera %s frame %u: shutter %llu older than previous %llu, sent as %llu",
                        p->id, f, (unsigned long long)ts, (unsigned long long)prev, (unsigned long long)fixed);
    real(p->cbw.orig, copy);
}

static void cb_result(const void *cb, const void *res) {
    proxy_t *p = proxy_of_cb(cb);
    void (*real)(const void *, const void *) = ((void *const *)p->cbw.orig)[0];
    const camera_metadata_t *meta = res ? RES_META((void *)res) : 0;
    uint64_t orig = 0, fixed = 0;
    if (meta) {
        uint32_t f = RES_FRAME(res);
        ts_lock(p);
        for (int i = 0; i < ADJ_RING; i++)
            if (p->adj[i].valid && p->adj[i].frame == f) { orig = p->adj[i].orig; fixed = p->adj[i].fixed; break; }
        ts_unlock(p);
    }
    camera_metadata_t *mine = 0;
    if (fixed) {
        camera_metadata_ro_entry_t e;
        if (find_camera_metadata_ro_entry(meta, TAG_SENSOR_TIMESTAMP, &e) == 0 && e.count == 1 &&
            *(const int64_t *)e.data == (int64_t)orig && (mine = clone_camera_metadata(meta)) != 0 &&
            find_camera_metadata_entry(mine, TAG_SENSOR_TIMESTAMP, &e) == 0 && e.count == 1) {
            *(int64_t *)e.data = (int64_t)fixed;
        } else if (mine) {
            free_camera_metadata(mine);
            mine = 0;
        }
    }
    if (!mine) { real(p->cbw.orig, res); return; }
    /* The result struct is Qualcomm's extended layout (private fields after the AOSP ones), so it
     * is not copied: the metadata pointer is swapped for this call only. The provider copies the
     * metadata before returning. */
    RES_META((void *)res) = mine;
    real(p->cbw.orig, res);
    RES_META((void *)res) = meta;
    free_camera_metadata(mine);
}

/* Forward callback slot i to the provider's own callback ops, as the provider's own first argument */
#ifdef OEMWRAP_HOST_TEST
#define CBTRAMP(i) static void cbtramp_##i(void) {}
#else
#define CBTRAMP(i) \
    __attribute__((naked)) static void cbtramp_##i(void) { \
        __asm__ volatile("hint #34\n"                 /* bti c */ \
                         "ldr x16, [x0, #128]\n"      /* cbw.orig */ \
                         "ldr x17, [x16, #" #i "*8]\n" \
                         "mov x0, x16\n" \
                         "br x17\n"); }
#endif
CBTRAMP(2) CBTRAMP(3) CBTRAMP(4) CBTRAMP(5) CBTRAMP(6) CBTRAMP(7) CBTRAMP(8) CBTRAMP(9)
CBTRAMP(10) CBTRAMP(11) CBTRAMP(12) CBTRAMP(13) CBTRAMP(14) CBTRAMP(15)

/* The callback ops a backend is initialised with: ours for the OnePlus layer (fix enabled), the
 * provider's own for Qualcomm's HAL, so other apps' sessions are untouched. */
static const void *cb_for(proxy_t *p, int oem) {
    if (!oem || !p->tsfix || !p->cb) return p->cb;
    void **o = p->cbw.ops;
    o[0] = (void *)cb_result;
    o[1] = (void *)cb_notify;
    o[2] = (void *)cbtramp_2;   o[3] = (void *)cbtramp_3;   o[4] = (void *)cbtramp_4;
    o[5] = (void *)cbtramp_5;   o[6] = (void *)cbtramp_6;   o[7] = (void *)cbtramp_7;
    o[8] = (void *)cbtramp_8;   o[9] = (void *)cbtramp_9;   o[10] = (void *)cbtramp_10;
    o[11] = (void *)cbtramp_11; o[12] = (void *)cbtramp_12; o[13] = (void *)cbtramp_13;
    o[14] = (void *)cbtramp_14; o[15] = (void *)cbtramp_15;
    p->cbw.orig = p->cb;
    return &p->cbw;
}

static int proxy_initialize(const struct camera3_device *dev, const void *cb) {
    proxy_t *p = (proxy_t *)dev;
    p->cb = cb;
    p->initialized = 1;
    p->tsfix = tsfix_enabled();
    return p->backend->ops->initialize(p->backend, cb_for(p, p->is_oem));
}

/* Move the device to the other backend between sessions (configure_streams is only called with
 * no requests in flight). On failure the previous backend is reopened. */
static int switch_backend(proxy_t *p, int oem) {
    int was = p->is_oem;
    close_backend(p);
    camera3_device_t *b = 0;
    int r = open_backend(p, oem, &b);
    if (r == 0 && p->initialized && (r = b->ops->initialize(b, cb_for(p, oem))) != 0) {
        b->common.close(&b->common);
        __atomic_sub_fetch(oem ? &g_open_oem : &g_open_direct, 1, __ATOMIC_SEQ_CST);
        update_oplus_callbacks();
    }
    if (r == 0) {
        adopt_backend(p, b, oem);
        __android_log_print(LOG_I, TAG, "camera %s: session moved to %s", p->id,
                            oem ? "the OnePlus layer" : "Qualcomm's HAL (stock path)");
        return 0;
    }
    __android_log_print(LOG_E, TAG, "camera %s: could not move session (%d), staying", p->id, r);
    if (open_backend(p, was, &b) == 0) {
        adopt_backend(p, b, was);
        if (p->initialized) b->ops->initialize(b, cb_for(p, was));
    }
    return r;
}

/* Does a session carry OnePlus settings? The OnePlus camera puts its own com.oplus.* keys into
 * every session (those the HAL declares as session keys reach it through LineageOS's camera
 * service); other apps don't know them. Returns how many, and for a standard-mode session logs
 * which, so a debug bundle shows what the app sent. */
static int oplus_settings(const proxy_t *p, const camera3_stream_configuration_t *cfg) {
    const camera_metadata_t *m = cfg->session_parameters;
    find_pkg_tag();
    if (!m || g_pkg_tag_state != 1 || !g_vtops.get_section_name || !g_vtops.get_tag_name) return 0;
    char names[160];
    int n = 0, len = 0;
    size_t count = get_camera_metadata_entry_count(m);
    for (size_t i = 0; i < count && i < 256; i++) {
        camera_metadata_ro_entry_t e;
        if (get_camera_metadata_ro_entry(m, i, &e) != 0 || e.tag < 0x80000000u) continue;
        const char *sec = g_vtops.get_section_name(&g_vtops, e.tag);
        if (!sec || sec[0] != 'c' || sec[1] != 'o' || sec[2] != 'm' || sec[3] != '.' || sec[4] != 'o' ||
            sec[5] != 'p' || sec[6] != 'l' || sec[7] != 'u' || sec[8] != 's')
            continue;
        const char *t = g_vtops.get_tag_name(&g_vtops, e.tag);
        for (int k = 0; n < 6 && t && t[k] && len < (int)sizeof(names) - 3; k++) names[len++] = t[k];
        if (n < 6 && len < (int)sizeof(names) - 2) names[len++] = ' ';
        n++;
    }
    names[len] = 0;
    if (cfg->operation_mode < 0x8000)
        __android_log_print(LOG_I, TAG, "camera %s: op mode 0x%x session, OnePlus settings: %d %s", p->id,
                            cfg->operation_mode, n, n ? names : "");
    return n;
}

/* A camera device is opened by one client. Once it has run a session in a OnePlus mode, it belongs
 * to the OnePlus camera, which also configures short standard-mode sessions while switching modes
 * (op mode 0 between two OnePlus modes). Those stay on the OnePlus layer, as on OxygenOS, instead of
 * closing and reopening the camera twice per mode switch. Some OnePlus modes use only standard
 * sessions on a camera (seen on camera 2); those are recognised by their OnePlus settings. Other
 * apps open their own devices and use neither, so they are still moved to Qualcomm's HAL. */
static int proxy_configure(const struct camera3_device *dev, camera3_stream_configuration_t *cfg) {
    proxy_t *p = (proxy_t *)dev;
    if (cfg && (cfg->operation_mode >= 0x8000 || (routing_enabled() && oplus_settings(p, cfg) > 0)))
        p->oplus_owned = 1;
    int oem = !cfg || p->oplus_owned || !routing_enabled();
    if (oem != p->is_oem) {
        int r = switch_backend(p, oem);
        if (r) return r;
    }
    if (!p->backend) return -19;
    return p->is_oem ? oem_configure(p, cfg) : p->backend->ops->configure_streams(p->backend, cfg);
}

static int proxy_close(struct hw_device_t *d) {
    proxy_t *p = (proxy_t *)d;
    close_backend(p);
    if (p->session_params) free_camera_metadata(p->session_params);
    free(p);
    return 0;
}

static int wrap_open(const struct hw_module_t *mod, const char *id, struct hw_device_t **out) {
    (void)mod;
    proxy_t *p = calloc(1, sizeof(*p));
    if (!p) return g_real_open(&g_real->common, id, out);
    for (int i = 0; id && id[i] && i < (int)sizeof(p->id) - 1; i++) p->id[i] = id[i];
    camera3_device_t *b = 0;
    int r = open_backend(p, 1, &b);           /* start on the OnePlus layer, as before */
    if (r) { free(p); return r; }
    memcpy(&p->dev, b, sizeof(p->dev));         /* tag, version, module, reserved, priv */
    p->dev.common.close = proxy_close;
    for (int i = 0; i < OPS_SLOTS; i++)
        p->ops[i] = ((void **)b->ops)[i] ? (void *)kTramp[i] : 0;
    p->ops[0] = (void *)proxy_initialize;
    p->ops[1] = (void *)proxy_configure;
    if (p->ops[OP_PROCESS_CAPTURE_REQUEST]) p->ops[OP_PROCESS_CAPTURE_REQUEST] = (void *)proxy_request;
    p->dev.ops = (camera3_device_ops_t *)p->ops;
    adopt_backend(p, b, 1);
    *out = &p->dev.common;
    __android_log_print(LOG_I, TAG, "camera %s: opened (third-party routing %s)", p->id,
                        routing_enabled() ? "on" : "off");
    return 0;
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
    /* Qualcomm's module and the callback registration, as the layer set them up while loading */
    g_camx_pp = (const camera_module_t **)dlsym(h, "g_camx_camera_module");
    g_set_oplus_cb_pp = (void (**)(const void *))dlsym(h, "pSetOplusCallback");
    g_oplus_cb = dlsym(h, "_ZN8OemLayer25g_camx_oplus_callback_opsE");
    if (!g_camx_pp || !g_set_oplus_cb_pp || !g_oplus_cb)
        __android_log_print(LOG_E, TAG, "stock path symbols missing: all sessions stay on the "
                            "OnePlus layer");
    memcpy(HMI, g_real, HMI_SIZE);
    camera_module_t *me = (camera_module_t *)HMI;
    g_real_open = g_real->common.methods->open;
    g_methods.open = wrap_open;
    me->common.methods = &g_methods;
    __android_log_print(LOG_I, TAG, "wrapping OnePlus camera layer");
}
