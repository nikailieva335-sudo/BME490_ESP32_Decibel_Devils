/*
 * Minimal NimBLE GATT server for the MAX4466 sound meter.
 *
 * Service      : 6e400001-a1b2-4c3d-9e8f-0123456789ab
 *   Sound level: 6e400002-...  READ | NOTIFY  (8 bytes: int32 db10, int32 freq_hz, LE)
 *   Errors     : 6e400003-...  READ | NOTIFY  (uint32 bitmask)
 *
 * If your phone app expects the UUIDs from the nRF ble_lib, paste them in below.
 */

#include <string.h>
#include "esp_log.h"
#include "nvs_flash.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"
#include "ble_lib.h"

static const char *TAG = "ble_lib";
#define DEVICE_NAME "MicDB"

/* UUIDs are written little-endian (byte order reversed from the string form) */
static const ble_uuid128_t svc_uuid =
	BLE_UUID128_INIT(0xab, 0x89, 0x67, 0x45, 0x23, 0x01, 0x8f, 0x9e,
			 0x3d, 0x4c, 0xb2, 0xa1, 0x01, 0x00, 0x40, 0x6e);
static const ble_uuid128_t level_uuid =
	BLE_UUID128_INIT(0xab, 0x89, 0x67, 0x45, 0x23, 0x01, 0x8f, 0x9e,
			 0x3d, 0x4c, 0xb2, 0xa1, 0x02, 0x00, 0x40, 0x6e);
static const ble_uuid128_t errors_uuid =
	BLE_UUID128_INIT(0xab, 0x89, 0x67, 0x45, 0x23, 0x01, 0x8f, 0x9e,
			 0x3d, 0x4c, 0xb2, 0xa1, 0x03, 0x00, 0x40, 0x6e);

static uint16_t level_handle;
static uint16_t errors_handle;

static volatile uint16_t conn_handle = BLE_HS_CONN_HANDLE_NONE;
static volatile bool level_notify_on;
static volatile bool errors_notify_on;
static uint8_t own_addr_type;

static uint8_t level_payload[8];
static uint32_t error_flags;

static void start_advertising(void);

/* ---------------- GATT ---------------- */

static int chr_access(uint16_t conn, uint16_t attr_handle,
		      struct ble_gatt_access_ctxt *ctxt, void *arg)
{
	if (ctxt->op != BLE_GATT_ACCESS_OP_READ_CHR) {
		return BLE_ATT_ERR_UNLIKELY;
	}

	int rc;

	if (attr_handle == level_handle) {
		rc = os_mbuf_append(ctxt->om, level_payload, sizeof(level_payload));
	} else {
		rc = os_mbuf_append(ctxt->om, &error_flags, sizeof(error_flags));
	}
	return rc == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
}

static const struct ble_gatt_svc_def gatt_svcs[] = {
	{
		.type = BLE_GATT_SVC_TYPE_PRIMARY,
		.uuid = &svc_uuid.u,
		.characteristics = (struct ble_gatt_chr_def[]) {
			{
				.uuid       = &level_uuid.u,
				.access_cb  = chr_access,
				.flags      = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_NOTIFY,
				.val_handle = &level_handle,
			},
			{
				.uuid       = &errors_uuid.u,
				.access_cb  = chr_access,
				.flags      = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_NOTIFY,
				.val_handle = &errors_handle,
			},
			{ 0 },
		},
	},
	{ 0 },
};

/* ---------------- GAP ---------------- */

