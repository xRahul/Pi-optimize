# Raspberry Pi 5: NVMe SSD Boot, PCIe Gen 3, Overclocking & Performance Tuning Guide

This comprehensive reference document summarizes technical learnings, configurations, and best practices compiled from major community resources, benchmark reports, and official documentation regarding the Raspberry Pi 5 platform.

---

## 1. PCIe Gen 3 Enablement & Configuration

The Raspberry Pi 5 is officially rated and certified for **PCIe Gen 2.0** speeds (5 GT/s, yielding up to ~450 MB/s). However, the hardware supports **PCIe Gen 3.0** (8 GT/s, yielding up to ~900 MB/s), which can be forced via configuration.

### Configuration (`/boot/firmware/config.txt`)
To enable the PCIe interface and force Gen 3.0 speeds, append the following to `/boot/firmware/config.txt` under the `[pi5]` filter section:

```ini
[pi5]
# Enable the external PCIe port
dtparam=pciex1

# Note: 'dtparam=nvme' is an alias for 'dtparam=pciex1'. Either works.
# dtparam=nvme

# Force PCIe Gen 3.0 speeds (Default is Gen 2.0)
dtparam=pciex1_gen=3
```

### Power Saving vs. Speed
* **Gen 2.0 Power Savings:** If peak speed is not required (e.g., media server, home automation, background torrents), dropping the PCIe bus to Gen 2.0 (`dtparam=pciex1_gen=2`) reduces load power consumption and operational heat.
* **Signal Integrity Fallbacks:** High speeds are highly sensitive to the Flexible Flat Cable (FFC) length, shielding, and connection quality. A standard, unshielded or poorly seated cable will cause PCIe link failures, data corruption, or drive dropouts. Revert to Gen 2.0 if issues arise.

---

## 2. Booting from NVMe SSD (M.2 HAT / Base)

Booting directly from an NVMe SSD removes the SD card bottleneck entirely, boosting boot speed and application responsiveness.

### Prerequisites
* **Hardware:** Raspberry Pi 5, an M.2 NVMe HAT (e.g., official Raspberry Pi M.2 HAT+, Pimoroni NVMe Base, Pineberry HatDrive, or Geekworm X1001), a compatible M.2 NVMe SSD, and a stable 27W (5V/5A) Power Supply.
* **Active Cooling:** Highly recommended, as NVMe SSDs and the Pi 5's BCM2712 SoC generate significant heat under I/O-heavy workloads.

### Hardware Assembly Best Practices (Pimoroni NVMe Base)
* **FFC Cable Orientation:** Ensure the ribbon cable is oriented correctly. The wider end labeled **"ADDON"** connects to the NVMe Base. The narrower end labeled **"RPI 5"** connects to the Pi 5's PCIe connector. When correctly installed, the pirate logo and text face outward.
* **Socket Seating:** Use tweezers. Carefully lift the grey clip on the NVMe Base socket to fold it up. Slide the ribbon cable in and fold the clip flat. On the Pi 5, lift the brown clip vertically by 1mm, insert the cable, and press the clip down firmly to latch.

### Bootloader Update & Configuration
To update the system firmware and prioritize the NVMe drive in the boot sequence:

1. **Update Firmware:**
   ```bash
   sudo apt update && sudo apt full-upgrade -y
   sudo rpi-eeprom-update -a
   ```
2. **Configure Boot Order:**
   Execute the interactive configuration tool:
   ```bash
   sudo raspi-config
   ```
   Navigate to **Advanced Options > Boot Order** and select **NVMe/USB Boot** (or NVMe as the primary device).
   
   *Alternatively*, edit the EEPROM configuration manually:
   ```bash
   sudo rpi-eeprom-config --edit
   ```
   Locate or add the `BOOT_ORDER` variable and change it to:
   ```ini
   BOOT_ORDER=0xf416
   ```
   * **`6`** = NVMe boot
   * **`4`** = USB mass storage boot
   * **`1`** = MicroSD boot
   * **`2`** = Network boot
   * **`f`** = Loop/Restart bootloader sequence
   
   To prioritize NVMe first, and fall back to MicroSD if no NVMe is present, use `BOOT_ORDER=0xf461`.

