// #include <math.h>
// #include <string.h>
// #include "freertos/FreeRTOS.h"
// #include "freertos/task.h"
// #include "esp_log.h"
// #include "esp_adc/adc_continuous.h"
// #include "esp_adc/adc_cali.h"
// #include "esp_adc/adc_cali_scheme.h"
// #include "ble_lib.h"

// static const char *TAG = "mic_db";

// #define MIC_ADC_UNIT        ADC_UNIT_1
// #define MIC_ADC_CHANNEL     ADC_CHANNEL_6        /* GPIO34 on ESP32, GPIO7 on ESP32-S3 */
// #define MIC_ADC_ATTEN       ADC_ATTEN_DB_12      /* ~0–3.1 V input range */

// #define SAMPLE_RATE_HZ      20000
// #define NUM_SAMPLES         1000
// #define SEND_DATA_WINDOWS   1

// #define SPL_CALIBRATION_DB       70.0f
// #define SPL_CALIBRATION_VRMS_MV  70.0f

// #define READ_CHUNK_BYTES    256


// #if CONFIG_IDF_TARGET_ESP32 || CONFIG_IDF_TARGET_ESP32S2
// #define ADC_OUTPUT_TYPE         ADC_DIGI_OUTPUT_FORMAT_TYPE1
// #define ADC_GET_CHANNEL(p)      ((p)->type1.channel)
// #define ADC_GET_DATA(p)         ((p)->type1.data)
// #else
// #define ADC_OUTPUT_TYPE         ADC_DIGI_OUTPUT_FORMAT_TYPE2
// #define ADC_GET_CHANNEL(p)      ((p)->type2.channel)
// #define ADC_GET_DATA(p)         ((p)->type2.data)
// #endif

// static adc_continuous_handle_t adc_handle;
// static int16_t samples[NUM_SAMPLES];


// static esp_err_t adc_init(void)
// {
// 	adc_continuous_handle_cfg_t handle_cfg = {
// 		.max_store_buf_size = 4096,
// 		.conv_frame_size    = READ_CHUNK_BYTES,
// 	};
// 	esp_err_t err = adc_continuous_new_handle(&handle_cfg, &adc_handle);
// 	if (err != ESP_OK) {
// 		return err;
// 	}

// 	adc_digi_pattern_config_t pattern = {
// 		.atten     = MIC_ADC_ATTEN,
// 		.channel   = MIC_ADC_CHANNEL,
// 		.unit      = MIC_ADC_UNIT,
// 		.bit_width = SOC_ADC_DIGI_MAX_BITWIDTH,
// 	};
// 	adc_continuous_config_t dig_cfg = {
// 		.sample_freq_hz = SAMPLE_RATE_HZ,
// 		.conv_mode      = ADC_CONV_SINGLE_UNIT_1,
// 		.format         = ADC_OUTPUT_TYPE,
// 		.pattern_num    = 1,
// 		.adc_pattern    = &pattern,
// 	};
// 	err = adc_continuous_config(adc_handle, &dig_cfg);
// 	if (err != ESP_OK) {
// 		return err;
// 	}

// 	return adc_continuous_start(adc_handle);
// }

// /* mV per ADC step, using eFuse calibration when available (only used for logging) */
// static float compute_mv_per_step(void)
// {
// 	adc_cali_handle_t cali = NULL;
// 	esp_err_t ret = ESP_FAIL;

// #if ADC_CALI_SCHEME_CURVE_FITTING_SUPPORTED
// 	adc_cali_curve_fitting_config_t cfg = {
// 		.unit_id  = MIC_ADC_UNIT,
// 		.chan     = MIC_ADC_CHANNEL,
// 		.atten    = MIC_ADC_ATTEN,
// 		.bitwidth = ADC_BITWIDTH_12,
// 	};
// 	ret = adc_cali_create_scheme_curve_fitting(&cfg, &cali);
// #elif ADC_CALI_SCHEME_LINE_FITTING_SUPPORTED
// 	adc_cali_line_fitting_config_t cfg = {
// 		.unit_id  = MIC_ADC_UNIT,
// 		.atten    = MIC_ADC_ATTEN,
// 		.bitwidth = ADC_BITWIDTH_12,
// 	};
// 	ret = adc_cali_create_scheme_line_fitting(&cfg, &cali);
// #endif

