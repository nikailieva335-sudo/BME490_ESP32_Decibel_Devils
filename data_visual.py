import asyncio
import threading
import time
from collections import deque

import matplotlib.pyplot as plt
from matplotlib.animation import FuncAnimation
from bleak import BleakClient, BleakScanner

DEVICE_NAME = "MicDB"                                    # name the ESP32 advertises
SOUND_UUID = "6e400002-a1b2-4c3d-9e8f-0123456789ab"      # sound-level characteristic on the ESP32
WINDOW_SECONDS = 30
Y_MIN, Y_MAX = -5, 50          # dB relative to the quiet room at startup
TARGET_LOW, TARGET_HIGH = 10, 20
readings = deque(maxlen=1000)  # ~50 s of data at 20 packets/s
status = {"text": "Starting..."}


def on_data(_, data):
    if len(data) != 8:
        return

    db = int.from_bytes(data[0:4], "little", signed=True) / 10
    frequency = int.from_bytes(data[4:8], "little", signed=True)
    readings.append((time.monotonic(), db, frequency))


async def ble_task():
    """Find the ESP32, subscribe, and reconnect automatically if the link drops."""
    while True:
        status["text"] = f"Scanning for {DEVICE_NAME}..."
        print(status["text"])
        device = await BleakScanner.find_device_by_name(DEVICE_NAME, timeout=15)
        if device is None:
            print("Board not found. Is it powered, advertising, and not "
                  "connected to your phone?")
            continue

        try:
            async with BleakClient(device) as client:
                status["text"] = "Connected"
                print("Connected. Close the graph window to quit.")
                await client.start_notify(SOUND_UUID, on_data)
                while client.is_connected:
                    await asyncio.sleep(0.5)
        except Exception as e:  # keep retrying on any BLE error
            print("BLE error:", e)

        status["text"] = "Disconnected, reconnecting..."
        print(status["text"])
        await asyncio.sleep(1)


def update(_):
    now = time.monotonic()
    recent = [(t - now, db, f) for t, db, f in list(readings)
              if now - t <= WINDOW_SECONDS]

    if not recent:
        ax_db.set_title(status["text"])
        return

    xs, dbs, freqs = zip(*recent)
    db_line.set_data(xs, dbs)
    freq_line.set_data(xs, freqs)

    # Frequency range isn't known ahead of time, so rescale its y-axis
    ax_freq.relim()
    ax_freq.autoscale_view(scalex=False)

    _, db, frequency = readings[-1]
    ax_db.set_title(f"{db:.1f} dB")          # top graph title
    ax_freq.set_title(f"{frequency} Hz")     # bottom graph title


threading.Thread(target=lambda: asyncio.run(ble_task()), daemon=True).start()

fig, (ax_db, ax_freq) = plt.subplots(2, 1, sharex=True, figsize=(8, 6))

# Decibel plot (top)
(db_line,) = ax_db.plot([], [], linewidth=2)
ax_db.axhspan(TARGET_LOW, TARGET_HIGH, color="green", alpha=0.2)
ax_db.set_xlim(-WINDOW_SECONDS, 0)
ax_db.set_ylim(Y_MIN, Y_MAX)
ax_db.set_ylabel("Level (dB vs. quiet room)")

# Frequency plot (bottom)
(freq_line,) = ax_freq.plot([], [], linewidth=2, color="tab:orange")
ax_freq.set_xlabel("Seconds")
ax_freq.set_ylabel("Frequency (Hz)")

fig.tight_layout()
anim = FuncAnimation(fig, update, interval=100, cache_frame_data=False)
plt.show()
 