3. **HAT+ Automatic Probing:**
   If using an official HAT+-compliant board, the Pi probes the PCIe port automatically. If using older or third-party boards that do not autodetect, you may need to force probing in the EEPROM config:
   ```ini
   PCIE_PROBE=1
   ```

### OS Migration & Card Cloning
* **Fresh Install:** Recommended to use the Raspberry Pi Imager to write the OS directly to the NVMe SSD.
* **Lite Edition / Headless Cloning:** If you are migrating a headless/Lite server configuration directly from a MicroSD card to the NVMe SSD, run the disk duplicator command from SSH:
  ```bash
  sudo dd if=/dev/mmcblk0 of=/dev/nvme0n1 status=progress
  ```

---

## 3. NVMe SSD Compatibility & Hardware Quirks

Choosing the right SSD is critical. The Pi 5's PCIe bus has strict power limits and controller compatibilities.

### SSD Selection Best Practices
* **DRAM-less SSDs Preferred:** Drives with large DRAM caches draw high peak power during heavy writes, which can exceed the GPIO power limit of the M.2 HAT. DRAM-less SSDs (e.g., WD Blue SN570/SN580, Kingston NV2) are highly recommended due to lower power consumption.
* **Avoid High-End Gen4/Gen5 Desktop Drives:** Drives like the Samsung 990 Pro or WD Black SN850X can draw up to 8–10W, causing brownouts or PCIe resets on the Pi 5 unless an external power supply is used.

### Incompatibility & Problematic Controller List
Many compatibility issues trace back to specific flash controllers, particularly certain **Phison** and **Maxio** designs:

| SSD Model | Controller | Status / Workaround |
| :--- | :--- | :--- |
| **WD Blue SN550** | SanDisk/WD custom | Resolved with 2024-01-24 and newer EEPROM updates |
| **WD Green SN350** | SanDisk/WD custom | Resolved with newer firmware updates |
| **WD Blue SN580 / SN5000** | Proprietary | Hit-or-miss detection; PCIe Gen 2 fallback recommended |
| **WD Black SN770 / SN850** | Proprietary | High power draw; potential handshake failure |
| **Kingston NV3** | Silicon Motion / Phison | Potential handshake failures |
| **fanxiang S500 Pro** | Maxio MAP1202 | MAP1202 has issues with PCIe Gen 2 backward compatibility |
| **Micron 2450 / 2200** | Silicon Motion | Detected by OS, but unable to boot (EEPROM loader failure) |
| **Corsair MP600** | Phison | Handshake/power negotiation issues |

### APST Sleep State / System Freeze Workaround
A major issue with Lexar, Kingston, and some WD drives is their aggressive **Autonomous Power State Transition (APST)**. The drive enters a deep sleep state (`ps3` or `ps4`), and the Pi 5 fails to wake it, causing the filesystem to freeze.

**Fix:** Disable deep sleep states by passing a kernel parameter. Edit `/boot/firmware/cmdline.txt` and append the following to the single line of boot arguments:
```text
nvme_core.default_ps_max_latency_us=0
```
This forces the NVMe controller to stay in active mode (`ps0`), preventing lockups.

---

## 4. Overclocking Settings & Stability

The Pi 5's Broadcom BCM2712 SoC runs at 2.4 GHz stock but can be safely overclocked with adequate cooling.

### Overclock Configuration (`/boot/firmware/config.txt`)
Add the following parameters under the `[pi5]` section. Start conservatively and increment.

