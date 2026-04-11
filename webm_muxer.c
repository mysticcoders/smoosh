#include "webm_muxer.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/*
 * Minimal WebM (Matroska subset) muxer for VP9 video-only.
 *
 * WebM is EBML-based. Each element has:
 *   - Element ID (variable length, 1-4 bytes)
 *   - Data size (variable length, 1-8 bytes)
 *   - Data payload
 *
 * We write: EBML Header, Segment (Info, Tracks, Cluster(s)).
 * Cues (seek index) are omitted for simplicity -- players handle this fine
 * for reasonably sized files.
 */

struct WebmMuxer {
    FILE* file;
    int width;
    int height;
    float fps;
    int64_t cluster_timecode;
    long cluster_size_pos;
    long segment_size_pos;
    long segment_data_start;
    int frames_in_cluster;
    int64_t duration_ms;
};

/* Write raw bytes */
static void write_bytes(FILE* f, const uint8_t* data, size_t len) {
    fwrite(data, 1, len, f);
}

/* Write a big-endian unsigned int of exactly `bytes` width */
static void write_uint_be(FILE* f, uint64_t val, int bytes) {
    for (int i = bytes - 1; i >= 0; i--) {
        uint8_t b = (val >> (i * 8)) & 0xFF;
        fwrite(&b, 1, 1, f);
    }
}

/* Write an EBML element ID (already encoded as big-endian bytes) */
static void write_id(FILE* f, uint32_t id) {
    if (id >= 0x1000000) {
        write_uint_be(f, id, 4);
    } else if (id >= 0x10000) {
        write_uint_be(f, id, 3);
    } else if (id >= 0x100) {
        write_uint_be(f, id, 2);
    } else {
        write_uint_be(f, id, 1);
    }
}

/* Write EBML variable-length size (VINT). We use 8-byte form for unknown sizes. */
static void write_size(FILE* f, uint64_t size) {
    if (size < 0x7F) {
        uint8_t b = (uint8_t)(size | 0x80);
        fwrite(&b, 1, 1, f);
    } else if (size < 0x3FFF) {
        uint8_t buf[2];
        buf[0] = (uint8_t)((size >> 8) | 0x40);
        buf[1] = (uint8_t)(size & 0xFF);
        fwrite(buf, 1, 2, f);
    } else if (size < 0x1FFFFF) {
        uint8_t buf[3];
        buf[0] = (uint8_t)((size >> 16) | 0x20);
        buf[1] = (uint8_t)((size >> 8) & 0xFF);
        buf[2] = (uint8_t)(size & 0xFF);
        fwrite(buf, 1, 3, f);
    } else if (size < 0x0FFFFFFF) {
        uint8_t buf[4];
        buf[0] = (uint8_t)((size >> 24) | 0x10);
        buf[1] = (uint8_t)((size >> 16) & 0xFF);
        buf[2] = (uint8_t)((size >> 8) & 0xFF);
        buf[3] = (uint8_t)(size & 0xFF);
        fwrite(buf, 1, 4, f);
    } else {
        /* 8-byte size */
        uint8_t buf[8];
        buf[0] = 0x01;
        buf[1] = (uint8_t)((size >> 48) & 0xFF);
        buf[2] = (uint8_t)((size >> 40) & 0xFF);
        buf[3] = (uint8_t)((size >> 32) & 0xFF);
        buf[4] = (uint8_t)((size >> 24) & 0xFF);
        buf[5] = (uint8_t)((size >> 16) & 0xFF);
        buf[6] = (uint8_t)((size >> 8) & 0xFF);
        buf[7] = (uint8_t)(size & 0xFF);
        fwrite(buf, 1, 8, f);
    }
}

/* Write unknown size marker (used for Segment when we don't know final size yet) */
static void write_unknown_size(FILE* f) {
    /* 8-byte unknown size: 0x01 0xFF 0xFF 0xFF 0xFF 0xFF 0xFF 0xFF */
    uint8_t buf[8] = {0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};
    fwrite(buf, 1, 8, f);
}

