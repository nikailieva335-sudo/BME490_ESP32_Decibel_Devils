#pragma once

#include <stdint.h>

/* Error flags reported through the Errors characteristic (bitmask) */
#define ERR_AUDIO_READ (1u << 0)

/*
 * Starts NimBLE and advertises as "MicDB". Returns 0 on success.
 */
int bluetooth_init(void *callbacks);

/* ORs error flags into the Errors characteristic and notifies a subscribed client. */
void bluetooth_set_errors(uint32_t flags);

/*
 * Sends one raw audio frame as MTU-sized notifications. Each notification
 * starts with little-endian uint16 frame_id, sample_offset, sample_count, and
 * sample_rate_hz fields, followed by little-endian int16 samples. Returns 0
 * on success or when nobody listens.
 */
int bluetooth_send_audio_frame(uint16_t frame_id, uint16_t sample_rate_hz,
                               const int16_t *samples, uint16_t sample_count);