#ifndef WEBM_MUXER_H
#define WEBM_MUXER_H

#include <stdint.h>
#include <stddef.h>

typedef struct WebmMuxer WebmMuxer;

/// Creates a new WebM muxer writing to the given file path
WebmMuxer* webm_muxer_create(const char* path, int width, int height, float fps);

/// Writes a VP9 encoded frame to the WebM file
int webm_muxer_write_frame(WebmMuxer* muxer, const uint8_t* data, size_t size, int64_t timestamp_ns, int is_keyframe);

/// Finalizes and closes the WebM file, returns 0 on success
int webm_muxer_finalize(WebmMuxer* muxer);

#endif
