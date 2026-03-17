# segwaycontrol

A Flutter-based remote control app for an ESP32 Segway-style robot using classic Bluetooth SPP.

## Features

- Connect to a paired ESP32 via Bluetooth
- Control forward/backward movement via on-screen "Gas" / "Bremse" buttons
- Steering via:
  - **Gyroscope mode** (turn your phone left/right)
  - **On-screen steering wheel** (tap-and-drag)

## Usage

1. Pair your phone with the ESP32 device via Android Bluetooth settings.
2. Start the app and select the paired ESP32 device from the dropdown.
3. Press **Verbinden** to connect.
4. Use the buttons or steering controls to drive the Segway.

> **Note:** This app sends simple single-character commands over Bluetooth serial to match the ESP32 firmware:
>
> - `w` = drive forward
> - `s` = reverse/brake
> - `x` = stop (stand upright)
> - `a` = turn left
> - `d` = turn right
> - `q` = stop turning
# RemoteControlledSegway