```ini
[pi5]
# Overclock the CPU (Stock: 2400)
arm_freq=2800

# Overclock the GPU (Stock: 910)
gpu_freq=1000

# Add voltage offset in microvolts (recommended for arm_freq >= 2800)
over_voltage_delta=50000
```

### Extreme Overclocking (3.0 GHz+ )
For extreme speeds (up to 3.2 GHz), you must supply a larger voltage offset and enforce aggressive cooling:
```ini
arm_freq=3000
gpu_freq=1000
over_voltage_delta=72000
```
*Note: Overclocking to 3.2 GHz may require custom kernel overvolting tools (like `pi-overvolt` by Jeff Geerling).*

### Overclocking Rules & Guardrails
* **Cooling is Non-Negotiable:** At 2.8+ GHz, active cooling (Active Cooler or custom fan/heatsink setup) is mandatory. Without it, the Pi will hit the 80°C thermal throttle threshold within seconds of load, rendering the overclock useless.
* **"Throttling = Failed Overclock":** If you see thermal or low-voltage throttling (`vcgencmd get_throttled`), your system is unstable. Reduce `arm_freq` or increase `over_voltage_delta`.
* **Dynamic Scaling:** Avoid `force_turbo=1` for general use. Let the CPU scale down during idle to save power and lifespan.

---

## 5. Memory & SDRAM Tuning (Jeff Geerling Insights)

Memory throughput is a common bottleneck for multi-threaded workloads on the Pi 5. Recent firmware updates and manual kernel tweaks unlock substantial performance gains.

### SDRAM Timing Tweaks
* Raspberry Pi engineers optimized SDRAM refresh rates and latency timings for Micron and LPDDR4X/LPDDR5 chips on the Pi 5.
* These memory tweaks provide a **10–20% speedup** at default clock speeds, and up to **32% speedup** when combined with CPU/GPU overclocking.

### NUMA Emulation for Multi-Core Workloads
Since the Pi 5's RAM is unified, setting up **Non-Uniform Memory Access (NUMA) emulation** optimizes cache locality and memory scheduling in multi-threaded applications (e.g., databases, compilation).

To enable NUMA emulation:
1. Append the following to `/boot/firmware/cmdline.txt`:
   ```text
   numa=fake=4
   ```
   *(or `numa=fake=8` depending on workload complexity)*
2. Verify after rebooting:
   ```bash
   dmesg | grep NUMA
   ```
   You should see: `mempolicy: NUMA default policy overridden to 'interleave:0-3'` (or `0-7`).

---

## 6. General Performance Optimization (EDATEC "11 Ways")

To build a high-performance home server, the system should be optimized holistically:

1. **Safely Overclock:** Elevate CPU (2.8 GHz), GPU (1000 MHz), and adjust RAM latency.
2. **Fast Storage:** Use M.2 NVMe SSD (Gen 3) for primary OS partition.
3. **Adequate Power Supply:** Use the official 27W 5V/5A power supply. Standard 15W supplies limit USB power output to 600mA and may throttle PCIe.
4. **Active Thermal Management:** Use the official Active Cooler or heavy-duty heatsink to keep temps below 60°C.
5. **Powered USB Hub:** Unload the Pi's internal power delivery by running external high-power USB drives via a powered hub.
6. **Wired Gigabit Ethernet:** Replace Wi-Fi with wired connections for server workloads to guarantee lowest latency and maximum throughput.
7. **Headless / Lightweight OS:** Run Raspberry Pi OS Lite (64-bit) without any desktop environment (X11/Wayland) to reclaim RAM and CPU cycles.
8. **Optimize Boot Settings:** Fast boot settings, disabling plymouth boot screens, and managing services.
9. **Disable Unused Hardware Services:** Disable onboard Wi-Fi, Bluetooth, and audio if not used. Add these to `/boot/firmware/config.txt`:
   ```ini
   dtoverlay=disable-wifi
   dtoverlay=disable-bt
   dtparam=audio=off
   ```
