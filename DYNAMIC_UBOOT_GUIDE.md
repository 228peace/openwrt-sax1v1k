# Dynamic U-Boot 配置腳本說明文件

本文件說明專案中針對 ASKEY RT5010W / Spectrum SAX1V1K 設備所客製化改寫的動態 U-Boot 配置腳本 [`configure-uboot-dynamic.sh`](configure-uboot-dynamic.sh)。

---

## 📌 腳本簡介與設計動機

原始的 [`configure-uboot.sh`](configure-uboot.sh) 採用了**靜態 GPT Hash 鎖定**與**硬編碼磁碟扇區號**（例如 Sector `0x8A22`）。
在**無 Qualcomm Secure Boot 變磚風險**的前提下，為了提供更高的分割區彈性（允許重新劃分分割區 / Repartition）並適應不同設備變體的 GPT 標籤格式（如 `0:HLOS` 與 `HLOS`），因而開發了 [`configure-uboot-dynamic.sh`](configure-uboot-dynamic.sh)。

---

## 🔄 與原版腳本之差異對比

| 功能項目 | 原版 `configure-uboot.sh` | 動態版 `configure-uboot-dynamic.sh` |
| :--- | :--- | :--- |
| **GPT 驗證機制** | 比對靜態 MD5 雜湊值（若分割表變動則拒絕執行） | 移除靜態 Hash 鎖，允許彈性調整分割區大小 |
| **扇區位址取得** | 硬編碼扇區位址（如 `0x8A22`） | 透過 `/sys/class/block/mmcblk0p*/` **動態解析**實體起始扇區 |
| **PARTLABEL 相容性** | 僅相容預設標準標籤 | **完全相容原廠帶有 `0:` 前綴的標籤**（如 `0:HLOS`, `0:HLOS_1`） |
| **U-Boot 雙槽救援** | 若現有 Slot 為未知 Hash 則中斷退出 | **智慧救援機制**：若備用 Slot 為已知 Hash，自動提示複製同步 |
| **Shell 相容性** | 部分 Bash 擴充語法 | **100% 相容 OpenWrt Busybox ash / POSIX sh** |
| **唯讀系統容錯** | 依賴 `/etc/fw_env.config` 寫入 | **自動降級至 `/tmp/fw_env.config`**，支援 Initramfs / 唯讀 SquashFS |
| **U-Boot Hack 校驗** | 依據 U-Boot MD5 Hash 匹配記憶體 Patch 位址 | **完整保留並持續擴充**（收錄 `63fc`、`f032`、`714b` 等 9 種版本） |

---

## 🚀 腳本套用後的 5 大功能與效果

當在設備上執行 [`configure-uboot-dynamic.sh`](configure-uboot-dynamic.sh) 並成功寫入 `fw_setenv` 後，設備將獲得以下能力：

### 1. RESET 按鈕硬體控制選單 (雙系統一鍵切換)
開機時觸發硬體選單之兩階段操作 SOP：

```text
[ 插上電源上電 ] ──(按住 Reset 不放 2~3 秒)──> [ LED 變為藍燈恆亮 (Pause) ]
                                                            │
                                                     (放開 Reset 鈕, LED 燈滅)
                                                            │
                                ┌───────────────────────────┴───────────────────────────┐
                                │                                                       │
                     【想要進入 Recovery OS】                                【想要切換雙系統 Slot 0 ↔ 1】
                                │                                                       │
                     👉 按一下 Reset 鈕 (短按 < 3秒)                          👉 長按 Reset 鈕超過 3 秒不放
                                │                                                       │
                                ▼                                                       ▼
                      [ 開入 Recovery OS ]                                  [ 切換槽位並開入 Main OS ]
```

