# FTP 服务器使用文档

## 文件说明

- `config.ini`：FTP 与前端控制面板的主要配置文件。
- `ftp_config.ini`：旧版兼容配置文件。
- `config.bat`：终端配置入口，推荐默认使用。
- `install_pyftpdlib.bat`：源码模式下检查并补全 Python/pip/pyftpdlib 环境。
- `start_ftp_server.bat`：启动 FTP 服务与双守护进程。
- `stop_ftp_server.bat`：停止 FTP 服务与双守护进程。
- `shutdown.bat`：正式关闭 FTP 服务与双守护进程。
- `start_control_panel.bat`：启动本地前端控制面板。
- `stop_control_panel.bat`：停止本地前端控制面板。
- `webui/`：前端页面文件。
- `scripts/`：FTP 服务、守护进程、控制面板后端脚本。

## 首次使用

1. 打开当前文件夹。
2. 双击运行 `config.bat`，根据终端菜单修改权限、目录、匿名访问等配置。
3. 双击运行 `start_ftp_server.bat` 启动 FTP 服务。

启动时会先检查运行环境。源码模式下如果缺少 Python 3、pip 或 `pyftpdlib`，终端会先询问是否安装；输入 `Y` 后会自动补全环境。打包版本自带 exe，正常不需要安装 Python。

默认不启用前端控制面板。若确实需要使用前端，先在 `config.bat` 中开启前端，或手动设置：

```ini
ENABLE_FRONTEND=true
```

然后双击运行 `start_control_panel.bat`，在浏览器中打开：

```text
http://127.0.0.1:8088
```

## 前端控制面板开关

前端是否允许启动由 `config.ini` 控制，默认关闭：

```ini
ENABLE_FRONTEND=false
```

- `true`：允许运行 `start_control_panel.bat` 打开本地前端控制面板。
- `false`：禁止启动前端控制面板。

注意：前端控制面板只绑定本机地址 `127.0.0.1`，不会对局域网开放。

## 常用配置

```ini
FTP_ROOT=ftp-root
HOST=192.168.110.107
PORT=21
PERMISSION=readonly
ALLOW_ANONYMOUS=true
FTP_ENCODING=system
MAX_DOWNLOAD_SIZE_MB=100
SHOW_STARTUP_LOGS=true
```

说明：

- `FTP_ROOT`：FTP 共享文件夹。可以是相对路径或绝对路径。
- `HOST`：监听地址，默认是实验室 FTP 地址 `192.168.110.107`。
- `PORT`：FTP 端口，默认 `21`。
- `PERMISSION`：权限模式。
- `ALLOW_ANONYMOUS`：是否允许匿名访问。
- `FTP_ENCODING`：FTP 命令与路径编码，默认 `system`，跟随系统首选编码。
- `MAX_DOWNLOAD_SIZE_MB`：单个文件下载或双击打开的最大体积，默认 `100` MB，设置为 `0` 表示不限制。
- `SHOW_STARTUP_LOGS`：启动窗口是否显示最近的守护进程/服务日志，默认 `true`。设置为 `false` 时不在窗口输出，但日志仍写入 `logs/`。

## FTP 文件夹限制

`FTP_ROOT` 不允许设置在 Windows 系统盘上。

例如，如果系统盘是 `C:`，以下路径都会被拒绝：

```text
C:\FTPShare
C:\Users\xxx\Desktop\FTP
C:\
```

建议使用非系统盘目录，例如：

```ini
FTP_ROOT=D:\FTPShare
```

当前默认值为：

```ini
FTP_ROOT=ftp-root
```

它会在当前项目目录下创建并使用 `ftp-root` 文件夹。

## 权限模式

`PERMISSION` 可选值：

- `readonly`：只读，可以列目录和下载文件。
- `upload`：允许上传，不允许下载和删除。
- `readwrite`：允许读写、重命名、创建文件夹，不允许删除。
- `full`：开放常用 FTP 文件权限。
- `custom`：使用 `CUSTOM_PERMISSIONS` 自定义 pyftpdlib 权限字符。

默认推荐：

```ini
PERMISSION=readonly
```

如需临时上传文件，可改为：

```ini
PERMISSION=readwrite
```

也可以直接运行：

```text
config.bat
```

然后选择 `Set permission` 修改权限模式。

## 编码设置

默认编码为：

```ini
FTP_ENCODING=system
```

