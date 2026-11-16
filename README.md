# edit

一个用 Racket 写的终端编辑器。目标是做出可日常使用的 TUI 编辑器：多标签 / 分屏、文件树、语法高亮、补全、文档查看、搜索替换，以及 Racket 源码的中英双语对照。

- 纯 Racket 实现，界面基于 [`racket-tui`](https://pkgs.racket-lang.org/package/racket-tui)
- 支持 Linux / Termux（macOS 等 Unix-like 系统可尝试从源码运行）
- 可保存 / 恢复会话
- 插件式能力：Racket / C 语言支持、补全、文档、双语映射等

> 当前开发环境：Racket v9.3。建议使用较新的 Racket 8.x / 9.x；更老版本未验证。

---

## 功能

- **编辑**：插入 / 删除、撤销 / 重做、选区、行首行尾、翻页、鼠标拖选
- **布局**：多标签、左右 / 上下分屏、拖动分隔条、多编辑区（`M-0` ~ `M-9`）
- **文件**：侧边文件树、新建 / 重命名 / 删除、递归查找、点文件显示切换
- **资源面板**：查看已打开 buffer / view、dirty 标记、创建 / 删除 view
- **语言能力**：
  - Racket：语法着色、括号配对、补全、模块 / 本地定义文档
  - C（`.c` / `.h`）：语法着色、`#include` 补全、libc 符号补全、`man` 文档
- **搜索替换**：当前 buffer 查找、选中文本驱动的全局替换
- **双语模式**：Racket buffer 可打开中英对照 mirror（`M-l`），源文件为权威
- **会话恢复**：`C-q s` 退出时保存布局和打开的文件，下次启动恢复
- **错误面板**：插件 / IO 错误统一记录，`C-e` 开关

---

## 依赖

### 必需

| 依赖 | 用途 | 安装方式 |
|---|---|---|
| **Racket**（含 `racket` / `raco`） | 运行时与包管理 | 见下方各平台安装命令 |
| **racket-tui** | 终端 UI | `raco pkg install --auto racket-tui` |
| **html-parsing** | 解析 Racket HTML 文档 | `raco pkg install --auto html-parsing` |
| **bash**、**tar** | 安装脚本 | 系统自带 |
| UTF-8 终端 | 正确显示中文 / 边框 | 任意现代终端 |

一次性安装两个 Racket 包：

```sh
raco pkg install --auto racket-tui html-parsing
```

如果提示权限不足，使用用户级安装：

```sh
raco pkg install --user --auto racket-tui html-parsing
```

### 可选

| 依赖 | 用途 | 安装方式 |
|---|---|---|
| `man` + C 手册页 | 查看 C / POSIX 完整文档 | Debian / Ubuntu：`sudo apt install man-db manpages-dev`<br>Termux：`pkg install man`<br>Arch：`sudo pacman -S man-pages` |
| 中文 man 页 | C 文档中文显示 | Debian / Ubuntu：`sudo apt install manpages-zh`<br>其他发行版安装 `manpages-zh` / `man-pages-zh` 包 |
| `git` | 克隆仓库 | `sudo apt install git` / `pkg install git` |
| `nproc` 或 `getconf` | 安装时并行编译 | 系统自带；缺失时脚本回退到 4 线程 |

没有 `man` 也能用 C 文档功能，只是会退回内置签名 / 摘要索引。

### 安装 Racket

**Debian / Ubuntu**

```sh
sudo apt update
sudo apt install racket
```

发行版仓库中的 Racket 可能较旧。如果遇到兼容问题，建议从
<https://download.racket-lang.org/> 安装官方版本。

**Fedora**

```sh
sudo dnf install racket
```

**Arch Linux**

```sh
sudo pacman -S racket
```

**macOS**

```sh
brew install racket
```

或使用官方安装包。

**Termux（Android）**

```sh
pkg update
pkg install racket
```

### 检查依赖是否就绪

```sh
racket --version
raco pkg show | grep -E 'racket-tui|html-parsing'

# 能输出 ok 即可
racket -e '(require tui) (displayln "tui ok")'
racket -e '(require html-parsing) (displayln "html ok")'
```

---

## 安装

### 方式一：使用安装脚本（推荐）

```sh
git clone https://github.com/lu96-wow/my-editer.git
cd my-editer
./install.sh
```

脚本会：

1. 识别 Linux / Termux；
2. 检查 `racket`、`raco`、`tar` 以及 `tui`、`html-parsing`（只检查，不自动安装）；
3. 复制 `core/` 和 `edit-tui/` 到安装目录；
4. 用 `raco make` 编译；
5. 生成启动器；
6. 必要时把启动器目录加入 `~/.bashrc`。

安装完成后：

```sh
edit-tui
```

如果当前终端找不到命令：

```sh
source ~/.bashrc
```

默认安装路径：

| 平台 | 程序目录 | 启动器 |
|---|---|---|
| Linux | `~/.local/share/edit` | `~/.local/bin/edit-tui` |
| Termux | `~/.local/share/edit` | `$PREFIX/bin/edit-tui` |

### 安装脚本选项

```sh
./install.sh --help
```

| 选项 | 说明 |
|---|---|
| `--prefix DIR` | 程序目录，默认 `~/.local/share/edit` |
| `--bin-dir DIR` | 启动器目录 |
| `--dry-run` | 只打印将执行的操作 |
| `--force` | 覆盖非本脚本创建的目录 / 启动器 |
| `-h`, `--help` | 显示帮助 |

### 方式二：直接从源码运行

先安装依赖：

```sh
raco pkg install --auto racket-tui html-parsing
```

然后在仓库根目录运行：

```sh
racket edit-tui/edit.rkt
```

这种方式不需要安装脚本，适合开发和调试。

---

## 快速上手

```text
C-x h          打开帮助
C-x f          在当前 buffer 中查找
C-s            保存 / 另存为
C-q q          退出（不保存会话）
C-q s          保存会话并退出
C-x b          切换侧边栏：文件树 / 资源
C-b            显示 / 隐藏侧边栏
Tab            插入两个空格
Enter          换行并保持当前行缩进
C-z / C-y      撤销 / 重做
C-w ←→↑↓       拆分当前编辑区
C-w c          进入 resize 模式（方向键调整，Esc / C-b 退出）
C-x ←→↑↓       在编辑区 panel 间移动焦点
M-d            查看光标处标识符文档
M-l            打开 / 关闭 Racket 双语对照
C-e            显示 / 隐藏错误面板
```

完整键位、插件扩展方式、内部分层见 **[`edit-tui/README.md`](edit-tui/README.md)**。

---

## 配置与会话

| 环境变量 | 作用 |
|---|---|
| `EDIT_HOME` | 安装程序目录，默认 `~/.local/share/edit` |
| `XDG_BIN_HOME` | Linux 启动器目录，默认 `~/.local/bin` |
| `EDIT_BASHRC` | 写入 PATH 的 rc 文件，默认 `~/.bashrc` |
| `EDIT_MAN` | 指定 `man` 可执行文件路径 |
| `EDIT_C_MAN_LOCALE` | 强制 C man 页语言，例如 `zh_CN` |
| `EDIT_MAN_LOCALE` | `EDIT_C_MAN_LOCALE` 的备用变量 |
| `LANG` / `LC_ALL` | 未设置上面的变量时，man 语言跟随系统 locale |

会话文件默认写入当前工作目录的：

```text
.editdata/session.rktd
```

- `C-q s` 退出时写入
- `C-q q` 退出时不写
- 缓存 layout / focus / resources / user buffer / view 状态
- 不缓存插件状态、history、UI 内容

---

## 测试

```sh
# 全部 edit-tui 回归测试
bash edit-tui/test/run.sh

# 分层 / 依赖方向检查
racket edit-tui/test/layers.rkt

# 单独运行某个领域测试
racket edit-tui/test/layout.rkt
racket edit-tui/test/hooks.rkt
racket edit-tui/test/filetree.rkt
```

测试依赖 `rackunit`，通常随 Racket 一起安装。

---

## 卸载

```sh
./uninstall.sh
```

同样支持 `--prefix`、`--bin-dir`、`--dry-run`。

卸载会删除：

- 安装目录
- 启动器
- `install.sh` 写入的 PATH 标记块

不会删除工作区中的 `.editdata/` 会话文件。

---

## 目录结构

| 目录 | 内容 |
|---|---|
| `core/` | 文本引擎 + 渲染值：buffer / view / document / history / panel / screen |
| `edit-tui/` | TUI 应用：State + action、editor 操作面、布局、命令、插件、host |
| `edit-tui/lang/` | 语言能力：Racket / C 的词法、着色、补全、文档 |
| `edit-tui/plugins/` | 插件：配对、缩进、着色、文件树、资源、补全、文档、双语 |
| `edit-tui/host/` | 文件 IO、事件、渲染、workspace、会话持久化 |
| `history/` | 旧实现，仅作参考，运行时不依赖 |
| `core-test/`、`edit-tui/test/` | 回归测试 |

更多设计说明：

- [`core/README.md`](core/README.md)：core 的设计决策、分层、写入口
- [`edit-tui/README.md`](edit-tui/README.md)：TUI 目录、数据流、API、完整键位
- [`edit-tui/lang/README.md`](edit-tui/lang/README.md)：语言能力层约定
- [`edit-tui/persist/DESIGN.md`](edit-tui/persist/DESIGN.md)：会话持久化设计

---

## 常见问题

### `找不到 racket`

先安装 Racket，并确认它在 `PATH` 中：

```sh
racket --version
```

Termux 下：

```sh
pkg install racket
```

### `缺少运行时依赖: tui html-parsing`

```sh
raco pkg install --auto racket-tui html-parsing
```

### 安装成功但 `edit-tui: command not found`

```sh
source ~/.bashrc
```

或检查启动器目录是否在 `PATH` 中：

```sh
ls ~/.local/bin/edit-tui
echo "$PATH"
```

### C 文档不完整 / 没有 man 页面

安装 C 手册页：

```sh
# Debian / Ubuntu
sudo apt install man-db manpages-dev

# Termux
pkg install man
```

### 中文显示为乱码或边框错位

确认终端使用 UTF-8，并安装支持宽字符的等宽字体：

```sh
locale
```

### 想改安装位置

```sh
./install.sh --prefix /path/to/edit --bin-dir /path/to/bin
```

---

## 当前限制

- 不支持多进程语言服务
- 文件树暂不自动监听文件系统变化
- 文件树拖拽尚未实现
- 双语模式当前主要针对 Racket