/* Write EBML unsigned integer element */
static void write_uint_element(FILE* f, uint32_t id, uint64_t val) {
    int bytes = 1;
    uint64_t tmp = val;
    while (tmp >= 256) { bytes++; tmp >>= 8; }

    write_id(f, id);
    write_size(f, bytes);
    write_uint_be(f, val, bytes);
}

/* Write EBML float element (8-byte double) */
static void write_float_element(FILE* f, uint32_t id, double val) {
    write_id(f, id);
    write_size(f, 8);
    /* Write double as big-endian */
    uint64_t bits;
    memcpy(&bits, &val, 8);
    /* Swap to big-endian */
    uint8_t buf[8];
    for (int i = 0; i < 8; i++) {
        buf[7 - i] = (bits >> (i * 8)) & 0xFF;
    }
    fwrite(buf, 1, 8, f);
}

/* Write EBML string element */
static void write_string_element(FILE* f, uint32_t id, const char* str) {
    size_t len = strlen(str);
    write_id(f, id);
    write_size(f, len);
    fwrite(str, 1, len, f);
}

/* EBML Element IDs */
#define EBML_ID              0x1A45DFA3
#define EBML_VERSION         0x4286
#define EBML_READ_VERSION    0x42F7
#define EBML_MAX_ID_LENGTH   0x42F2
#define EBML_MAX_SIZE_LENGTH 0x42F3
#define DOCTYPE              0x4282
#define DOCTYPE_VERSION      0x4287
#define DOCTYPE_READ_VERSION 0x4285

#define SEGMENT              0x18538067
#define SEGMENT_INFO         0x1549A966
#define TIMECODE_SCALE       0x2AD7B1
#define MUXING_APP           0x4D80
#define WRITING_APP          0x5741
#define DURATION             0x4489

#define TRACKS               0x1654AE6B
#define TRACK_ENTRY          0xAE
#define TRACK_NUMBER         0xD7
#define TRACK_UID            0x73C5
#define TRACK_TYPE           0x83
#define CODEC_ID             0x86
#define CODEC_NAME           0x258688
#define VIDEO                0xE0
#define PIXEL_WIDTH          0xB0
#define PIXEL_HEIGHT         0xBA

#define CLUSTER              0x1F43B675
#define CLUSTER_TIMECODE     0xE7
#define SIMPLE_BLOCK         0xA3

/* Write the initial EBML header and segment start */
static void write_header(WebmMuxer* muxer) {
    FILE* f = muxer->file;

    /* EBML Header */
    long ebml_start = ftell(f);
    write_id(f, EBML_ID);
    long ebml_size_pos = ftell(f);
    write_size(f, 0); /* placeholder */
    long ebml_data_start = ftell(f);

    write_uint_element(f, EBML_VERSION, 1);
    write_uint_element(f, EBML_READ_VERSION, 1);
    write_uint_element(f, EBML_MAX_ID_LENGTH, 4);
    write_uint_element(f, EBML_MAX_SIZE_LENGTH, 8);
    write_string_element(f, DOCTYPE, "webm");
    write_uint_element(f, DOCTYPE_VERSION, 4);
    write_uint_element(f, DOCTYPE_READ_VERSION, 2);

    /* Patch EBML header size */
    long ebml_end = ftell(f);
    uint64_t ebml_len = ebml_end - ebml_data_start;
    fseek(f, ebml_size_pos, SEEK_SET);
    write_size(f, ebml_len);
    fseek(f, ebml_end, SEEK_SET);

    /* Segment (unknown size -- we patch it at finalize) */
    write_id(f, SEGMENT);
    muxer->segment_size_pos = ftell(f);
    write_unknown_size(f);
    muxer->segment_data_start = ftell(f);
}

