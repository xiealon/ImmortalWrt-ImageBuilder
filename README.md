# CrowdSec + LXC 开机自动对接 —— 补丁包

把包内所有文件按下面的路径**覆盖**到你的仓库根目录即可。
（路径与仓库内原有结构一一对应，直接解压覆盖最省事）

## 文件与放置位置

| 包内路径 | 仓库内位置（= 解压后覆盖到哪里） | 固件内最终位置 | 作用 |
|---|---|---|---|
| `shell/prepare-crowdsec-rootfs.sh` | `shell/prepare-crowdsec-rootfs.sh` | 不进固件 | 编译期在 GitHub runner 上 chroot 装 CrowdSec，产出 rootfs 压缩包 |
| `files/usr/sbin/crowdsec-lxc-bootstrap.sh` | `files/usr/sbin/crowdsec-lxc-bootstrap.sh` | `/usr/sbin/crowdsec-lxc-bootstrap.sh` | 首次开机：解压→起容器→取 LAPI key→写回 bouncer |
| `files/etc/rc.local` | `files/etc/rc.local` | `/etc/rc.local` | 开机末尾后台拉起上面的引导脚本 |
| `files/etc/uci-defaults/99-custom.sh` | `files/etc/uci-defaults/99-custom.sh` | `/etc/uci-defaults/99-custom.sh` | 日志外发 UDP 514、容器自启、bouncer 预填、cgroup2 兜底 |
| `shell/apk-custom-packages.sh` | `shell/apk-custom-packages.sh` | — | **25.12(apk)** 包列表：bouncer + LXC |
| `shell/custom-packages.sh` | `shell/custom-packages.sh` | — | **24.x(opkg)** 包列表：去重 + cgroup 包标注 |
| `x86-64/build25.sh` | `x86-64/build25.sh` | — | 新增第三方 apk 源 / 公钥支持 |
| `.github/workflows/build-x86-64-25.12.x.yml` | `.github/workflows/build-x86-64-25.12.x.yml` | — | 新增 `include_crowdsec` 开关与预制步骤 |
| `.gitattributes` | `.gitattributes` | — | 强制 LF，防止 Windows 提交把脚本变 CRLF |
| `shell/apk-keys/README.txt` | `shell/apk-keys/README.txt` | — | 第三方 apk 源公钥存放目录说明（可留空） |

## 关键规则

- `files/` 下的目录结构 = 固件内的目录结构，由 `make image FILES=...` 原样打进固件。
  所以 `files/etc/rc.local` 最终就是路由器的 `/etc/rc.local`。
- **24.x 与 25.12 的包列表是两个文件，别改错：**
  - `shell/custom-packages.sh` → 24.x（opkg），被 12 个机型的 build*.sh 共用
  - `shell/apk-custom-packages.sh` → 25.12（apk），只被 build25.sh 读
  - cgroupfs-mount / cgroup-tools 只留在 24.x 那份，**不要搬到 25.12**
- 新增的 3 个脚本必须是 **LF** 换行且带可执行位；压缩包内已统一为 LF。
  覆盖后建议执行一次：
      git update-index --chmod=+x shell/prepare-crowdsec-rootfs.sh \
                                  files/usr/sbin/crowdsec-lxc-bootstrap.sh \
                                  files/etc/rc.local

## 使用

Actions 里跑 `Build 25.12.x x86-64`：
- `include_crowdsec` 选 `yes`
- `profile` 选 **2G 以上**
- 其余按原样

刷机后检查：
    cat /var/log/crowdsec-lxc-bootstrap.log
    uci show crowdsec          # api_key 应已写入
    nft list table ip crowdsec # 应能看到 crowdsec-blacklists 集合
