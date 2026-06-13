# ACM 实验室 FTP 服务器工具包

这是为 ACMC-ICPC 实验室网络准备的 Windows FTP 服务器工具包，提供终端配置、可选 WebUI、双守护进程、独立打包版本和一键关闭脚本。

默认 FTP 地址：

```text
ftp://192.168.110.107
```

在 Windows 上建议通过资源管理器访问该地址。

## 快速使用

推荐使用已经打包好的独立版本：

1. 解压 `dist/ACM_FTP_Server_Standalone.zip`。
2. 运行 `config.bat`，也可以手动编辑根目录的 `config.ini`。
3. 运行 `start.bat` 启动 FTP 服务。
4. 在资源管理器地址栏输入 `ftp://192.168.110.107`。
5. 需要关闭时运行 `shutdown.bat`。

源码目录中也提供同名功能脚本：

- `start_ftp_server.bat`：启动 FTP 服务和双守护进程。
- `shutdown.bat`：关闭 FTP 服务，同时让守护进程退出。
- `config.bat`：终端配置入口，默认推荐使用。
- `start_control_panel.bat`：启动本地 WebUI，需先在配置中启用。
- `config.ini`：主要配置文件。
- `ftp_config.ini`：兼容旧路径的配置文件。

## 配置说明

主要配置项位于 `config.ini`。程序仍兼容旧路径 `config/ftp_config.ini` 和 `ftp_config.ini`，但新版本推荐直接使用根目录的 `config.ini`。

| 配置项 | 说明 |
| --- | --- |
| `FTP_ROOT` | FTP 文件夹路径，可以是相对路径或绝对路径。禁止设置到 Windows 系统盘。 |
| `HOST` / `PORT` | 监听地址和端口，默认 `192.168.110.107:21`。 |
| `PERMISSION` | 权限模式：`readonly`、`upload`、`readwrite`、`full`、`custom`。 |
| `CUSTOM_PERMISSIONS` | `PERMISSION=custom` 时使用的 pyftpdlib 权限字符串。 |
| `DANGEROUS_ALLOW_ANONYMOUS_DELETE` | 是否允许匿名删除，默认关闭。 |
| `ALLOW_ANONYMOUS` | 是否允许匿名访问。关闭后使用 `USERNAME` 和 `PASSWORD`。 |
| `PASSIVE_PORTS` | 被动模式端口范围，防火墙放行时会用到。 |
| `FTP_ENCODING` | FTP 命令和路径编码，默认 `system`，即跟随系统编码。 |
| `ENABLE_FRONTEND` | 是否启用 WebUI，默认 `false`。 |
| `WATCHDOG_INTERVAL_SECONDS` | 守护进程检查间隔。 |

## 权限模式

- `readonly`：只能浏览和下载，默认值。
- `upload`：允许上传，不允许下载和删除。
- `readwrite`：允许浏览、下载、上传、改名、创建目录，不允许删除。
- `full`：开放常见 FTP 文件权限，但匿名删除仍受 `DANGEROUS_ALLOW_ANONYMOUS_DELETE` 控制。
- `custom`：直接使用 `CUSTOM_PERMISSIONS`。

## 安全约束

- FTP 根目录不能位于 Windows 系统盘，程序会在启动前检查并拒绝。
- 默认不开放删除权限，尤其不要长期允许匿名删除。
- 默认不开启 WebUI，日常配置请使用终端入口。
- 该工具面向实验室局域网使用，不建议直接暴露到公网。
- 修改权限后建议重新启动服务，让配置完全生效。

## 守护进程行为

启动脚本会同时拉起 FTP 服务和两个守护进程。两个守护进程会互相检查；如果某个守护进程退出，另一个会尝试补起。

当使用 `shutdown.bat` 关闭，或 FTP 服务被手动关闭后，守护进程会识别为主动停止并一起退出。

## WebUI

WebUI 是可选的本地控制面板，默认关闭。需要使用时：

1. 将配置中的 `ENABLE_FRONTEND=false` 改为 `ENABLE_FRONTEND=true`。
2. 运行 `start_control_panel.bat`，或在打包版本中运行 `webui.bat`。
3. 使用页面修改配置、启动或关闭服务。

未开启 `ENABLE_FRONTEND` 时，WebUI 启动脚本会直接拒绝启动。

## 项目结构

```text
.
├── ftp_config.ini
├── config.ini
├── start_ftp_server.bat
├── shutdown.bat
├── config.bat
├── start_control_panel.bat
├── scripts/
├── webui/
├── dist/
│   └── ACM_FTP_Server_Standalone.zip
├── FTP服务器使用文档.md
└── 实验室FTP说明.md
```

## 打包产物

`dist/ACM_FTP_Server_Standalone.zip` 是当前整理好的独立包，包含：

- `start.bat`
- `shutdown.bat`
- `config.ini`
- `config.bat`
- `webui.bat`
- `bin/ftp_server.exe`
- `bin/control_panel.exe`
- `config/ftp_config.ini`
- `docs/FTP服务器使用文档.md`

该 zip 用于分发；`dist/ACM_FTP_Server_Standalone/` 是本地展开目录，不纳入 Git 跟踪。

## 维护备注

当前实现基于 `pyftpdlib`。源码模式运行需要 Python 和依赖；打包版本不依赖外部 Python 环境。

## 开源协议

本项目使用 MIT License 开源，详见 `LICENSE`。