static int gap_event(struct ble_gap_event *event, void *arg)
{
	switch (event->type) {
	case BLE_GAP_EVENT_CONNECT:
		if (event->connect.status == 0) {
			conn_handle = event->connect.conn_handle;
			ESP_LOGI(TAG, "Connected");
		} else {
			start_advertising();
		}
		break;

	case BLE_GAP_EVENT_DISCONNECT:
		ESP_LOGI(TAG, "Disconnected (reason %d)", event->disconnect.reason);
		conn_handle = BLE_HS_CONN_HANDLE_NONE;
		level_notify_on = false;
		errors_notify_on = false;
		start_advertising();
		break;

	case BLE_GAP_EVENT_SUBSCRIBE:
		if (event->subscribe.attr_handle == level_handle) {
			level_notify_on = event->subscribe.cur_notify;
		} else if (event->subscribe.attr_handle == errors_handle) {
			errors_notify_on = event->subscribe.cur_notify;
		}
		break;

	case BLE_GAP_EVENT_ADV_COMPLETE:
		start_advertising();
		break;

	default:
		break;
	}
	return 0;
}

static void start_advertising(void)
{
	struct ble_hs_adv_fields fields = { 0 };

	fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
	fields.name = (uint8_t *)DEVICE_NAME;
	fields.name_len = strlen(DEVICE_NAME);
	fields.name_is_complete = 1;

	int rc = ble_gap_adv_set_fields(&fields);
	if (rc != 0) {
		ESP_LOGE(TAG, "adv_set_fields failed (%d)", rc);
		return;
	}

	struct ble_gap_adv_params params = {
		.conn_mode = BLE_GAP_CONN_MODE_UND,
		.disc_mode = BLE_GAP_DISC_MODE_GEN,
	};
	rc = ble_gap_adv_start(own_addr_type, NULL, BLE_HS_FOREVER, &params, gap_event, NULL);
	if (rc != 0 && rc != BLE_HS_EALREADY) {
		ESP_LOGE(TAG, "adv_start failed (%d)", rc);
	}
}

static void on_sync(void)
{
	ble_hs_id_infer_auto(0, &own_addr_type);
	start_advertising();
	ESP_LOGI(TAG, "Advertising as \"%s\"", DEVICE_NAME);
}

static void on_reset(int reason)
{
	ESP_LOGW(TAG, "NimBLE reset (%d)", reason);
}

static void host_task(void *param)
{
	nimble_port_run();              /* Returns only on nimble_port_stop() */
	nimble_port_freertos_deinit();
}

/* ---------------- Public API ---------------- */

int bluetooth_init(void *callbacks)
{
	(void)callbacks;

	esp_err_t err = nvs_flash_init();
	if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
		nvs_flash_erase();
		err = nvs_flash_init();
	}
	if (err != ESP_OK) {
		return err;
	}

	err = nimble_port_init();
	if (err != ESP_OK) {
		return err;
	}

	ble_hs_cfg.sync_cb = on_sync;
	ble_hs_cfg.reset_cb = on_reset;

	ble_svc_gap_init();
	ble_svc_gatt_init();

	int rc = ble_gatts_count_cfg(gatt_svcs);
	if (rc == 0) {
		rc = ble_gatts_add_svcs(gatt_svcs);
	}
	if (rc != 0) {
		return rc;
	}
	ble_svc_gap_device_name_set(DEVICE_NAME);

	nimble_port_freertos_init(host_task);
	return 0;
}

void bluetooth_set_errors(uint32_t flags)
{
	error_flags |= flags;

	if (conn_handle != BLE_HS_CONN_HANDLE_NONE && errors_notify_on) {
		struct os_mbuf *om = ble_hs_mbuf_from_flat(&error_flags, sizeof(error_flags));

		if (om) {
			ble_gatts_notify_custom(conn_handle, errors_handle, om);
		}
	}
}

int bluetooth_send_sound_level(int32_t db10, int32_t freq_hz)
{
	memcpy(&level_payload[0], &db10, 4);       /* ESP32 is little-endian */
	memcpy(&level_payload[4], &freq_hz, 4);

	if (conn_handle == BLE_HS_CONN_HANDLE_NONE || !level_notify_on) {
		return 0;   /* Nobody listening: value is still readable, just not pushed */
	}

	struct os_mbuf *om = ble_hs_mbuf_from_flat(level_payload, sizeof(level_payload));
	if (!om) {
		return BLE_HS_ENOMEM;
	}
	return ble_gatts_notify_custom(conn_handle, level_handle, om);
}