// 	int full_scale_mv = 3100;
// 	if (ret == ESP_OK) {
// 		adc_cali_raw_to_voltage(cali, 4095, &full_scale_mv);
// 	} else {
// 		ESP_LOGW(TAG, "No ADC calibration available, using nominal %d mV full scale", full_scale_mv);
// 	}
// 	return full_scale_mv / 4095.0f;
// }


// static esp_err_t read_window(void)
// {
// 	uint8_t raw[READ_CHUNK_BYTES];
// 	int n = 0;

// 	/* Drop stale data that piled up while we were processing / sending */
// 	adc_continuous_flush_pool(adc_handle);

// 	while (n < NUM_SAMPLES) {
// 		uint32_t got = 0;
// 		esp_err_t err = adc_continuous_read(adc_handle, raw, sizeof(raw), &got, 200);

// 		if (err != ESP_OK) {
// 			return err;
// 		}
// 		for (uint32_t i = 0; i + SOC_ADC_DIGI_RESULT_BYTES <= got && n < NUM_SAMPLES;
// 		     i += SOC_ADC_DIGI_RESULT_BYTES) {
// 			adc_digi_output_data_t *p = (adc_digi_output_data_t *)&raw[i];

// 			if (ADC_GET_CHANNEL(p) == MIC_ADC_CHANNEL) {
// 				samples[n++] = (int16_t)ADC_GET_DATA(p);
// 			}
// 		}
// 	}
// 	return ESP_OK;
// }


// static float window_mean(void)
// {
// 	float mean = 0.0f;

// 	for (int i = 0; i < NUM_SAMPLES; i++) {
// 		mean += samples[i];
// 	}
// 	return mean / NUM_SAMPLES;
// }


// static float window_rms(void)
// {
// 	float mean = window_mean();
// 	float sum_sq = 0.0f;

// 	for (int i = 0; i < NUM_SAMPLES; i++) {
// 		float d = samples[i] - mean;

// 		sum_sq += d * d;
// 	}
// 	return sqrtf(sum_sq / NUM_SAMPLES);
// }


// static int window_peak_count(void)
// {
// 	float mean = window_mean();
// 	float threshold = mean + 0.25f * window_rms();
// 	int peaks = 0;

// 	for (int i = 1; i < NUM_SAMPLES - 1; i++) {
// 		if (samples[i] > threshold &&
// 		    samples[i] >= samples[i - 1] &&
// 		    samples[i] > samples[i + 1]) {
// 			peaks++;
// 		}
// 	}
// 	return peaks;
// }


// static float window_frequency_hz(void)
// {
// 	float window_seconds = (float)NUM_SAMPLES / (float)SAMPLE_RATE_HZ;

// 	return window_peak_count() / window_seconds;
// }

// /* ---------------- Main ---------------- */

// void app_main(void)
// {
// 	esp_err_t err;

// 	if (bluetooth_init(NULL) != 0) {
// 		ESP_LOGE(TAG, "Bluetooth initialization failed");
// 		return;
// 	}

// 	err = adc_init();
// 	if (err != ESP_OK) {
// 		ESP_LOGE(TAG, "ADC init failed (%s)", esp_err_to_name(err));
// 		return;
// 	}

// 	float mv_per_step = compute_mv_per_step();
// 	ESP_LOGI(TAG, "SPL calibration: %.1f dB at %.1f mVrms",
// 		 SPL_CALIBRATION_DB, SPL_CALIBRATION_VRMS_MV);