* **第一階段 (上電觸發暫停)**：
  1. 路由器斷電狀態下，**按住 RESET 按鈕不放**，隨即**插上電源線上電**。
  2. 保持按住約 **2 ~ 3 秒**，直到前方 **LED 變為藍燈恆亮 (Solid Blue)** 時，代表 U-Boot 已成功暫停開機流程。
  3. **鬆開 (Release) RESET 按鈕**，LED 燈熄滅，設備進入選單等待狀態。

* **第二階段 (功能選擇)**：
  * **按一下 (Click, 短按 < 3秒)**：直接開入 Recovery OS 復原系統 (`rsvd_5`)。
  * **長按 3 秒 (Hold, 長按 > 3秒)**：**自動切換雙 Slot 系統**！在 Slot 0 (`0:HLOS`) 與 Slot 1 (`0:HLOS_1`) 之間切換並開機。當升級 OpenWrt 失敗或崩潰時，長按 Reset 即可切回備份系統。

### 2. 開放 Serial Console 控制台選單 (Stage 1)
開機前 2 秒畫面上會顯示 `Hit Ctrl+C for shell...` 提示，按下 `Ctrl + C` 即可進入 U-Boot Shell 進行底層除錯。

### 3. 多階段自動備援開機鏈 (Stages 1 ~ 5)
* **Stage 1**：Serial Console 中斷檢查。
* **Stage 2**：RESET 按鈕狀態判定。
* **Stage 3**：載入當前 Active Slot (HLOS 0 或 1) 的 OpenWrt 核心。若載入失敗，自動降級。
* **Stage 4**：自動載入 Recovery OS。若 Recovery 亦失敗，自動降級。
* **Stage 5**：自動發起 TFTP 網路救磚開機（向 IP `1.2.3.4` 請求 `recovery.img`）。

### 4. 自動修正原廠 U-Boot 限制與網卡功能 (Memory Hack)
自動比對當前 U-Boot 版本 Hash，寫入對應的暫存器修補檔（`uboot_hack` 與 `uboot_net_init`），解除原廠鎖定並確保開機時網卡順利初始化（維護 TFTP 救磚功能）。

### 5. 精確綁定實體扇區位址
自動抓取 `/dev/mmcblk0p18` (`0:HLOS`) 與 `/dev/mmcblk0p19` (`0:HLOS_1`) 之實際起始扇區，並填入 U-Boot `KERNEL` 變數中，防止任何讀錯扇區導致的 Boot Failure。

---

## 🏗️ 雙系統 (Dual Slot) 與 Recovery OS 的架構說明

本設備的 U-Boot 救磚與開機備援體系包含三層防線：

| 系統層級 | 對應分割區 | 主要用途 | 特性說明 |
| :--- | :--- | :--- | :--- |
| **雙 U-Boot 備援** | `0:APPSBL` (`p15`) / `0:APPSBL_1` (`p16`) | 晶片級硬體 Bootloader 備援 | 高通 SBL1 晶片開機層，若 Slot 0 損毀自動降級切至 Slot 1 |
| **雙系統 (Slot 0)** | `0:HLOS` (`mmcblk0p18`) | 正式運行的 OpenWrt 主系統 A | 搭配獨立 rootfs (`p20`)，日常使用與熱升級 |
| **雙系統 (Slot 1)** | `0:HLOS_1` (`mmcblk0p19`) | 正式運行的 OpenWrt 備份系統 B | 搭配獨立 rootfs (`p22`)，可用於備份或測試新版韌體 |
| **Recovery OS** | `rsvd_5` (`mmcblk0p36`) | 獨立救援系統 (Ramdisk) | 記憶體虛擬磁碟系統 (Initramfs)，當雙主系統皆崩潰時的救磚介面 (32MB) |
| **TFTP 網路救磚** | (記憶體載入) | 終極網路救磚鏈 | 由 U-Boot 透過網路下載 `recovery.img` 並直接開機 |

---

### 🔄 多階段自動備援開機流程圖 (Stages 1 ~ 5)