10. **Keep System Current:** Run regular package upgrades and update the bootloader/EEPROM firmware.
11. **Clustering:** Scale performance vertically using container systems (Docker Swarm / Kubernetes).

---

## 7. Storage Benchmarks & Performance Verification

Use these commands to benchmark your NVMe drive and ensure your PCIe configurations are functioning at peak speeds:

### Simple Sequential Read Test (hdparm)
```bash
sudo apt install hdparm -y
sudo hdparm -t --direct /dev/nvme0n1
```
* **MicroSD target:** ~80-90 MB/s
* **PCIe Gen 2.0 target:** ~420-450 MB/s
* **PCIe Gen 3.0 target:** ~800-900 MB/s

### Complete System Boot Time (systemd-analyze)
```bash
systemd-analyze
```
* Shows kernel, initrd, and userspace startup times. NVMe drives typically reduce overall boot time from ~35-40 seconds down to **10-14 seconds**.

### Detailed I/O Performance Profiling (fio)
Install `fio`:
```bash
sudo apt install fio -y
```

1. **Sequential Read Benchmark:**
   ```bash
   fio --name=seqread --rw=read --bs=1M --size=1G --numjobs=1 --runtime=30 --time_based --filename=/tmp/test.fio
   ```
2. **Random 4K Read/Write (IOPS) Benchmark:**
   ```bash
   fio --name=randrw --rw=randrw --bs=4k --size=256M --numjobs=4 --runtime=30 --time_based --filename=/tmp/test.fio
   ```
   *High-quality NVMe SSDs easily achieve 50,000+ Read IOPS and 35,000+ Write IOPS on the Pi 5, compared to only 1,500 - 3,000 IOPS on high-end MicroSD cards.*

---

## 8. Headless Server & Docker Specific Tweaks (from raspberry.tips)

When running the Pi 5 as a headless home server running Docker Compose stacks (e.g., Caddy, Tailscale, Immich, n8n), these additional optimizations maximize resource availability and protect storage media:

### GPU Memory Split Allocation
Since a headless server does not drive a monitor or graphical interface, you can minimize the RAM allocated to the GPU, freeing up system memory for containers:
1. Edit `/boot/firmware/config.txt`.
2. Add or modify:
   ```ini
   gpu_mem=16
   ```
*(Note: On 4GB/8GB Pi 5 models, this frees up minor memory but is a solid best-practice for maximum RAM availability).*

### Cap Journald Log Growth
To prevent system logs from growing unbounded and wearing down flash storage or taking up valuable NVMe SSD space:
1. Edit `/etc/systemd/journald.conf`.
2. Uncomment/configure:
   ```ini
   SystemMaxUse=100M
   ```
3. Restart the service:
   ```bash
   sudo systemctl restart systemd-journald
   ```

### RAM Disk Offloading for `/tmp` and `/var/tmp`
Move frequently written temporary files out of persistent storage and into volatile memory (`tmpfs`). This speeds up I/O and reduces wear on flash devices:
1. Edit `/etc/fstab`.
2. Append:
   ```text
   tmpfs   /tmp            tmpfs   defaults,noatime,nosuid,size=50m    0 0
   tmpfs   /var/tmp        tmpfs   defaults,noatime,nosuid,size=30m    0 0
   ```
*(Warning: Any files placed in /tmp or /var/tmp will be deleted on reboot. This is correct behavior for temp files).*

### Power Reduction & Device Isolation
If the home lab server runs over hardwired Gigabit Ethernet, disable onboard wireless components to drop peak/idle power draw and prevent device wake interrupts:
1. Append the overlays to `/boot/firmware/config.txt`:
   ```ini
   dtoverlay=disable-wifi
   dtoverlay=disable-bt
   ```
2. Verify that they are completely shut down (both signals should read `lo` and value `0`):
   ```bash
   pinctrl WL_ON,BT_ON
   ```