// 	while (1) {
// 		float rms_sum = 0.0f;
// 		float frequency_sum = 0.0f;
// 		int good_windows = 0;

// 		for (int w = 0; w < SEND_DATA_WINDOWS; w++) {
// 			err = read_window();
// 			if (err != ESP_OK) {
// 				ESP_LOGE(TAG, "Could not read (%s)", esp_err_to_name(err));
// 				bluetooth_set_errors(ERR_ADC_READ);
// 				continue;
// 			}
// 			rms_sum += window_rms();
// 			frequency_sum += window_frequency_hz();
// 			good_windows++;
// 		}

// 		if (good_windows == 0) {
// 			vTaskDelay(pdMS_TO_TICKS(50));
// 			continue;
// 		}

// 		float rms = rms_sum / good_windows;
// 		float frequency_hz = frequency_sum / good_windows;
// 		float vrms_mv = rms * mv_per_step;

// 		if (vrms_mv < 0.01f) {
// 			vrms_mv = 0.01f;
// 		}

// 		float db = SPL_CALIBRATION_DB
// 			   + 20.0f * log10f(vrms_mv / SPL_CALIBRATION_VRMS_MV);

// 		ESP_LOGI(TAG, "Vrms: %6.2f mV   level: %5.1f dB   frequency: %5.0f Hz",
// 			 vrms_mv, db, frequency_hz);

// 		/* Round to the nearest tenth of a dB, e.g. 12.43 -> 124 */
// 		int32_t db10 = (int32_t)(db * 10.0f + (db >= 0.0f ? 0.5f : -0.5f));

// 		int ble_err = bluetooth_send_sound_level(db10, (int32_t)(frequency_hz + 0.5f));
// 		if (ble_err) {
// 			ESP_LOGW(TAG, "BLE send failed (%d)", ble_err);
// 		}
// 	}
// }



#include <math.h>
#include <stdint.h>
#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include "esp_adc/adc_continuous.h"
#include "esp_adc/adc_cali.h"
#include "esp_adc/adc_cali_scheme.h"
#include "ble_lib.h"

static const char *TAG = "mic_db";

#define MIC_ADC_UNIT        ADC_UNIT_1
#define MIC_ADC_CHANNEL     ADC_CHANNEL_6
#define MIC_ADC_ATTEN       ADC_ATTEN_DB_12

#define SAMPLE_RATE_HZ      20000
#define NUM_SAMPLES         1000
#define CAL_WINDOWS         40
#define SEND_DATA_WINDOWS   1
#define FREQUENCY_AVG_WINDOW 3

#define READ_CHUNK_BYTES    256
#define MIN_VOICE_FREQ_HZ   60
#define MAX_VOICE_FREQ_HZ   1200

#define YIN_THRESHOLD       0.20f
#define MIN_VOICED_RMS_COUNTS  5.0f

#define MIN_LAG (SAMPLE_RATE_HZ / MAX_VOICE_FREQ_HZ)
#define MAX_LAG (SAMPLE_RATE_HZ / MIN_VOICE_FREQ_HZ)

#if CONFIG_IDF_TARGET_ESP32 || CONFIG_IDF_TARGET_ESP32S2
#define ADC_OUTPUT_TYPE     ADC_DIGI_OUTPUT_FORMAT_TYPE1
#define ADC_GET_CHANNEL(p)  ((p)->type1.channel)
#define ADC_GET_DATA(p)     ((p)->type1.data)
#else
#define ADC_OUTPUT_TYPE     ADC_DIGI_OUTPUT_FORMAT_TYPE2
#define ADC_GET_CHANNEL(p)  ((p)->type2.channel)
#define ADC_GET_DATA(p)     ((p)->type2.data)
#endif

static adc_continuous_handle_t adc_handle;

static int16_t samples[NUM_SAMPLES];
static float yin_cmnd[MAX_LAG + 2];
static float frequency_history[FREQUENCY_AVG_WINDOW];
static int frequency_history_count;
static int frequency_history_next;

