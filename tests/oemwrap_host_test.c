/*
 * Host test for the wrapper's frame-timestamp fix (tools/oemwrap/oemwrap.c).
 *
 * Builds the wrapper's C logic for the build machine (OEMWRAP_HOST_TEST: the aarch64 forwarding
 * stubs are left out) and drives it the way the camera provider and the OnePlus layer do:
 * initialize -> process_capture_request -> notify(shutter) -> process_capture_result.
 * libcamera_metadata, liblog, libdl and properties are replaced by small fakes below.
 * Run by tests/test_build.py; exits non-zero on the first failed check.
 */
#define OEMWRAP_HOST_TEST 1
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../tools/oemwrap/oemwrap.c"

/* ---- fake libcamera_metadata: up to 8 entries, each one u8 or one int64 ---- */
struct camera_metadata {
    int n;
    struct { unsigned tag; long long v; unsigned char u8; int is_u8; } e[8];
};
typedef camera_metadata_ro_entry_t ro_entry_t;

static int g_live_meta;   /* metadata objects allocated by the wrapper and not yet freed */
camera_metadata_t *allocate_camera_metadata(size_t a, size_t b) { (void)a; (void)b; g_live_meta++; return calloc(1, sizeof(camera_metadata_t)); }
void free_camera_metadata(camera_metadata_t *m) { if (m) { g_live_meta--; free(m); } }
camera_metadata_t *clone_camera_metadata(const camera_metadata_t *s) {
    camera_metadata_t *m = malloc(sizeof(*m));
    memcpy(m, s, sizeof(*m));
    g_live_meta++;
    return m;
}
int append_camera_metadata(camera_metadata_t *d, const camera_metadata_t *s) { (void)d; (void)s; return 0; }
int add_camera_metadata_entry(camera_metadata_t *m, uint32_t t, const void *d, size_t c) { (void)m; (void)t; (void)d; (void)c; return 0; }
static int find_any(const camera_metadata_t *m, unsigned t, ro_entry_t *e) {
    for (int i = 0; i < m->n; i++)
        if (m->e[i].tag == t) {
            e->tag = t; e->count = 1; e->index = i;
            e->data = m->e[i].is_u8 ? (const void *)&m->e[i].u8 : (const void *)&m->e[i].v;
            return 0;
        }
    return -2;
}
int find_camera_metadata_ro_entry(const camera_metadata_t *m, uint32_t t, ro_entry_t *e) { return find_any(m, t, e); }
int find_camera_metadata_entry(camera_metadata_t *m, uint32_t t, ro_entry_t *e) { return find_any(m, t, e); }
size_t get_camera_metadata_entry_count(const camera_metadata_t *m) { return m->n; }
size_t get_camera_metadata_data_count(const camera_metadata_t *m) { (void)m; return 0; }
int get_camera_metadata_tag_type(uint32_t t) { (void)t; return 0; }
int set_camera_metadata_vendor_ops(const struct vendor_tag_ops *o) { (void)o; return 0; }

/* ---- fake liblog / libdl / properties ---- */
int __android_log_print(int prio, const char *tag, const char *fmt, ...) { (void)prio; (void)tag; (void)fmt; return 0; }
void *dlopen(const char *n, int f) { (void)n; (void)f; return 0; }
void *dlsym(void *h, const char *n) { (void)h; (void)n; return 0; }
static char g_prop_tsfix[8] = "";
int __system_property_get(const char *k, char *v) {
    v[0] = 0;
    if (!strcmp(k, "persist.vendor.camera.oplus_los.tsfix")) strcpy(v, g_prop_tsfix);
    return (int)strlen(v);
}

/* ---- Qualcomm camera3 structs, laid out as the HAL uses them (see the offsets in oemwrap.c) ---- */
typedef struct { int32_t type; uint32_t pad; uint32_t frame; uint32_t pad2; uint64_t ts, readout; } shutter_msg_t;
typedef struct { uint32_t frame; uint32_t pad; const camera_metadata_t *settings; const void *input; char rest[0x60]; } request_t;
/* the result struct is longer than AOSP's (Qualcomm private fields): the wrapper must not copy it */
typedef struct { uint32_t frame; uint32_t pad; const camera_metadata_t *result; char qti_private[0x50]; } result_t;
_Static_assert(__builtin_offsetof(shutter_msg_t, ts) == 0x10 && __builtin_offsetof(shutter_msg_t, readout) == 0x18, "msg");
_Static_assert(__builtin_offsetof(request_t, input) == 0x10 && __builtin_offsetof(result_t, result) == 0x08, "req/res");

