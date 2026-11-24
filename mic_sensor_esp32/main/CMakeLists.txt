idf_component_register(
	SRCS "main.c" "ble_lib.c"
	INCLUDE_DIRS "."
	PRIV_REQUIRES driver bt nvs_flash
)