/* Write Segment Info */
static void write_segment_info(WebmMuxer* muxer) {
    FILE* f = muxer->file;

    /* Buffer the info element to calculate size */
    long info_start = ftell(f);
    write_id(f, SEGMENT_INFO);
    long info_size_pos = ftell(f);
    write_size(f, 0); /* placeholder, we'll use 4-byte size */
    long info_data_start = ftell(f);

    write_uint_element(f, TIMECODE_SCALE, 1000000); /* 1ms */
    write_string_element(f, MUXING_APP, "Smoosh");
    write_string_element(f, WRITING_APP, "Smoosh");

    long info_end = ftell(f);
    uint64_t info_len = info_end - info_data_start;
    fseek(f, info_size_pos, SEEK_SET);
    write_size(f, info_len);
    fseek(f, info_end, SEEK_SET);
}

/* Write Tracks element with a single VP9 video track */
static void write_tracks(WebmMuxer* muxer) {
    FILE* f = muxer->file;

    /* Video sub-element */
    uint8_t video_buf[64];
    FILE* vmem = fmemopen(video_buf, sizeof(video_buf), "w");
    write_uint_element(vmem, PIXEL_WIDTH, muxer->width);
    write_uint_element(vmem, PIXEL_HEIGHT, muxer->height);
    long video_len = ftell(vmem);
    fclose(vmem);

    /* TrackEntry sub-element */
    uint8_t track_buf[256];
    FILE* tmem = fmemopen(track_buf, sizeof(track_buf), "w");
    write_uint_element(tmem, TRACK_NUMBER, 1);
    write_uint_element(tmem, TRACK_UID, 1);
    write_uint_element(tmem, TRACK_TYPE, 1); /* video */
    write_string_element(tmem, CODEC_ID, "V_VP9");
    write_id(tmem, VIDEO);
    write_size(tmem, video_len);
    fwrite(video_buf, 1, video_len, tmem);
    long track_len = ftell(tmem);
    fclose(tmem);

    /* Tracks element */
    write_id(f, TRACKS);
    /* Size = TrackEntry ID + size of size + track data */
    uint8_t tracks_buf[512];
    FILE* trmem = fmemopen(tracks_buf, sizeof(tracks_buf), "w");
    write_id(trmem, TRACK_ENTRY);
    write_size(trmem, track_len);
    fwrite(track_buf, 1, track_len, trmem);
    long tracks_len = ftell(trmem);
    fclose(trmem);

    write_size(f, tracks_len);
    fwrite(tracks_buf, 1, tracks_len, f);
}

/* Start a new Cluster */
static void start_cluster(WebmMuxer* muxer, int64_t timecode_ms) {
    FILE* f = muxer->file;
    muxer->cluster_timecode = timecode_ms;
    muxer->frames_in_cluster = 0;

    write_id(f, CLUSTER);
    muxer->cluster_size_pos = ftell(f);
    write_unknown_size(f);

    write_uint_element(f, CLUSTER_TIMECODE, (uint64_t)timecode_ms);
}

/* Patch the current cluster size and close it */
static void finish_cluster(WebmMuxer* muxer) {
    if (muxer->cluster_size_pos == 0) return;

    FILE* f = muxer->file;
    long cluster_end = ftell(f);
    /* cluster data starts right after the 8-byte unknown size */
    long cluster_data_start = muxer->cluster_size_pos + 8;
    uint64_t cluster_len = cluster_end - cluster_data_start;

    fseek(f, muxer->cluster_size_pos, SEEK_SET);
    /* Write 8-byte VINT size */
    uint8_t buf[8];
    buf[0] = 0x01;
    buf[1] = (uint8_t)((cluster_len >> 48) & 0xFF);
    buf[2] = (uint8_t)((cluster_len >> 40) & 0xFF);
    buf[3] = (uint8_t)((cluster_len >> 32) & 0xFF);
    buf[4] = (uint8_t)((cluster_len >> 24) & 0xFF);
    buf[5] = (uint8_t)((cluster_len >> 16) & 0xFF);
    buf[6] = (uint8_t)((cluster_len >> 8) & 0xFF);
    buf[7] = (uint8_t)(cluster_len & 0xFF);
    fwrite(buf, 1, 8, f);

    fseek(f, cluster_end, SEEK_SET);
    muxer->cluster_size_pos = 0;
}