```text
[ Stage 1: Serial 控制台 ] ──(預設放開)──> [ Stage 2: 按鍵判定 (插電源按住 Reset 2~3秒)]
                                                      │
                                           (藍燈恆亮後放開按鈕)
                                                      │
                       ┌──────────────────────────────┼──────────────────────────────┐
                       │ (未按鍵)                     │ (短按 Click < 3秒)           │ (長按 Hold > 3秒)
                       ▼                              ▼                              ▼
             [ Stage 3: Main OS ]           [ Stage 4: Recovery OS ]      [ 切換 Slot 0 ↔ 1 ]
           (開入 active Slot 0 或 1)              (開入 rsvd_5)                    └──> 重回 Stage 3
                       │                              │
                    (啟動失敗)                     (啟動失敗)
                       └──────────────> 降級 ─────────┴──────────────> [ Stage 5: TFTP 網路救磚 ]
                                                                       (向電腦 1.2.3.4 請求 recovery.img)
```

---

## 🛠️ 前置檢查與執行指南

### 0. 檢視設備 MTD / eMMC 分割區資訊 (Partition Inspection)
在執行配置前，可用以下指令確認設備磁碟與 GPT 標籤對照：
```bash
# 1. 檢視 U-Boot 雙槽 (p15 / p16) 之版本字串與 MD5 雜湊值 (最通用 ⭐️)
md5sum /dev/mmcblk0p15 /dev/mmcblk0p16
strings -n10 /dev/mmcblk0p15 | grep "U-Boot"
strings -n10 /dev/mmcblk0p16 | grep "U-Boot"

# 2. 檢視 eMMC 區塊磁碟分割區表
cat /proc/partitions

# 3. 檢視完整 GPT 分割區標籤 (PARTNAME) 對照
for p in /sys/class/block/mmcblk0p*; do printf "%-12s " "${p##*/}"; grep PARTNAME "$p/uevent" 2>/dev/null; done
```

#### 📋 實機標準 GPT 分割區佈局對照表 (Spectrum SAX1V1K 實測驗證)

| 區塊裝置 | 大小 (KB) | PARTNAME 標籤 | 系統角色與用途描述 |
| :--- | :--- | :--- | :--- |
| `mmcblk0p14` | 256 KB | `0:APPSBLENV` | U-Boot 環境變數儲存區 (`fw_setenv`) |
| `mmcblk0p15` | 2048 KB | `0:APPSBL` | **Slot 0 U-Boot 韌體** |
| `mmcblk0p16` | 2048 KB | `0:APPSBL_1` | **Slot 1 U-Boot 韌體** |
| `mmcblk0p17` | 1024 KB | `0:ART` | 無線網卡校準資料 (Atheros Radio Test) |
| `mmcblk0p18` | 8192 KB | `0:HLOS` | **Slot 0 Main OS Kernel 核心** |
| `mmcblk0p19` | 8192 KB | `0:HLOS_1` | **Slot 1 Main OS Kernel 核心** |
| `mmcblk0p20` | 131072 KB | `rootfs` | **Slot 0 Main OS RootFS (128 MB)** |
| `mmcblk0p22` | 131072 KB | `rootfs_1` | **Slot 1 Main OS RootFS (128 MB)** |
| `mmcblk0p24` | 524288 KB | `rootfs_data` | **Slot 0 OpenWrt Overlay (512 MB)** |
| `mmcblk0p25` | 524288 KB | `rootfs_data_1` | **Slot 1 OpenWrt Overlay (512 MB)** |
| `mmcblk0p36` | 32768 KB | `rsvd_5` | **Recovery OS 復原系統 (32 MB Initramfs)** |
| `mmcblk0p38` | 4894942 KB | `user_data` | 大容量使用者資料儲存區 (~4.66 GB) |

---

### 1. 檢查 U-Boot 雙槽 Hash
```bash
md5sum /dev/mmcblk0p15 /dev/mmcblk0p16
```

### 2. 檢查環境變數寫入工具
```bash
which fw_printenv fw_setenv
```

