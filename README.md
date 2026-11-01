# Infrared Gas Detection System based on Efinix Ti60F225

Camera capture + adaptive brightness enhancement + Sobel edge detection + thermal-style
image display, all on an **Efinix Titanium Ti60F225** FPGA, output over **HDMI 1080p60**.

Video input is a **SC431HAI** CMOS sensor over MIPI CSI-2; frames are buffered in DDR3 and
displayed on HDMI. A single key cycles the display through three modes.

> Target board: Efinix Ti60F225 DemoBoard v4 · Toolchain: Efinity 2026.1 · Top module: `final_top`

---

## 1. Features

| # | Feature | Implementation |
|---|---|---|
| 1 | **Adaptive brightness (AGC)** — fixes the "picture too dark" problem of the stock demo | `rtl/video/auto_enhance.v`: per-frame mean luminance → closed-loop digital gain (converges in ~0.3 s) → gamma 1/1.8 lift LUT (`gamma_brt.hex`) |
| 2 | **Noise reduction** | `rtl/video/hblur3.v`: 3-tap `[1 2 1]/4` per-channel smoothing placed *before* the AGC, so noise is not amplified with the signal |
| 3 | **White balance** | `r_gain / g_gain / b_gain` (Q8.8) applied to raw Bayer data before debayer; default R=1.33x, G=1.00x, B=1.53x to cancel the green cast of the raw sensor |
| 4 | **Sobel edge detection** | `sobel_3x3` in `rtl/video/key_mode.v`: two line buffers + 3x3 window, `max(|Gx|,|Gy|)` magnitude, dead zone + gain |
| 5 | **Thermal-style still image** | `rtl/video/ir_display.v` + `img_rom.v`: 256x200 grayscale stored in BRAM, nearest-neighbour upscale to **full 1920x1080**, same 1080p60 timing as the camera path |
| 6 | **One-key mode switch** | `rtl/video/key_mode.v`: KEY3 or KEY0 cycles the three modes, `led[2]` / `led[3]` indicate the mode |

### Display modes (press KEY3 or KEY0 to cycle)

| Mode | Picture | LED |
|---|---|---|
| 0 (default at power-up) | Camera + adaptive enhancement | `led[2]` on |
| 1 | Sobel edges (white edge on black) | both off |
| 2 | Thermal-style still image (full screen) | `led[3]` on |

---

## 2. Repository layout

```
final_cam_ir/
├─ final_cam_ir.xml          Efinity project (top = final_top)
├─ final_cam_ir.peri.xml     pins / PLL / LVDS / MIPI constraints
├─ final_cam_ir.sdc          Interface-Designer generated timing constraints
├─ final_cam_ir_io.sdc       hand-written constraints (async clock groups)
├─ final_profile.wizard.json debugger (LA/VIO) profile
├─ rtl/
│   ├─ final_top.v           top level (camera path, DDR3, HDMI out, mode mux)
│   ├─ video/                auto_enhance.v · gamma_rom.v · hblur3.v
│   │                        ir_display.v · img_rom.v · palette_rom.v · key_mode.v
│   ├─ cam/  cam_i2c_ctrl/   sensor I2C configuration
│   ├─ csi_rx_controller.sv  MIPI CSI-2 receiver
│   ├─ debayer/              RAW → RGB (raw_to_rgb, line_buffer, rgb_gain...)
│   ├─ ddr3_controller/      DDR3 controller
│   ├─ frame_buffer_V3/      three-frame DDR3 buffering
│   ├─ dvi_tx/               TMDS encoder
│   └─ dsi_tx/ mipi_config/  DSI display path (unused here, kept as-is)
├─ img.hex                   256x200 thermal-style image (51200 bytes)
├─ gamma_brt.hex             256-entry gamma 1/1.8 lift table
├─ build.ps1                 map → interface → pnr → pgm (one command)
├─ efinity_env.ps1           Efinity discovery / wrapper helpers
├─ 0-编译并烧录.bat           build + program
├─ 1-一键编译.bat             build only
├─ 2-打开工程.bat             open project in Efinity GUI
└─ 3-烧录器.bat               open Efinity Programmer
```