/* Public API */

WebmMuxer* webm_muxer_create(const char* path, int width, int height, float fps) {
    WebmMuxer* muxer = calloc(1, sizeof(WebmMuxer));
    if (!muxer) return NULL;

    muxer->file = fopen(path, "wb");
    if (!muxer->file) {
        free(muxer);
        return NULL;
    }

    muxer->width = width;
    muxer->height = height;
    muxer->fps = fps;

    write_header(muxer);
    write_segment_info(muxer);
    write_tracks(muxer);

    return muxer;
}

int webm_muxer_write_frame(WebmMuxer* muxer, const uint8_t* data, size_t size, int64_t timestamp_ns, int is_keyframe) {
    if (!muxer || !muxer->file) return -1;

    int64_t timestamp_ms = timestamp_ns / 1000000;
    muxer->duration_ms = timestamp_ms;

    /* Start new cluster on keyframes or every 5 seconds */
    if (muxer->cluster_size_pos == 0 ||
        is_keyframe ||
        (timestamp_ms - muxer->cluster_timecode) > 5000) {
        if (muxer->cluster_size_pos != 0) {
            finish_cluster(muxer);
        }
        start_cluster(muxer, timestamp_ms);
    }

    FILE* f = muxer->file;
    int16_t relative_ts = (int16_t)(timestamp_ms - muxer->cluster_timecode);

    /*
     * SimpleBlock:
     *   - Track number as VINT (0x81 = track 1)
     *   - Timecode relative to cluster (int16 big-endian)
     *   - Flags (0x80 = keyframe, 0x00 = not)
     *   - Frame data
     */
    size_t block_size = 1 + 2 + 1 + size; /* tracknum + timecode + flags + data */

    write_id(f, SIMPLE_BLOCK);
    write_size(f, block_size);

    uint8_t track_num = 0x81; /* VINT for track 1 */
    fwrite(&track_num, 1, 1, f);

    uint8_t ts_buf[2];
    ts_buf[0] = (relative_ts >> 8) & 0xFF;
    ts_buf[1] = relative_ts & 0xFF;
    fwrite(ts_buf, 1, 2, f);

    uint8_t flags = is_keyframe ? 0x80 : 0x00;
    fwrite(&flags, 1, 1, f);

    fwrite(data, 1, size, f);
    muxer->frames_in_cluster++;

    return 0;
}

int webm_muxer_finalize(WebmMuxer* muxer) {
    if (!muxer) return -1;

    if (muxer->cluster_size_pos != 0) {
        finish_cluster(muxer);
    }

    /* Patch segment size */
    long file_end = ftell(muxer->file);
    uint64_t segment_len = file_end - muxer->segment_data_start;
    fseek(muxer->file, muxer->segment_size_pos, SEEK_SET);
    uint8_t buf[8];
    buf[0] = 0x01;
    buf[1] = (uint8_t)((segment_len >> 48) & 0xFF);
    buf[2] = (uint8_t)((segment_len >> 40) & 0xFF);
    buf[3] = (uint8_t)((segment_len >> 32) & 0xFF);
    buf[4] = (uint8_t)((segment_len >> 24) & 0xFF);
    buf[5] = (uint8_t)((segment_len >> 16) & 0xFF);
    buf[6] = (uint8_t)((segment_len >> 8) & 0xFF);
    buf[7] = (uint8_t)(segment_len & 0xFF);
    fwrite(buf, 1, 8, muxer->file);

    fclose(muxer->file);
    muxer->file = NULL;

    free(muxer);
    return 0;
}