`system` 表示跟随系统首选编码。中文 Windows 上通常会解析为 `cp936/gbk` 一类编码。

常用可选值：

- `system`：跟随系统。
- `utf-8`：UTF-8。
- `gbk` / `cp936`：中文 Windows 常用编码。
- `gb2312`：简体中文旧编码。
- `big5`：繁体中文常用编码。

终端修改方式：

```text
config.bat
```

然后选择 `Set FTP encoding`。

## 双击查看与大文件限制

在 Windows 资源管理器中访问 FTP 文件夹时，双击 PDF、图片、文本等文件，会由资源管理器请求下载该文件，再交给系统默认程序打开。

服务端会在下载前检查文件大小：

```ini
MAX_DOWNLOAD_SIZE_MB=100
```

- 小于或等于该大小的文件可以正常打开或下载。
- 大于该大小的文件会被 FTP 服务拒绝，客户端会收到 `550 File too large`。
- 如确实需要不限制大小，可设置为 `0`。

终端修改方式：

```text
config.bat
```

然后选择 `Set max download size`。

## 环境检查与自动补全

源码模式运行依赖 Python 3、pip 和 `pyftpdlib`。当环境不完整时，`start_ftp_server.bat` 会先询问是否自动补全：

- 缺少 Python 3：尝试通过 Windows `winget` 安装 Python。
- 缺少 pip：尝试通过 `ensurepip` 修复。
- 缺少 `pyftpdlib`：安装到 `.ftp_runtime/packages`，不写入系统 Python 目录。

也可以运行：

```text
config.bat
```

然后选择 `Check/repair environment` 手动检查。

## 匿名删除保护

即使设置了 `PERMISSION=full`，匿名删除默认仍会被拦截：

```ini
DANGEROUS_ALLOW_ANONYMOUS_DELETE=false
```

只有在短时间、有人看管的维护场景下，才建议临时改为：

```ini
DANGEROUS_ALLOW_ANONYMOUS_DELETE=true
```

## 账号密码模式

默认允许匿名访问：

```ini
ALLOW_ANONYMOUS=true
```

如果要改为账号密码登录：

```ini
ALLOW_ANONYMOUS=false
USERNAME=ftp
PASSWORD=请改成强密码
```

注意：普通 FTP 是明文协议，账号、密码和文件内容都不会加密。仅建议在可信局域网内使用。

## 启动与停止

启动 FTP：

```text
start_ftp_server.bat
```

停止 FTP：

```text
shutdown.bat
```

`stop_ftp_server.bat` 也会调用 `shutdown.bat`，两者都属于正式关闭。

启动前端控制面板：

```text
start_control_panel.bat
```

停止前端控制面板：

```text
stop_control_panel.bat
```

## 双守护进程

运行 `start_ftp_server.bat` 后，会启动两个守护进程：

- `FTP Watchdog A`
- `FTP Watchdog B`

它们会检查 FTP 服务是否仍在运行。如果 FTP 服务异常退出，会尝试重新拉起。

两个守护进程也会互相检查：

- 如果 A 发现 B 不在，会自动拉起 B。
- 如果 B 发现 A 不在，会自动拉起 A。
- 如果通过 `shutdown.bat` 正式关闭，脚本会写入 `.ftp_runtime\shutdown.request` 标记，A 和 B 看到后都会退出，不再重启 FTP。
- 如果 FTP 服务进程被手动关闭，守护进程会将其视为手动停服，自动写入 `.ftp_runtime\shutdown.request`，随后两个守护进程也会一起退出。

## 日志与运行文件

- `logs/`：运行日志。
- `.ftp_runtime/`：运行时文件，例如 PID 文件和本地依赖包。

这些文件夹由脚本自动创建。

如果不希望 `start.bat` 或 `start_ftp_server.bat` 在启动后显示最近日志，可设置：

```ini
SHOW_STARTUP_LOGS=false
```

该开关只影响启动窗口显示，不影响日志文件写入。

## 安全建议

- 默认保持 `PERMISSION=readonly`。
- 不要把 `HOST` 改成 `0.0.0.0`，除非确认需要监听所有网卡。
- 不要把 `FTP_ROOT` 设置到系统盘。
- 不要长期使用 `PERMISSION=full`。
- 不要在非可信网络中使用普通 FTP 账号密码登录。
- 如需长期对外开放，建议改用 FTPS 或 SFTP。