/* ---- fake camera service (the provider's callback ops) ---- */
typedef struct provider_cb { void (*result)(const void *, const void *); void (*notify)(const void *, const void *); } provider_cb_t;
static provider_cb_t g_prov;
static const void *g_last_cb_arg;
static uint64_t g_seen_ts, g_seen_readout;
static int64_t g_seen_meta_ts;
static const camera_metadata_t *g_seen_meta;
static void prov_notify(const void *cb, const void *m) {
    g_last_cb_arg = cb;
    const shutter_msg_t *s = m;
    g_seen_ts = s->ts; g_seen_readout = s->readout;
}
static void prov_result(const void *cb, const void *r) {
    g_last_cb_arg = cb;
    const result_t *res = r;
    ro_entry_t e;
    g_seen_meta = res->result;
    g_seen_meta_ts = find_any(res->result, TAG_SENSOR_TIMESTAMP, &e) == 0 ? *(const int64_t *)e.data : -1;
}

/* ---- fake OnePlus layer device ---- */
static const void *g_layer_cb;   /* the callback ops the layer was initialised with */
static int g_layer_requests;
static int layer_init(const struct camera3_device *d, const void *cb) { (void)d; g_layer_cb = cb; return 0; }
static int layer_request(const struct camera3_device *d, void *r) { (void)d; (void)r; g_layer_requests++; return 0; }
static void *g_layer_ops[OPS_SLOTS];
static camera3_device_t g_layer_dev;

static int failures;
#define CHECK(c, ...) do { if (!(c)) { failures++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

/* HAL side: what the OnePlus layer does with the callback ops it was given */
static void hal_shutter(uint32_t f, uint64_t ts, uint64_t ro) {
    shutter_msg_t m = {CAMERA3_MSG_SHUTTER, 0, f, 0, ts, ro};
    ((provider_cb_t *)g_layer_cb)->notify(g_layer_cb, &m);
    CHECK(m.ts == ts && m.readout == ro, "the HAL's own message was modified");
}
static void hal_result(uint32_t f, const camera_metadata_t *meta) {
    result_t r; memset(&r, 0x5a, sizeof(r));
    r.frame = f; r.result = meta;
    ((provider_cb_t *)g_layer_cb)->result(g_layer_cb, &r);
    CHECK(r.result == meta, "result metadata pointer not restored");
}
static camera_metadata_t g_set_zsl_still, g_set_plain, g_set_still_only;

static void request(proxy_t *p, uint32_t f, const camera_metadata_t *set, int input) {
    request_t r; memset(&r, 0, sizeof(r));
    r.frame = f; r.settings = set; r.input = input ? (void *)&r : 0;
    proxy_request(&p->dev, &r);
}
static camera_metadata_t meta_ts(int64_t ts) {
    camera_metadata_t m = {0};
    m.n = 1; m.e[0].tag = TAG_SENSOR_TIMESTAMP; m.e[0].v = ts;
    return m;
}
static proxy_t *new_session(int oem) {
    proxy_t *p = calloc(1, sizeof(*p));
    strcpy(p->id, "0");
    memcpy(&p->dev, &g_layer_dev, sizeof(p->dev));
    p->ops[4] = (void *)proxy_request;
    p->dev.ops = (camera3_device_ops_t *)p->ops;
    p->backend = &g_layer_dev;
    p->is_oem = oem;
    proxy_initialize(&p->dev, &g_prov);
    return p;
}

