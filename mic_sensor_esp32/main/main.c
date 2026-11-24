#include <stdint.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include "driver/i2s_std.h"
#include "ble_lib.h"

static const char *TAG = "mic_db";

#define MIC_I2S_PORT        I2S_NUM_0
#define MIC_I2S_BCLK        GPIO_NUM_14
#define MIC_I2S_WS          GPIO_NUM_25
#define MIC_I2S_DATA        GPIO_NUM_26

#define SAMPLE_RATE_HZ      8000
#define NUM_SAMPLES         512

static int16_t samples[NUM_SAMPLES];
static i2s_chan_handle_t i2s_rx_handle;

static esp_err_t i2s_init(void)
{
    i2s_chan_config_t chan_cfg =
        I2S_CHANNEL_DEFAULT_CONFIG(MIC_I2S_PORT, I2S_ROLE_MASTER);

    esp_err_t err = i2s_new_channel(&chan_cfg, NULL, &i2s_rx_handle);
    if (err != ESP_OK) {
        return err;
    }

    const i2s_std_config_t std_cfg = {
        .clk_cfg = I2S_STD_CLK_DEFAULT_CONFIG(SAMPLE_RATE_HZ),
        .slot_cfg = I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(
            I2S_DATA_BIT_WIDTH_32BIT, I2S_SLOT_MODE_MONO),
        .gpio_cfg = {
            .mclk = I2S_GPIO_UNUSED,
            .bclk = MIC_I2S_BCLK,
            .ws = MIC_I2S_WS,
            .dout = I2S_GPIO_UNUSED,
            .din = MIC_I2S_DATA,
        },
    };

    err = i2s_channel_init_std_mode(i2s_rx_handle, &std_cfg);
    if (err != ESP_OK) {
        return err;
    }

    return i2s_channel_enable(i2s_rx_handle);
}

static esp_err_t read_window(void)
{
    static int32_t raw[NUM_SAMPLES];
    size_t bytes_read = 0;
    int n = 0;

    while (n < NUM_SAMPLES) {
        esp_err_t err = i2s_channel_read(
            i2s_rx_handle,
            raw,
            sizeof(raw),
            &bytes_read,
            1000);

        if (err != ESP_OK) {
            return err;
        }

        for (size_t i = 0;
             i < bytes_read / sizeof(raw[0]) && n < NUM_SAMPLES;
             i++) {
            /* INMP441 sends 24-bit samples left-justified in 32 bits. */
            samples[n++] = (int16_t)(raw[i] >> 16);
        }
    }

    return ESP_OK;
}

void app_main(void)
{
    int bt_err = bluetooth_init(NULL);
    if (bt_err != 0) {
        ESP_LOGE(TAG, "Bluetooth initialization failed (%d)", bt_err);
        return;
    }

    esp_err_t err = i2s_init();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "I2S init failed (%s)", esp_err_to_name(err));
        return;
    }

    ESP_LOGI(TAG, "Streaming I2S audio frames to the visualization app");

    uint16_t frame_id = 0;
    while (1) {
        err = read_window();
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "I2S read failed (%s)", esp_err_to_name(err));
            bluetooth_set_errors(ERR_AUDIO_READ);
            continue;
        }

        int ble_err = bluetooth_send_audio_frame(
            frame_id++, SAMPLE_RATE_HZ, samples, NUM_SAMPLES);
        if (ble_err != 0) {
            ESP_LOGW(TAG, "Audio frame send failed (%d)", ble_err);
        }
    }
}