#### 📌 出廠原始 `fw_printenv` 環境變數對照參考 (未套用動態腳本前)
```text
baudrate=115200
bootargs=console=ttyMSM0,115200n8
bootcmd=bootipq
bootdelay=2
ethact=eth0
ethaddr=a4:97:33:28:f1:63
eth1addr=a4:97:33:28:f1:64
eth2addr=a4:97:33:28:f1:64
eth3addr=a4:97:33:28:f1:64
eth4addr=a4:97:33:28:f1:64
ipaddr=192.168.10.10
serverip=192.168.10.1
netmask=255.255.255.0
```

### 3. 執行配置腳本
```bash
chmod +x configure-uboot-dynamic.sh
./configure-uboot-dynamic.sh
```

### 3.5 首次刷機：原廠環境下從 U-Boot 極簡引導 `.itb` 開機 SOP (零硬編碼純淨版)

在原廠 U-Boot 控制台 (`IPQ807x#`) 下，**無須重命名檔案或輸入複雜的 `mw` 雜湊位址**。手動引導僅需 **3 個極簡步驟**，所有雜湊檢查與位址修補將全權交由後續的動態腳本自動處理：

1. **電腦準備**：PC (IP `1.2.3.4`) 開啟 TFTP Server，將下載好的 OpenWrt Initramfs 檔案（例如 `openwrt-xxx-initramfs-uImage.itb`）直接放於根目錄（**完全無須改名**）。
2. **U-Boot 一鍵載入並引導進入 OpenWrt 臨時系統**：
   在 `IPQ807x#` 控制台貼上以下一列指令（請將 `<檔案名稱.itb>` 替換為實際檔名）：
   ```bash
   setenv ipaddr 1.2.3.1; setenv serverip 1.2.3.4; tftpboot 44000000 <檔案名稱.itb> && bootm 44000000
   ```
3. **上傳配置腳本至路由器並執行**：
   成功開入 OpenWrt 記憶體臨時系統後，在電腦透過 `scp` 將腳本上傳至路由器的 `/tmp/` 目錄（請將 `<ROUTER_IP>` 替換為該系統的 IP，**官方預設 Initramfs 系統 IP 通常為 `192.168.1.1`**）：
   ```bash
   scp configure-uboot-dynamic.sh root@<ROUTER_IP>:/tmp/configure-uboot-dynamic.sh
   ```
   登入路由器 SSH 並執行：
   ```bash
   chmod +x /tmp/configure-uboot-dynamic.sh
   /tmp/configure-uboot-dynamic.sh
   ```
   *(所有的 MD5 計算、版本識別、Memory Hack 位址匹配與 Boot 鏈設定，一律由該腳本自動化 100% 完成！)*

### 4. 燒錄安裝 Recovery OS 至 `rsvd_5` 分割區 SOP

腳本配置完成後，需將 OpenWrt Initramfs 救磚映像檔寫入 `rsvd_5`（`mmcblk0p36`）：

#### 🔹 方法 A：在 OpenWrt 系統內直接燒錄 (推薦 ⭐️)
1. 將 OpenWrt Initramfs 映像檔上傳至路由器的 `/tmp/recovery.img`：
   ```bash
   scp openwrt-xxx-initramfs-recovery.itb root@1.2.3.1:/tmp/recovery.img
   ```
2. 在路由器 SSH 終端機內寫入 eMMC：
   ```bash
   dd if=/tmp/recovery.img of=/dev/mmcblk0p36
   sync
   ```

#### 🔹 方法 B：在 U-Boot Shell 透過 TFTP 燒錄
1. 在 PC (IP `1.2.3.4`) 開啟 TFTP Server，將 Initramfs 映像檔命名為 `recovery.img`。
2. 在 U-Boot Shell 控制台執行：
   ```bash
   run boot_write_recovery_from_tftp
   ```

---

## ✅ 腳本套用完成後的 3 大驗證 SOP

