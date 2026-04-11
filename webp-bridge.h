#include <webp/encode.h>
#include <vpx/vpx_encoder.h>
#include <vpx/vpx_codec.h>
#include <vpx/vp8cx.h>
#include "webm_muxer.h"

/* Expose macros that Swift can't import directly */
static inline int get_vpx_encoder_abi_version(void) {
    return VPX_ENCODER_ABI_VERSION;
}

static inline int get_vp8e_set_cpuused(void) {
    return VP8E_SET_CPUUSED;
}

static inline vpx_codec_err_t vpx_codec_enc_init_helper(
    vpx_codec_ctx_t *ctx,
    vpx_codec_iface_t *iface,
    const vpx_codec_enc_cfg_t *cfg,
    vpx_codec_flags_t flags
) {
    return vpx_codec_enc_init_ver(ctx, iface, cfg, flags, VPX_ENCODER_ABI_VERSION);
}

static inline vpx_codec_err_t vpx_codec_control_set_cpuused(
    vpx_codec_ctx_t *ctx,
    int value
) {
    return vpx_codec_control_(ctx, VP8E_SET_CPUUSED, value);
}

