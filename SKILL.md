---
name: sax1v1k-uboot-maintenance
description: OpenWrt Spectrum SAX1V1K / ASKEY RT5010W U-Boot 配置、雙區同步、記憶體位址排查、MAC 校正與還原恢復維護指南
---

# OpenWrt SAX1V1K / RT5010W U-Boot 維護與實戰經驗手冊

本手冊彙整將 Spectrum SAX1V1K (ASKEY RT5010W-D187) 設備配置動態 U-Boot 引導時的實戰經驗、故障排除與完整還原 SOP。

---

## 💡 核心經驗與注意事項 (Lessons Learned)

### 1. 磁碟標籤與分割區差異 (PARTLABEL Differences)
* **現象**：不同設備版本/電信商韌體的 GPT 標籤可能帶有 `0:` 前綴（例如 `0:HLOS` 對應 Slot 0，`0:HLOS_1` 對應 Slot 1）。
* **實踐**：指令與腳本應同時匹配 `HLOS` 與 `0:HLOS`。某些設備變體可能不包含 Recovery OS (`rsvd_5` / `mmcblk0p36`) 分割區，腳本需具備非致命性警告容錯。

### 2. Busybox `ash` POSIX 相容性限制 (Shell Compatibility)
* **現象**：OpenWrt 設備預設使用極簡的 `Busybox ash` (POSIX `sh`)，執行包含 `[[ ... ]]` 或 `=~` (正則表達式) 的指令時會爆出 `sh: =~: unknown operand` 錯誤。
* **實踐**：
  * 嚴禁使用 Bash 擴充語法（如 `[[ ... ]]`、`==`、`=~`）。
  * 數字驗證改用 POSIX `case "$var" in ''|*[!0-9]*) ;; *) ... ;; esac`。
  * 多字串匹配改用 POSIX `case "$var" in "A" | "0:A") ... ;; esac`。

### 3. U-Boot 雙 Slot 版本不一致與自動同步 (Dual-Slot Sync)
* **現象**：設備常出現 Slot 0 (`p15`) 與 Slot 1 (`p16`) U-Boot 版本/Hash 不一致的情況（例如實機實測 Slot 0 為未登錄 Hash `714b3fce...`，而 Slot 1 為已知 Hash `f3066582...`）。
* **實踐**：在寫入 Bootenv 前，腳本會比對 MD5。若 Slot 0 不存在資料庫中而 Slot 1 為已知版本，只需在 OpenWrt 終端機執行雙區同步即可：
  ```bash
  dd if=/dev/mmcblk0p16 of=/dev/mmcblk0p15 && sync
  ```

### 4. 記憶體開機位址防踩踏 (Memory Overwrite Prevention)
* **現象**：手動執行 `bootm 42000000` 時出現 `ERROR: new format image overwritten - must RESET the board to recover`。
* **原因**：Kernel 解壓縮目標位址為 `0x41000000`，若 FIT 載入位址設為 `0x42000000`，解壓過程會踩毀原映像檔。
* **實踐**：在 U-Boot 中必須統一使用 **`44000000` (`0x44000000`)** 作為 `loadaddr` / `tftpboot` 載入位址。

### 5. 高通 EDMA 網卡驅動 MAC 不一致警告 (MAC Mismatch)
* **現象**：在 U-Boot Shell 中啟動網路 (`run boot_tftp` / `go 4a96433c`) 時出現 `Warning: eth0 MAC addresses don't match: Address in SROM is ...63, Address in environment is ...64`。
* **原因**：高通網卡驅動會讀取 `eth1addr` 變數與 SROM 晶片 MAC 比對，若不一致會回傳非 0 狀態碼。
* **實踐**：在 U-Boot 中執行以下指令校正 MAC：
  ```bash
  setenv ethaddr a4:97:33:28:f1:63
  setenv eth1addr a4:97:33:28:f1:63
  saveenv
  ```

### 6. 雙系統 (Dual Slot) 與 Recovery OS (rsvd_5) 的備援機制區分
* **雙系統 (Slot 0 / Slot 1)**：位於 `0:HLOS` (`p18`) 與 `0:HLOS_1` (`p19`)，為主要 OpenWrt 系統 A/B 槽，用於日常使用、版號升級與長按 Reset 按鍵熱切換。
* **Recovery OS (`rsvd_5`)**：位於獨立的 `mmcblk0p36` (32MB Initramfs 記憶體救援系統)，當雙 Slot 主系統皆損毀時，提供應急救磚介面（按一下 Reset 切入）。
* **TFTP 網路救援**：若 Recovery OS 亦不可用，最後一道防線將發起向 1.2.3.4 請求 `recovery.img` 載入記憶體開機。

### 7. 設備 MTD / eMMC 分割區快速排查指令
```bash
# 查看雙槽 U-Boot (p15 / p16) 版本與 MD5 雜湊值
md5sum /dev/mmcblk0p15 /dev/mmcblk0p16
strings -n10 /dev/mmcblk0p15 | grep "U-Boot"
# 檢查 eMMC 區塊裝置
cat /proc/partitions
# 快速對照 GPT PARTNAME 標籤與裝置名 (如 mmcblk0p18 -> 0:HLOS)
for p in /sys/class/block/mmcblk0p*; do printf "%-12s " "${p##*/}"; grep PARTNAME "$p/uevent" 2>/dev/null; done
```