當執行完 `./configure-uboot-dynamic.sh` 並全數輸入 `yes` 完成配置後，可用以下 3 個步驟進行驗證：

### 驗證 1：檢查關鍵環境變數 (Software Check)
在 SSH 終端機執行：
```bash
fw_printenv bootcmd boot_stage1 boot_set_slot_0 boot_recovery boot_hack
```
* **合格標準**：`bootcmd` 變更為 `run boot_stage1`；`boot_set_slot_0` 包含動態扇區 `KERNEL=0x8A22`；`boot_hack` 包含 Memory Hack 修補指令。

---

### 驗證 2：檢查 Bootloader 雙槽同步 (Dual-Slot Sync Check)
在 SSH 終端機執行：
```bash
md5sum /dev/mmcblk0p15 /dev/mmcblk0p16
```
* **合格標準**：Slot 0 (`p15`) 與 Slot 1 (`p16`) 的 MD5 雜湊值 **100% 完全相同**。

---

### 驗證 3：硬體 Reset 選單觸發驗證 (Hardware Check)
1. **斷電狀態下，按住 RESET 鈕不放再插上電源**。
2. 保持 **2 ~ 3 秒**，觀察前方 **LED 變為藍燈恆亮** 時鬆開 Reset 鈕。
3. **長按 Reset 鈕 3 秒** ──> 觀察設備能否成功完成槽位切換與降級開入 Recovery OS！

#### 📋 實機成功切換與 Recovery 降級啟動 Serial Console Log 範例
```text
Hit Ctrl+C for shell...
## Info: button pressed, boot paused
Click button for recovery, hold for active boot slot switch...
Saving Environment to MMC...
Writing to MMC(0)... done
## Info: switched active boot slot to: 1
## Info: booting main OS...

MMC read: dev # 0, block # 51746, count 16384 ... 16384 blocks read: OK
Wrong Image Format for bootm command
## Error: main OS boot failed

## Info: booting recovery OS...
MMC read: dev # 0, block # 5217826, count 65536 ... 65536 blocks read: OK
## Loading kernel from FIT Image at 44000000 ...
   Trying 'kernel-1' kernel subimage
     Description:  ARM64 OpenWrt Linux-6.12.94
     Compression:  gzip compressed
```

---

## 5. 雙系統 (A/B 槽) 維護與 CLI 指令切換 SOP

### 💻 透過 SSH 指令手動切換開機槽位 (CLI Slot Switch)

除了在開機時長按 Reset 按鈕切換槽位外，您也可以直接在路由器的 OpenWrt SSH 終端機內使用 CLI 指令手動指定切換開機槽位並重啟：

1. **查看當前活躍槽位**：
   ```bash
   fw_printenv boot_active_slot
   ```
2. **手動指定切換至 Slot 1 開機並重啟**：
   ```bash
   fw_setenv boot_active_slot 1 && reboot
   ```
3. **手動指定切換至 Slot 0 開機並重啟**：
   ```bash
   fw_setenv boot_active_slot 0 && reboot
   ```
4. **一鍵自動切換至「另一個槽位」並重啟**：
   ```bash
   ACTIVE="$( fw_printenv boot_active_slot 2>/dev/null | cut -d= -f2 )"
   if [ "$ACTIVE" = "1" ]; then
     echo "Switching from Slot 1 -> Slot 0..."
     fw_setenv boot_active_slot 0 && reboot
   else
     echo "Switching from Slot 0 -> Slot 1..."
     fw_setenv boot_active_slot 1 && reboot
   fi
   ```

---

#### 🔍 槽位確認與多層級反查策略 (Multi-Tier Slot Detection)

若當前系統或第三方純淨韌體**未安裝 `u-boot-envtools` 或缺少 `/etc/fw_env.config`**，可透過以下三種方式查詢：