Build outputs (`outflow/`, `work_syn/`, `work_pnr/`) are **not** committed — regenerate them
with `build.ps1`.

---

## 3. Building

**Requirements**: Efinix Efinity 2026.1 (default `C:\Efinity\2026.1`, or set `EFINITY_HOME`).

```powershell
# full flow: synthesis → interface → place & route → bitstream
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
```

or double-click `1-一键编译.bat`. Result: `outflow/final_cam_ir.bit`.

Programming: double-click `3-烧录器.bat` (or `0-编译并烧录.bat` to build and program in one go).

Timing / utilisation of the committed configuration (Ti60F225, C4):

| Item | Value |
|---|---|
| Pixel clock | 148.5 MHz (1080p60) |
| Setup slack (worst) | +0.40 ns |
| Hold slack (worst) | +0.09 ns |
| LUT4 | ~6.1 k / 60.8 k |
| Memory Blocks | ~145 / 256 |

---

## 4. Tuning knobs

| What | Where |
|---|---|
| White balance | `final_top.v`: `r_gain / g_gain / b_gain` (Q8.8, 256 = 1.0x) |
| AGC target window / max gain | `auto_enhance.v`: `TGT_LO / TGT_HI / G_MIN / G_MAX` |
| Denoise strength | `hblur3.v` (3-tap); replace with a median filter for stronger noise removal |
| Sobel sensitivity | `final_top.v`: `.THRESH(...)` dead zone, `.GAIN(...)` = 2^GAIN magnitude boost |
| Thermal image content / size | `img.hex` (256x200, 8-bit) and `ir_display.v` (window + scaling) |

---

## 5. Known limitations

- The TN256 thermal **module** on the same board does not deliver a valid video stream
  (HS/VS/data timing unstable); this project therefore displays a **stored** thermal-style
  image for the "thermal" mode. The camera path (SC431HAI) runs live.
- `led[0]` / `led[1]` are wired to KEY2 / KEY1 on this board and are therefore tied to 0.
- Mode switching may cause the monitor to re-sync for a fraction of a second (both paths are
  1080p60 but with different phase) — this is expected.

---

## 6. 中文说明

**这是个什么项目**：在 Efinix Titanium **Ti60F225** 开发板上，把 **SC431HAI** 摄像头
（MIPI CSI-2）的画面经 DDR3 三帧缓存后，以 **HDMI 1080p60** 输出；同时做了自适应亮度增强、
降噪、白平衡和 Sobel 边缘检测；按一个键可以在「增强画面 / Sobel 边缘 / 红外风格图」三种显示之间切换。

**为什么要做这些**：原厂 demo 挂了一条 gamma=2.2 的“校正”表，实际是把中间调往下压
（输入 128 只出到 55），画面很暗；本工程整条通路换成了 **AGC 测光闭环 + gamma 1/1.8 提亮**，
室内和傍晚都能自动拉到合适亮度。

**怎么编译**：装好 Efinity 2026.1，双击 `1-一键编译.bat`（或跑 `build.ps1`），
产物在 `outflow/final_cam_ir.bit`；双击 `3-烧录器.bat` 下载。

**三种模式**：KEY3 或 KEY0 循环切换，`led[2]` 亮 = 摄像头增强，全灭 = Sobel 边缘，
`led[3]` 亮 = 红外风格图。

**说明**：红外图那一路上游是 TN256 热成像模组，目前模组侧的 HS/VS/数据时序还不稳定，
所以这里显示的是存在 BRAM 里的一张 256×200 静态热像图（全屏放大），不是实时热成像。

---

*Based on the Efinix Ti60F225 out-of-box demo. Use at your own risk.*