### 8. 實機動態解析適配驗證指標 (Validation Checklist)
在 Spectrum SAX1V1K 實測中，應確認以下適配條件皆滿足：
* ✅ `mmcblk0p14` (`0:APPSBLENV`) 空間大小精確為 `256 KB` (`0x40000` bytes)。
* ✅ `mmcblk0p18` / `mmcblk0p19` 標籤帶有 `0:` 前綴 (`0:HLOS` / `0:HLOS_1`)，動態腳本能自動辨識去前綴匹配。
* ✅ `mmcblk0p36` (`rsvd_5`) 空間為 `32 MB`，動態腳本能成功綁定作為 Recovery OS 載入目標。
* ✅ `fw_printenv` 初始 `bootcmd=bootipq` 在套用腳本後順利轉移為 `run boot_stage1`。

### 9. Recovery OS (`rsvd_5` / `mmcblk0p36`) 燒錄 SOP
* **OpenWrt 環境**：`dd if=/tmp/recovery.img of=/dev/mmcblk0p36 && sync`
* **U-Boot 控制台**：設定 TFTP Server `1.2.3.4` 放 `recovery.img` 後執行 `run boot_write_recovery_from_tftp`

### 10. 雙槽 A/B 自動判斷安全備份 SOP
```bash
# PARTUUID 反查實體槽位: grep -H "$(cat /proc/cmdline | grep -o 'PARTUUID=[^ ]*' | cut -d= -f2)" /sys/class/block/mmcblk0p*/uevent
# 自動判定當前槽位並將 Active Slot 備份至 Inactive Slot
ACTIVE="$( fw_printenv boot_active_slot 2>/dev/null | cut -d= -f2 )"
if [ "$ACTIVE" = "1" ]; then
  dd if=/dev/mmcblk0p19 of=/dev/mmcblk0p18 && dd if=/dev/mmcblk0p22 of=/dev/mmcblk0p20 && sync
else
  dd if=/dev/mmcblk0p18 of=/dev/mmcblk0p19 && dd if=/dev/mmcblk0p20 of=/dev/mmcblk0p22 && sync
fi
```

### 11. 腳本套用完成後驗證 SOP
* **環境變數檢驗**：`fw_printenv bootcmd boot_stage1 boot_set_slot_0 boot_hack` (檢查 `bootcmd=run boot_stage1`)
* ** Bootloader 雙槽對比**：`md5sum /dev/mmcblk0p15 /dev/mmcblk0p16` (兩者一致)
* **硬體 Reset 測試**：斷電按住 Reset 插電 2-3 秒至藍燈恆亮放開，短按一下切進入 Recovery OS

### 12. 專案最新完工現況紀錄 (2026-08-11)
* ✅ **自動動態解析**：`configure-uboot-dynamic.sh` 已登錄 `714b3fce...` Variant，動態鎖定 `HLOS (0x8A22)`、`HLOS_1 (0xCA22)` 與 `rsvd_5 (0x4F9E22)`。
* ✅ **Recovery 系統燒錄**：已將 `openwrt-25.12.5-qualcommax-ipq807x-spectrum_sax1v1k-initramfs-uImage.itb` (13.35MB) 完整寫入 `rsvd_5` (`mmcblk0p36`)。
* ✅ **自動化逆向工具**：專案庫內備有 `scan-uboot-hack.py` 供快速分析任何新 U-Boot 記憶體位址。

### 13. 雙槽切換 `could not switch active boot slot` 故障排除
* **根因**：`boot_active_slot` 在環境變數中未初始化（為空），舊邏輯 `test "$boot_active_slot" = 1 ... elif test "$boot_active_slot" = 0` 不符落入 `false` 失敗。
* **修復**：`fw_setenv boot_active_slot '0'` 並且將切換邏輯強化為 `if test "$boot_active_slot" = "1"; then setenv boot_active_slot 0; else setenv boot_active_slot 1; fi`。

### 14. 實機自動降級與 Recovery 引導合格 Log 驗證指標
* **槽位切換合格**：出現 `Saving Environment to MMC... Writing to MMC(0)... done` 與 `## Info: switched active boot slot to: 1`
* **自動降級合格**：若當前 Slot 無有效 Kernel，印出 `## Error: main OS boot failed` 後自動跳轉 `## Info: booting recovery OS...`
* **Recovery 引導合格**：自 `rsvd_5` (`block # 5217826`) 讀取映像檔至 `0x44000000` 成功載入 FIT Kernel