```bash
# 方法 1：透過 Kernel cmdline 判定當前活躍槽位 (最萬能 ⭐️)
case "$(cat /proc/cmdline 2>/dev/null)" in
  *mmcblk0p20*|*rootfs_data*)   echo "Active Slot: 0" ;;
  *mmcblk0p22*|*rootfs_data_1*) echo "Active Slot: 1" ;;
  *) echo "Unknown slot" ;;
esac

# 方法 2：直接讀取 eMMC 分區 14 字串 (免安裝任何工具)
strings -n5 /dev/mmcblk0p14 2>/dev/null | grep "^boot_active_slot="

# 方法 3：自動補全 fw_env.config 設定檔 (補齊後即可直接使用 fw_printenv)
[ -f /etc/fw_env.config ] || echo "/dev/mmcblk0p14 0x0 0x40000 0x40000 1" > /etc/fw_env.config
fw_printenv boot_active_slot
```

#### 💡 A/B 槽安全維護理念 (為什麼不自動寫入兩槽？)
A/B 雙系統的核心價值在於**「安全備援」**：
1. **防止新韌體死磚**：Web Upgrade 時僅更新 Slot 0，確保 Slot 1（或備份槽）留有已知穩定的舊版系統。
2. **驗證後再備份**：開入 Slot 0 確認新升級的韌體運作 100% 正常後，再手動/腳本將 Slot 0 複製給 Slot 1。這樣可確保兩槽隨時都處於可成功開機的高可用狀態！

#### 🔹 雙槽自動判定備份指令
預設情況下，`sysupgrade` 僅會更新 Slot 0。在 Slot 0 驗證新系統無誤後，請在 SSH 執行以下自動判定備份指令：

```bash
ACTIVE="$( fw_printenv boot_active_slot 2>/dev/null | cut -d= -f2 )"
if [ "$ACTIVE" = "1" ]; then
  echo "Active slot is 1. Backing up Slot 1 -> Slot 0..."
  dd if=/dev/mmcblk0p19 of=/dev/mmcblk0p18 && dd if=/dev/mmcblk0p22 of=/dev/mmcblk0p20 && sync
else
  echo "Active slot is 0. Backing up Slot 0 -> Slot 1..."
  dd if=/dev/mmcblk0p18 of=/dev/mmcblk0p19 && dd if=/dev/mmcblk0p20 of=/dev/mmcblk0p22 && sync
fi
```

---

## 🐛 實務常見疑問與操作排除 (Troubleshooting & Tips)

### 1. 在 Recovery OS 進行 Web 升級後，重啟依然讀取 Slot 1 失敗並退回 Recovery
* **真實情境**：若先前手動將活躍槽位切換為 **Slot 1 (`boot_active_slot=1`)**，隨後在 Recovery OS 執行 Web Upgrade（預設刷寫至 Slot 0），重啟後 U-Boot 仍會依照設定去讀取尚未刷寫的 Slot 1 (`0xCA22`)，導致開機失敗並再次降級開回 Recovery。
* **快速對策**：
  * **按鍵快速切回**：路由器斷電插電，**按住 Reset 鈕 2~3 秒至藍燈恆亮放開，隨後長按 3 秒** 將活躍槽位切回 **Slot 0**，即可直接開入剛升級好的全新正式系統。
  * **雙槽同步**：進入 Slot 0 驗證系統無誤後，執行 `dd if=/dev/mmcblk0p18 of=/dev/mmcblk0p19 && dd if=/dev/mmcblk0p20 of=/dev/mmcblk0p22 && sync` 備份至 Slot 1。

---

## 🔄 還原 U-Boot 至出廠狀態 SOP

本腳本僅寫入 `/dev/mmcblk0p14` 環境變數暫存區，未修改 Bootloader 韌體本身。若需要完全還原出廠設定，在 U-Boot 控制台 (`IPQ807x#`) 輸入：

```bash
env default -a
saveenv
reset
```
即可完全清除所有自訂變數並恢復原廠預設狀態。
