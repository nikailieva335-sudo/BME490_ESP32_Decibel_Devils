#pragma once

#include <stdint.h>

/* Error flags reported through the Errors characteristic (bitmask) */
#define ERR_ADC_READ   (1u << 0)

/*
 * Starts NimBLE and advertises as "MicDB".
 * `callbacks` is unused (kept so the call matches the nRF version). Returns 0 on success.
 */
int bluetooth_init(void *callbacks);

/* ORs error flags into the Errors characteristic and notifies a subscribed client. */
void bluetooth_set_errors(uint32_t flags);

/*
 * Sends a sound-level packet: 8 bytes, little-endian
 *   int32 db10    (dB x 10, e.g. 124 = 12.4 dB)
 *   int32 freq_hz
 * Returns 0 on success (or when no client is subscribed), non-zero NimBLE error otherwise.
 */
int bluetooth_send_sound_level(int32_t db10, int32_t freq_hz);