static esp_err_t adc_init(void)
{
    adc_continuous_handle_cfg_t handle_cfg = {
        .max_store_buf_size = 4096,
        .conv_frame_size = READ_CHUNK_BYTES,
    };

    esp_err_t err =
        adc_continuous_new_handle(&handle_cfg, &adc_handle);

    if (err != ESP_OK) {
        return err;
    }

    adc_digi_pattern_config_t pattern = {
        .atten = MIC_ADC_ATTEN,
        .channel = MIC_ADC_CHANNEL,
        .unit = MIC_ADC_UNIT,
        .bit_width = SOC_ADC_DIGI_MAX_BITWIDTH,
    };

    adc_continuous_config_t dig_cfg = {
        .sample_freq_hz = SAMPLE_RATE_HZ,
        .conv_mode = ADC_CONV_SINGLE_UNIT_1,
        .format = ADC_OUTPUT_TYPE,
        .pattern_num = 1,
        .adc_pattern = &pattern,
    };

    err = adc_continuous_config(adc_handle, &dig_cfg);
    if (err != ESP_OK) {
        return err;
    }

    return adc_continuous_start(adc_handle);
}


static float compute_mv_per_step(void)
{
    adc_cali_handle_t cali = NULL;
    esp_err_t ret = ESP_FAIL;

#if ADC_CALI_SCHEME_CURVE_FITTING_SUPPORTED
    adc_cali_curve_fitting_config_t cfg = {
        .unit_id = MIC_ADC_UNIT,
        .chan = MIC_ADC_CHANNEL,
        .atten = MIC_ADC_ATTEN,
        .bitwidth = ADC_BITWIDTH_12,
    };

    ret = adc_cali_create_scheme_curve_fitting(&cfg, &cali);

#elif ADC_CALI_SCHEME_LINE_FITTING_SUPPORTED
    adc_cali_line_fitting_config_t cfg = {
        .unit_id = MIC_ADC_UNIT,
        .atten = MIC_ADC_ATTEN,
        .bitwidth = ADC_BITWIDTH_12,
    };

    ret = adc_cali_create_scheme_line_fitting(&cfg, &cali);
#endif

    int full_scale_mv = 3100;

    if (ret == ESP_OK) {
        if (adc_cali_raw_to_voltage(
                cali, 4095, &full_scale_mv) != ESP_OK) {
            full_scale_mv = 3100;
        }
    } else {
        ESP_LOGW(TAG,
                 "No ADC calibration; using nominal %d mV",
                 full_scale_mv);
    }

    /* Calibration handle remains allocated for this application. */
    return full_scale_mv / 4095.0f;
}


static esp_err_t read_window(void)
{
    uint8_t raw[READ_CHUNK_BYTES];
    int n = 0;

    /* Discard buffered samples left over from previous processing. */
    esp_err_t flush_err = adc_continuous_flush_pool(adc_handle);
    if (flush_err != ESP_OK) {
        ESP_LOGW(TAG, "ADC buffer flush failed: %s",
                 esp_err_to_name(flush_err));
    }

    while (n < NUM_SAMPLES) {
        uint32_t got = 0;

        esp_err_t err = adc_continuous_read(
            adc_handle, raw, sizeof(raw), &got, 200);

        if (err != ESP_OK) {
            return err;
        }

        for (uint32_t i = 0;
             i + SOC_ADC_DIGI_RESULT_BYTES <= got &&
             n < NUM_SAMPLES;
             i += SOC_ADC_DIGI_RESULT_BYTES) {

            adc_digi_output_data_t *p =
                (adc_digi_output_data_t *)&raw[i];

            if (ADC_GET_CHANNEL(p) == MIC_ADC_CHANNEL) {
                samples[n++] = (int16_t)ADC_GET_DATA(p);
            }
        }
    }

    return ESP_OK;
}


