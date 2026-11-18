# one-click-shell-scripts

集合所有最新一键安装脚本

## Xray

`xray-install.sh`：Xray 一键安装脚本，适用于 systemd 发行版（Debian/Ubuntu、CentOS/RHEL/Rocky/Alma、Fedora）。

支持静默或交互执行、指定版本、按需开启 VLESS / VMess / Shadowsocks 入站（含 TLS 与 VLESS Reality）、本地 API、默认账号与分享链接。

```bash
sudo ./xray-install.sh --silent    # 全默认：VLESS + Reality + API + 默认账号
sudo ./xray-install.sh             # 交互向导，回车接受默认值
sudo ./xray-install.sh --help      # 全部参数
```

安装后：配置 `/usr/local/etc/xray/config.json`，账号 `/usr/local/etc/xray/account.txt`，服务 `systemctl status xray`。

### 依赖

脚本会自动检测并安装缺失的 `curl`（或 `wget`）、`unzip`、`ca-certificates`，按系统选择包管理器（`apt-get` / `dnf` / `yum` / `zypper` / `pacman`）。加 `--no-deps` 可关闭自动安装，改为缺失时报错。

### 升级与卸载

```bash
sudo ./xray-install.sh --upgrade            # 升级到最新，配置不动，旧二进制备份为 xray.bak.<时间戳>
sudo ./xray-install.sh -u -v 26.11.9        # 升级/降级到指定版本
sudo ./xray-install.sh --uninstall          # 卸载服务与二进制，保留配置与日志
sudo ./xray-install.sh --uninstall --purge  # 连配置目录与日志目录一起删除
```

升级失败会自动回滚：下载失败还原旧二进制，配置校验或服务启动失败还原旧二进制并重启旧版本。