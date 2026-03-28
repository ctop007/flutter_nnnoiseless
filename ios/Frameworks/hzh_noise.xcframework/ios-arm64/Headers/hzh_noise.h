#ifndef HZH_NOISE_H
#define HZH_NOISE_H

#include <stdint.h>
#include <stddef.h>

typedef struct FfiByteBuffer {
  uint8_t *ptr;
  size_t len;
  int32_t code;
} FfiByteBuffer;

uint32_t nnnoiseless_target_sample_rate(void);
size_t nnnoiseless_frame_size(void);
size_t nnnoiseless_stream_recommended_input_bytes(uint32_t input_sample_rate, uint32_t num_channels);
int32_t nnnoiseless_denoise_file(const char *input_path, const char *output_path);
void *nnnoiseless_stream_create(uint32_t input_sample_rate, uint32_t num_channels);
FfiByteBuffer nnnoiseless_stream_process(void *stream, const uint8_t *input_ptr, size_t input_len);
FfiByteBuffer nnnoiseless_stream_flush(void *stream);
void nnnoiseless_stream_destroy(void *stream);
void nnnoiseless_buffer_free(uint8_t *ptr, size_t len);
char *nnnoiseless_last_error_message(void);
void nnnoiseless_string_free(char *ptr);

#endif