static float window_mean(void)
{
    float sum = 0.0f;

    for (int i = 0; i < NUM_SAMPLES; i++) {
        sum += samples[i];
    }

    return sum / NUM_SAMPLES;
}

static float window_rms(void)
{
    float mean = window_mean();
    float sum_sq = 0.0f;

    for (int i = 0; i < NUM_SAMPLES; i++) {
        float x = (float)samples[i] - mean;
        sum_sq += x * x;
    }

    return sqrtf(sum_sq / NUM_SAMPLES);
}

/* ---------------- YIN fundamental-frequency detector ---------------- */

/*
 * Returns fundamental frequency in Hz.
 *
 * Returns 0 when:
 *   - the signal is too quiet;
 *   - no convincing periodic pitch is found;
 *   - the pitch falls outside the configured range.
 *
 * YIN uses a difference function and cumulative mean normalized
 * difference (CMND), rather than counting waveform peaks.
 */
static float window_frequency_hz(void)
{
    float mean = window_mean();
    float rms = window_rms();

    /* Silence / insufficient signal: pitch is undefined. */
    if (rms < MIN_VOICED_RMS_COUNTS) {
        return 0.0f;
    }

    yin_cmnd[0] = 1.0f;

    float running_sum = 0.0f;

    /*
     * Difference function:
     * d(tau) = sum((x[i] - x[i + tau])^2)
     *
     * The DC mean cancels in the subtraction, but removing it
     * makes the signal interpretation explicit.
     */
    for (int tau = 1; tau <= MAX_LAG; tau++) {
        float diff_sum = 0.0f;
        int count = NUM_SAMPLES - tau;

        for (int i = 0; i < count; i++) {
            float a = (float)samples[i] - mean;
            float b = (float)samples[i + tau] - mean;
            float d = a - b;

            diff_sum += d * d;
        }

        running_sum += diff_sum;

        if (running_sum > 1e-12f) {
            yin_cmnd[tau] =
                diff_sum * tau / running_sum;
        } else {
            yin_cmnd[tau] = 1.0f;
        }
    }

    /*
     * Find the first plausible period whose normalized difference
     * is below the threshold. Then descend to the local minimum.
     *
     * Searching for the first acceptable minimum helps reduce
     * errors where a later multiple of the true period is selected.
     */
    int selected_lag = -1;

    for (int tau = MIN_LAG; tau <= MAX_LAG; tau++) {
        if (yin_cmnd[tau] < YIN_THRESHOLD) {
            while (tau < MAX_LAG &&
                   yin_cmnd[tau + 1] < yin_cmnd[tau]) {
                tau++;
            }

            selected_lag = tau;
            break;
        }
    }

    /*
     * No sufficiently convincing periodicity.
     * Do not report a fabricated frequency for unvoiced speech.
     */
    if (selected_lag < 0) {
        return 0.0f;
    }

    /*
     * Parabolic interpolation around the minimum improves
     * frequency precision beyond integer-sample lag resolution.
     */
    float lag = (float)selected_lag;

    if (selected_lag > 1 && selected_lag < MAX_LAG) {
        float left = yin_cmnd[selected_lag - 1];
        float center = yin_cmnd[selected_lag];
        float right = yin_cmnd[selected_lag + 1];

        float denom = left - 2.0f * center + right;

        if (fabsf(denom) > 1e-12f) {
            float correction = 0.5f * (left - right) / denom;

            /* Keep interpolation local to the selected sample. */
            if (correction > 1.0f) correction = 1.0f;
            if (correction < -1.0f) correction = -1.0f;

            lag += correction;
        }
    }

    if (lag <= 0.0f) {
        return 0.0f;
    }

    float frequency = SAMPLE_RATE_HZ / lag;

    if (frequency < MIN_VOICE_FREQ_HZ ||
        frequency > MAX_VOICE_FREQ_HZ) {
        return 0.0f;
    }

    return frequency;
}

