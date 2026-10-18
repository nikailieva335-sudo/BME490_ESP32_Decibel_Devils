idf_component_register(
	SRCS "main.c" "ble_lib.c"
	INCLUDE_DIRS "."
	PRIV_REQUIRES esp_adc bt nvs_flash
)