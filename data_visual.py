import asyncio
import math
import queue
import struct
import threading
import time
from collections import deque

import matplotlib.pyplot as plt
import numpy as np
from bleak import BleakClient, BleakScanner
from matplotlib.animation import FuncAnimation

DEVICE_NAME = "MicDB"
SOUND_UUID = "6e400002-a1b2-4c3d-9e8f-0123456789ab"
WINDOW_SECONDS = 30
Y_MIN, Y_MAX = -100, 0

# Set to (known SPL in dB) - (measured dBFS) using a sound-level calibrator
# or a reference meter placed beside the microphone. Leave None for raw dBFS.
SPL_CALIBRATION_OFFSET_DB = 107.0

SAMPLE_RATE_HZ = 8000
FRAME_SAMPLES = 512
FREQUENCY_AVG_WINDOW = 7
MIN_VOICE_FREQ_HZ = 60
MAX_VOICE_FREQ_HZ = 1200
YIN_THRESHOLD = 0.30
HIGHPASS_CUTOFF_HZ = 80.0
MIN_LAG = int(SAMPLE_RATE_HZ / MAX_VOICE_FREQ_HZ)
MAX_LAG = int(SAMPLE_RATE_HZ / MIN_VOICE_FREQ_HZ)

readings = deque(maxlen=2000)
readings_lock = threading.Lock()
audio_frames = queue.Queue(maxsize=16)
frame_lock = threading.Lock()
partial_frames = {}
status = {"text": "Starting..."}
ax_db = None
ax_freq = None
db_line = None
freq_line = None


def on_data(_, data):
    if len(data) < 10:
        return

    frame_id, offset, sample_count, sample_rate = struct.unpack_from(
        "<HHHH", data
    )
    sample_data = data[8:]
    if (
        sample_count != FRAME_SAMPLES
        or sample_rate != SAMPLE_RATE_HZ
        or len(sample_data) % 2
    ):
        return

    samples = np.frombuffer(sample_data, dtype="<i2")
    end = offset + len(samples)
    if end > FRAME_SAMPLES:
        return

    with frame_lock:
        frame = partial_frames.get(frame_id)
        if frame is None:
            frame = {
                "samples": np.empty(FRAME_SAMPLES, dtype=np.int16),
                "received": np.zeros(FRAME_SAMPLES, dtype=bool),
            }
            partial_frames[frame_id] = frame

        frame["samples"][offset:end] = samples
        frame["received"][offset:end] = True

        if frame["received"].all():
            del partial_frames[frame_id]
            try:
                audio_frames.put_nowait(frame["samples"].copy())
            except queue.Full:
                try:
                    audio_frames.get_nowait()
                except queue.Empty:
                    pass
                try:
                    audio_frames.put_nowait(frame["samples"].copy())
                except queue.Full:
                    status["text"] = "Audio processing queue full; dropping frames"

        while len(partial_frames) > 4:
            del partial_frames[next(iter(partial_frames))]


def estimate_frequency(samples):
    """Estimate the voiced fundamental in Hz with YIN; return zero if unvoiced."""
    mean_removed = samples.astype(np.float64) - float(np.mean(samples))

    w0 = 2.0 * math.pi * HIGHPASS_CUTOFF_HZ / SAMPLE_RATE_HZ
    alpha = math.sin(w0) / (2.0 * 0.7071)
    cosw = math.cos(w0)
    a0 = 1.0 + alpha
    b0 = (1.0 + cosw) / 2.0 / a0
    b1 = -(1.0 + cosw) / a0
    b2 = b0
    a1 = -2.0 * cosw / a0
    a2 = (1.0 - alpha) / a0

    filtered = np.empty_like(mean_removed)
    x1 = x2 = y1 = y2 = 0.0
    for i, x0 in enumerate(mean_removed):
        y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        filtered[i] = y0
        x2, x1 = x1, x0
        y2, y1 = y1, y0

    cmnd = np.ones(MAX_LAG + 1, dtype=np.float64)
    running_sum = 0.0
    for lag in range(1, MAX_LAG + 1):
        delta = filtered[:-lag] - filtered[lag:]
        difference = float(np.dot(delta, delta))
        running_sum += difference
        if running_sum > 1e-12:
            cmnd[lag] = difference * lag / running_sum

    selected_lag = None
    for lag in range(MIN_LAG, MAX_LAG + 1):
        if cmnd[lag] < YIN_THRESHOLD:
            while lag < MAX_LAG and cmnd[lag + 1] < cmnd[lag]:
                lag += 1
            selected_lag = lag
            break

    if selected_lag is None:
        return 0.0

    lag = float(selected_lag)
    if 1 < selected_lag < MAX_LAG:
        left, center, right = cmnd[selected_lag - 1:selected_lag + 2]
        denominator = left - 2.0 * center + right
        if abs(denominator) > 1e-12:
            correction = 0.5 * (left - right) / denominator
            lag += max(-1.0, min(1.0, correction))

    if lag <= 0.0:
        return 0.0

    frequency = SAMPLE_RATE_HZ / lag
    if MIN_VOICE_FREQ_HZ <= frequency <= MAX_VOICE_FREQ_HZ:
        return frequency
    return 0.0