static float smooth_frequency_hz(float frequency)
{
    if (frequency <= 0.0f) {
        frequency_history_count = 0;
        frequency_history_next = 0;
        return 0.0f;
    }

    frequency_history[frequency_history_next] = frequency;
    frequency_history_next =
        (frequency_history_next + 1) % FREQUENCY_AVG_WINDOW;

    if (frequency_history_count < FREQUENCY_AVG_WINDOW) {
        frequency_history_count++;
    }

    float sum = 0.0f;
    for (int i = 0; i < frequency_history_count; i++) {
        sum += frequency_history[i];
    }

    return sum / frequency_history_count;
}

/* ---------------- Main ---------------- */

void app_main(void)
{
    esp_err_t err;

    if (bluetooth_init(NULL) != 0) {
        ESP_LOGE(TAG, "Bluetooth initialization failed");
        return;
    }

    err = adc_init();

    if (err != ESP_OK) {
        ESP_LOGE(TAG, "ADC init failed (%s)",
                 esp_err_to_name(err));
        return;
    }

    float mv_per_step = compute_mv_per_step();

    /*
     * Calibrate the ambient noise reference for relative dB only.
     * This is not an absolute dB SPL calibration.
     */
    ESP_LOGI(TAG, "Calibrating: keep quiet for about 2 seconds...");
    vTaskDelay(pdMS_TO_TICKS(500));

    float ref_sum = 0.0f;

    for (int w = 0; w < CAL_WINDOWS; w++) {
        err = read_window();

        if (err != ESP_OK) {
            ESP_LOGE(TAG, "Calibration read failed (%s)",
                     esp_err_to_name(err));
            return;
        }

        ref_sum += window_rms();
    }

    float rms_ref = ref_sum / CAL_WINDOWS;

    if (rms_ref < 0.5f) {
        rms_ref = 0.5f;
    }

    ESP_LOGI(TAG, "Reference Vrms: %.2f mV",
             rms_ref * mv_per_step);

    while (1) {
        float rms_sum = 0.0f;
        float frequency_sum = 0.0f;
        int good_windows = 0;
        int voiced_windows = 0;

        for (int w = 0; w < SEND_DATA_WINDOWS; w++) {
            err = read_window();

            if (err != ESP_OK) {
                ESP_LOGE(TAG, "ADC read failed (%s)",
                         esp_err_to_name(err));

                bluetooth_set_errors(ERR_ADC_READ);
                continue;
            }

            float rms = window_rms();
            float frequency = window_frequency_hz();

            rms_sum += rms;
            good_windows++;

            if (frequency > 0.0f) {
                frequency_sum += frequency;
                voiced_windows++;
            }
        }

        if (good_windows == 0) {
            vTaskDelay(pdMS_TO_TICKS(50));
            continue;
        }

        float rms = rms_sum / good_windows;

        /* Zero means no valid voiced pitch was detected. */
        float frequency_hz = 0.0f;

        if (voiced_windows > 0) {
            frequency_hz = frequency_sum / voiced_windows;
        }
        frequency_hz = smooth_frequency_hz(frequency_hz);

        if (rms < 0.01f) {
            rms = 0.01f;
        }

        float db = 20.0f * log10f(rms / rms_ref);

        ESP_LOGI(TAG,
                 "Vrms: %6.2f mV  level: %5.1f dB  "
                 "voice F0: %5.1f Hz  voiced: %d/%d",
                 rms * mv_per_step,
                 db,
                 frequency_hz,
                 voiced_windows,
                 good_windows);

        int32_t db10 = (int32_t)(
            db * 10.0f + (db >= 0.0f ? 0.5f : -0.5f));

        int32_t pitch_hz = (int32_t)(frequency_hz + 0.5f);

        int ble_err = bluetooth_send_sound_level(
            db10, pitch_hz);

        if (ble_err) {
            ESP_LOGW(TAG, "BLE send failed (%d)", ble_err);
        }
    }
}