### 15. 原廠環境下從 U-Boot 極簡引導 Initramfs (.itb) 開機 SOP
在原廠 U-Boot Shell (`IPQ807x#`) 中無須改檔名或輸入複雜位址，僅需 3 步：
1. PC (IP `1.2.3.4`) 開啟 TFTP Server 直接放置官方下載的 `.itb` 檔案（無須改名）
2. 在 `IPQ807x#` 貼上：`setenv ipaddr 1.2.3.1; setenv serverip 1.2.3.4; tftpboot 44000000 <檔案名稱.itb> && bootm 44000000`
3. 開入 OpenWrt 臨時系統後，電腦上傳腳本 `scp configure-uboot-dynamic.sh root@<ROUTER_IP>:/tmp/` (官方 Initramfs 預設 IP 為 `192.168.1.1`)，進入 SSH 執行 `chmod +x /tmp/configure-uboot-dynamic.sh && /tmp/configure-uboot-dynamic.sh`

### 16. Recovery OS 下 Web Upgrade 的升級機制與切槽對策
* **機制原理解析**：OpenWrt 原生 `sysupgrade` 預設只會升級寫入 **Slot 0 (`p18` / `p20`)**。若當前 U-Boot 活躍槽位為 **Slot 1 (`boot_active_slot=1`)**，Web 升級成功後重啟，U-Boot 仍會嘗試去讀取未寫入的 Slot 1 導致開機失敗，並再度降級進入 Recovery。
* **對策 A**：長按 Reset 3 秒切回 Slot 0，即可直接開入剛 Web 升級好的全新正式系統。
* **對策 B**：開入 Slot 0 系統後，執行 `dd if=/dev/mmcblk0p18 of=/dev/mmcblk0p19 && dd if=/dev/mmcblk0p20 of=/dev/mmcblk0p22 && sync` 進行雙槽同步。

### 17. A/B 雙槽安全營運哲學 (先驗證，再 dd 同步)
* **單槽升級防保護**：Web Upgrade 不自動同時刷寫兩槽，避免新韌體 Bug 造成雙槽死磚。
* **標準營運 SOP**：Web 升級 ──> 開入 Slot 0 驗證系統/網路 100% 正常 ──> 執行 `dd` 一鍵指令備份至 Slot 1。確保 Slot 1 永遠留存經驗證合格的備用系統。

### 18. 透過 SSH CLI 指令手動切換開機 Slot 並重啟 SOP
在 OpenWrt SSH 終端機內：
* 查看當前槽位：`fw_printenv boot_active_slot`
* 切換 Slot 1 並重啟：`fw_setenv boot_active_slot 1 && reboot`
* 切換 Slot 0 並重啟：`fw_setenv boot_active_slot 0 && reboot`
* 一鍵自動跳轉另一個 Slot 重啟：
  `ACTIVE="$( fw_printenv boot_active_slot 2>/dev/null | cut -d= -f2 )"; if [ "$ACTIVE" = "1" ]; then fw_setenv boot_active_slot 0 && reboot; else fw_setenv boot_active_slot 1 && reboot; fi`

### 19. OpenWrt 無 sftp-server 時之 SCP 上傳傳輸 SOP (`scp -O`)
* **問題**：提示 `ash: /usr/libexec/sftp-server: not found` 傳輸失敗。
* **原因**：OpenWrt 精簡韌體無 SFTP 服務，新版 SSH client 預設走 SFTP。
* **對策**：加上 `-O` 參數強制切換回傳統 SCP 傳輸協定：`scp -O file.sh root@<ROUTER_IP>:/tmp/`。

### 20. U-Boot Jul 02 2021 (variant f032) 實戰逆向成功經驗
* **MD5 雜湊**：`f0320e776cfb0b5509ca9722eda42213`
* **掃描位址**：`mw 4a612880 0a000007 1; mw 4a614034 0a000006 1; go 4a9647cc` (實測與 `scan-uboot-hack.py` 100% 驗證相符)。

### 21. 動態 GPT 容錯：無 rsvd_5 設備之自動降級機制
* **實測現象**：在部分無 `rsvd_5` GPT 標籤之設備上，提示 `rsvd_5 (recovery) partition NOT found`。
* **腳本自動保護**：腳本自動將 `boot_recovery` 與 `boot_stage4` 設為 `#nop`（空指令），確保開機鏈流程不會因缺失 Recovery 分割區而異常卡死。

---

## 🛠️ 完全還原 U-Boot 至原廠狀態 SOP (Factory Restoration)

本專案腳本**完全沒有修改硬體 Bootloader 韌體本身**，所有配置僅寫入 `/dev/mmcblk0p14` 環境變數區。若需要完全還原為原廠出廠狀態，請在 U-Boot Shell (`IPQ807x#`) 執行：

```bash
env default -a
saveenv
reset
```

---

## 📄 專案文件索引
* `configure-uboot-dynamic.sh` - 動態解析與 POSIX 相容之 U-Boot 配置主腳本
* `DYNAMIC_UBOOT_GUIDE.md` - 詳細功能、BOOT Stages 機制與硬體按鈕操作說明
* `UBOOT_REVERSE_ENGINEERING_GUIDE.md` - 高通 U-Boot 逆向工程與 Memory Hack 位址提取指南