def measure_a_weighted_dbfs(samples):
    centered = samples.astype(np.float64) - float(np.mean(samples))
    window = np.hanning(len(centered))
    spectrum = np.fft.rfft(centered * window)
    frequencies = np.fft.rfftfreq(len(centered), d=1.0 / SAMPLE_RATE_HZ)

    f_squared = np.maximum(frequencies, 1e-12) ** 2
    ra = (
        (12194.0 ** 2 * f_squared ** 2)
        / (
            (f_squared + 20.6 ** 2)
            * np.sqrt((f_squared + 107.7 ** 2) * (f_squared + 737.9 ** 2))
            * (f_squared + 12194.0 ** 2)
        )
    )
    weighting = 10.0 ** ((20.0 * np.log10(ra) + 2.0) / 20.0)
    weighting[0] = 0.0

    weighted_power = np.abs(spectrum) ** 2 * weighting ** 2
    weighted_power[1:-1] *= 2.0
    mean_square = float(
        np.sum(weighted_power) / (len(centered) * np.sum(window ** 2))
    )
    rms = math.sqrt(mean_square)
    full_scale_sine_rms = 32768.0 / math.sqrt(2.0)
    return 20.0 * math.log10(max(rms, 1.0) / full_scale_sine_rms)


def process_audio():
    frequency_history = deque(maxlen=FREQUENCY_AVG_WINDOW)
    invalid_pitch_frames = 0

    while True:
        samples = audio_frames.get()
        dbfs = measure_a_weighted_dbfs(samples)
        frequency = estimate_frequency(samples)
        if frequency > 0.0:
            frequency_history.append(frequency)
            invalid_pitch_frames = 0
        else:
            invalid_pitch_frames += 1
            if invalid_pitch_frames >= 3:
                frequency_history.clear()

        smoothed_frequency = (
            float(np.mean(frequency_history)) if frequency_history else 0.0
        )
        db = dbfs
        if SPL_CALIBRATION_OFFSET_DB is not None:
            db += SPL_CALIBRATION_OFFSET_DB

        with readings_lock:
            readings.append((time.monotonic(), db, smoothed_frequency))


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
                mtu = client.mtu_size
                if mtu < 64:
                    status["text"] = f"Connected (BLE MTU {mtu}; audio may drop)"
                    print(status["text"])
                else:
                    status["text"] = "Connected"
                    print(f"Connected with BLE MTU {mtu}. "
                          "Close the graph window to quit.")
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
    with readings_lock:
        snapshot = list(readings)
    recent = [(t - now, db, f) for t, db, f in snapshot
              if now - t <= WINDOW_SECONDS]

    if not recent:
        ax_db.set_title(status["text"])
        return

    xs, dbs, freqs = zip(*recent)
    db_line.set_data(xs, dbs)
    freq_line.set_data(xs, freqs)
    ax_freq.relim()
    ax_freq.autoscale_view(scalex=False)

    _, db, frequency = snapshot[-1]
    level_unit = "dBA" if SPL_CALIBRATION_OFFSET_DB is not None else "dBFS(A)"
    ax_db.set_title(f"{db:.1f} {level_unit}")
    ax_freq.set_title(f"{frequency:.0f} Hz")


def main():
    global ax_db, ax_freq, db_line, freq_line

    threading.Thread(target=process_audio, daemon=True).start()
    threading.Thread(target=lambda: asyncio.run(ble_task()), daemon=True).start()

    fig, (ax_db, ax_freq) = plt.subplots(2, 1, sharex=True, figsize=(8, 6))
    (db_line,) = ax_db.plot([], [], linewidth=2)
    ax_db.set_xlim(-WINDOW_SECONDS, 0)
    if SPL_CALIBRATION_OFFSET_DB is not None:
        ax_db.set_ylim(-5, 120)
        ax_db.set_ylabel("Level (dBA, calibrated)")
    else:
        ax_db.set_ylim(Y_MIN, Y_MAX)
        ax_db.set_ylabel("Level (dBFS, A-weighted)")

    (freq_line,) = ax_freq.plot([], [], linewidth=2, color="tab:orange")
    ax_freq.set_xlabel("Seconds")
    ax_freq.set_ylabel("Frequency (Hz)")

    fig.tight_layout()
    animation = FuncAnimation(fig, update, interval=100, cache_frame_data=False)
    plt.show()


if __name__ == "__main__":
    main()