int main(void) {
    g_prov.result = prov_result; g_prov.notify = prov_notify;
    g_layer_ops[0] = (void *)layer_init; g_layer_ops[4] = (void *)layer_request;
    g_layer_dev.ops = (camera3_device_ops_t *)g_layer_ops;
    g_set_zsl_still.n = 2;
    g_set_zsl_still.e[0].tag = TAG_ENABLE_ZSL; g_set_zsl_still.e[0].u8 = 1; g_set_zsl_still.e[0].is_u8 = 1;
    g_set_zsl_still.e[1].tag = TAG_CAPTURE_INTENT; g_set_zsl_still.e[1].u8 = INTENT_STILL_CAPTURE; g_set_zsl_still.e[1].is_u8 = 1;
    g_set_still_only.n = 1;
    g_set_still_only.e[0].tag = TAG_CAPTURE_INTENT; g_set_still_only.e[0].u8 = INTENT_STILL_CAPTURE; g_set_still_only.e[0].is_u8 = 1;
    g_set_plain.n = 1;
    g_set_plain.e[0].tag = TAG_CAPTURE_INTENT; g_set_plain.e[0].u8 = 1; g_set_plain.e[0].is_u8 = 1;

    /* 1. OnePlus session: the layer gets the wrapper's callback ops, requests reach the layer */
    proxy_t *p = new_session(1);
    CHECK(g_layer_cb == &p->cbw, "OnePlus layer should get the wrapper's callbacks");
    request(p, 1, &g_set_plain, 0);
    CHECK(g_layer_requests == 1, "request not forwarded");

    /* 2. increasing timestamps pass unchanged, with the provider's own pointer as first argument */
    hal_shutter(1, 1000, 1500);
    CHECK(g_seen_ts == 1000 && g_seen_readout == 1500, "increasing shutter changed: %llu", (unsigned long long)g_seen_ts);
    CHECK(g_last_cb_arg == &g_prov, "provider not called with its own callback ops");
    camera_metadata_t m1 = meta_ts(1000);
    hal_result(1, &m1);
    CHECK(g_seen_meta == &m1 && g_seen_meta_ts == 1000, "unchanged result was copied or changed");

    /* 3. a re-stamped older frame (multi-frame shot) is raised to previous + 1, result matches */
    request(p, 2, 0, 0);   /* NULL settings: same as frame 1 */
    hal_shutter(2, 900, 1400);
    CHECK(g_seen_ts == 1001, "older shutter should be sent as 1001, got %llu", (unsigned long long)g_seen_ts);
    CHECK(g_seen_readout == 1501, "readout should move by the same amount, got %llu", (unsigned long long)g_seen_readout);
    camera_metadata_t m2 = meta_ts(900);
    hal_result(2, &m2);
    CHECK(g_seen_meta != &m2 && g_seen_meta_ts == 1001, "result timestamp should be 1001, got %lld", (long long)g_seen_meta_ts);
    CHECK(m2.e[0].v == 900, "the HAL's own metadata was modified");
    CHECK(g_live_meta == 0, "metadata copy leaked (%d)", g_live_meta);
    /* a later partial result of the same frame without a timestamp passes as is */
    camera_metadata_t m2b = {0};
    hal_result(2, &m2b);
    CHECK(g_seen_meta == &m2b, "partial result without timestamp should pass unchanged");
    /* a result whose timestamp isn't the re-stamped one is not touched */
    camera_metadata_t m2c = meta_ts(12345);
    hal_result(2, &m2c);
    CHECK(g_seen_meta == &m2c && g_seen_meta_ts == 12345, "unrelated timestamp should not change");

    /* 4. the next real frame is newer than the raised one: unchanged */
    request(p, 3, 0, 0);
    hal_shutter(3, 2000, 2500);
    CHECK(g_seen_ts == 2000, "newer frame changed");

    /* 5. reprocess request (input buffer): exempt in the camera service, passed unchanged */
    request(p, 4, 0, 1);
    hal_shutter(4, 1200, 0);
    CHECK(g_seen_ts == 1200 && g_seen_readout == 0, "reprocess frame should keep its timestamp");

    /* 6. ZSL still capture: exempt, also when the next request repeats the settings (NULL) */
    request(p, 5, &g_set_zsl_still, 0);
    hal_shutter(5, 1300, 1350);
    CHECK(g_seen_ts == 1300, "ZSL still frame should keep its timestamp");
    request(p, 6, 0, 0);
    hal_shutter(6, 1310, 1360);
    CHECK(g_seen_ts == 1310, "repeated ZSL still settings should stay exempt");
    /* still capture without ZSL is not exempt */
    request(p, 7, &g_set_still_only, 0);
    hal_shutter(7, 1320, 1370);
    CHECK(g_seen_ts == 2001, "non-ZSL still should be raised to 2001, got %llu", (unsigned long long)g_seen_ts);

    /* 7. equal timestamp counts as not increasing (camera service uses <=) */
    request(p, 8, &g_set_plain, 0);
    hal_shutter(8, 2001, 0);
    CHECK(g_seen_ts == 2002 && g_seen_readout == 0, "equal timestamp should be raised, readout 0 kept");

    /* 8. a shutter for a frame the wrapper never saw is passed unchanged */
    hal_shutter(99, 5, 5);
    CHECK(g_seen_ts == 5, "unknown frame changed");

    /* 9. timestamp 0 is passed unchanged */
    request(p, 9, 0, 0);
    hal_shutter(9, 0, 0);
    CHECK(g_seen_ts == 0, "zero timestamp changed");

    /* 10. error messages pass through untouched */
    shutter_msg_t err = {1, 0, 10, 0, 7, 7};
    ((provider_cb_t *)g_layer_cb)->notify(g_layer_cb, &err);
    CHECK(g_seen_ts == 7, "error message changed");
    free(p);

    /* 11. disabled with persist.vendor.camera.oplus_los.tsfix=0: provider's own callbacks */
    strcpy(g_prop_tsfix, "0");
    p = new_session(1);
    CHECK(g_layer_cb == &g_prov, "tsfix=0 should give the layer the provider's own callbacks");
    int before = g_layer_requests;
    request(p, 1, &g_set_plain, 0);
    CHECK(g_layer_requests == before + 1, "request not forwarded with tsfix off");
    free(p);
    g_prop_tsfix[0] = 0;

    /* 12. other apps' sessions (Qualcomm's HAL) always get the provider's own callbacks */
    p = new_session(0);
    CHECK(g_layer_cb == &g_prov, "direct session should get the provider's own callbacks");
    CHECK(cb_for(p, 1) == &p->cbw && cb_for(p, 0) == &g_prov, "cb_for by backend type");
    free(p);

    CHECK(g_live_meta == 0, "metadata leaked at end (%d)", g_live_meta);
    if (failures) { printf("%d check(s) failed\n", failures); return 1; }
    printf("oemwrap host test: all checks passed\n");
    return 0;
}
