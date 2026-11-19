# one-click-shell-scripts

常用服务的一键安装脚本集合。

## Xray

`xray-install.sh`：Xray 一键安装脚本，适用于 systemd 发行版（Debian/Ubuntu、CentOS/RHEL/Rocky/Alma、Fedora）。

支持交互向导与静默安装、指定版本、按需开启 VLESS / VMess / Shadowsocks 入站（含 TLS 与 VLESS Reality）、本地 API、默认账号与分享链接、升级与卸载。

### 一键安装

```bash
# 静默安装：VLESS + Reality + API + 默认账号
curl -fsSL https://raw.githubusercontent.com/misakanetwork2018/one-click-shell-scripts/main/xray-install.sh | sudo bash -s -- --silent
```

```bash
# 交互安装：逐项询问，回车接受默认值
curl -fsSL https://raw.githubusercontent.com/misakanetwork2018/one-click-shell-scripts/main/xray-install.sh -o xray-install.sh && sudo bash xray-install.sh
```

### 常用操作

```bash
# 升级到最新版本（配置不动）
curl -fsSL https://raw.githubusercontent.com/misakanetwork2018/one-click-shell-scripts/main/xray-install.sh | sudo bash -s -- --upgrade

# 卸载（保留配置与日志）
curl -fsSL https://raw.githubusercontent.com/misakanetwork2018/one-click-shell-scripts/main/xray-install.sh | sudo bash -s -- --uninstall
```

### 说明

- 安装后：配置 `/usr/local/etc/xray/config.json`，账号与分享链接 `/usr/local/etc/xray/account.txt`，服务状态 `systemctl status xray`。
- 依赖（`curl`/`wget`、`unzip`、`ca-certificates`）缺失时按系统包管理器自动安装。
- 完整参数、协议配置示例与故障排查见 [Wiki](https://github.com/misakanetwork2018/one-click-shell-scripts/wiki)。