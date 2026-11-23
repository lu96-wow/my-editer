# 前端 / 后端参考与工具清单

> 前端：`/home/lu96/work/edit/edit-tui/lang`
> 后端：`/home/lu96/work/racket-s-compiler`
> 外部验证源：`/home/lu96/work/loko`

这份文档只整理“后面写前端、接后端、做验证时要用到的东西”。不是新的架构文档；
架构边界仍以 `edit-tui/lang/README.md` 和后端各目录的 `ARCHITECTURE.md` 为准。

> 注意：`racket-s-compiler` 当前工作树有未提交改动（尤其 RISC-V 正在从
> analyze/dce 旧路径迁到 `code` / `lower-code`）。本清单按**当前工作树**整理，
> 不是按某个旧 commit。

---

## 1. 后端事实源：先读哪些

### 1.1 总入口

| 文件 | 用途 |
| --- | --- |
| `racket-s-compiler/README.md` | 两个目标、顶层流水线、当前完成度 |
| `racket-s-compiler/amd64/README.md` | amd64 子项目地图、测试入口、Loko 验证链 |
| `racket-s-compiler/riscv/riscv-compiler/README.md` | RISC-V 编译器流水线、native 顺序、测试入口 |

### 1.2 amd64 契约

| 文件 | 内容 |
| --- | --- |
| `amd64/ARCHITECTURE.md` | 跨层规则、stage 表、依赖方向、错误模型、尺寸边界 |
| `amd64/SYNTAX.md` | 用户表面语法：item、寄存器、内存、立即数、分支 |
| `amd64/IR.md` | 每层 s-expression 形状、owner、输入/输出、局部性规则 |
| `amd64/GAPS.md` | 当前缺口和已知边界 |
| `amd64/ROADMAP.md` | 路线图 |
| `amd64/compiler/README.md` | compiler 子流水线和目录 |
| `amd64/compiler/flow/DESIGN.md` | core flow 的 stage 选择器与硬边界 |
| `amd64/loko-compatibility/DESIGN.md` | Loko 前端层 |
| `amd64/loko-compatibility/UPSTREAM.md` | 外部 Loko 源码位置、三处改动、重建方式 |
| `amd64/tools/README.md` | dump、缓存、ELF/平铺镜像、QEMU、裸机验证 |

按主题索引：

| 主题 | 文档 |
| --- | --- |
| 指令/编码 | `amd64/amd64-asm/INSTRUCTIONS.md`、`DESIGN.md` |
| 寄存器 | `amd64/amd64-asm/REGISTERS.md` |
| target/填充 | `amd64/amd64-asm/TARGET.md` |
| NASM 数据表 | `amd64/amd64-asm/NASM.md`、`nasm/README.md` |
| `li` / 分支 / 范围 | `amd64/amd64-help/DESIGN.md` |
| ELF 写出 | `amd64/amd64-elf/DESIGN.md` |
| 布局 | `amd64/compiler/layout/DESIGN.md` |
| bind-labels | `amd64/compiler/bind-labels/DESIGN.md` |
| encode | `amd64/compiler/encode/DESIGN.md` |
| analyze / dce | `amd64/compiler/analyze/DESIGN.md`、`dce/DESIGN.md` |

### 1.3 RISC-V 契约

| 文件 | 内容 |
| --- | --- |
| `riscv/riscv-compiler/USAGE.md` | 完整使用手册：语法、API、seed、stage、产物、边界 |
| `riscv/riscv-compiler/SYNTAX.md` | native 表面语法；没有 GAS 方言层 |
| `riscv/riscv-compiler/IR.md` | 层间 s-expression |
| `riscv/riscv-compiler/ARCHITECTURE.md` | stage 地图和模块责任 |
| `riscv/riscv-compiler/DATA.md` | 数据形状、解析入口、共享解析器 |
| `riscv/riscv-compiler/RICH-DATA.md` | rich-data 完整语法 |
| `riscv/riscv-compiler/STRUCT.md` | struct 布局、静态数据、字段访问 |
| `riscv/riscv-compiler/TARGET.md` | target 模型、XLEN、扩展集、填充 |
| `riscv/riscv-compiler/CONSTRAINTS.md` | 尺寸/布局/显式形式约束 |
| `riscv/riscv-compiler/flow/DESIGN.md` | 构建流和硬边界 |
| `riscv/riscv-asm/README.md` | 指令编码表生成、运行时 API、扩展作用域 |
| `riscv/riscv-asm/DESIGN.md` | riscv-asm 的构建/解析/合并设计 |
| `riscv/riscv-asm/riscv-opcodes/README.md` | 上游 opcode 源文件格式 |
| `riscv/riscv-help/DESIGN.md` | `li` / `la` / 跳转 / 分支 / scratch / size |

---

## 2. 后端对前端暴露的入口

### 2.1 amd64

```racket
(require "racket-s-compiler/amd64/compiler/flow/flow.rkt")
```

提供：

```text
stage-table
default-flow
stage-names
providers-of
select-stages
group-names
run-flow
run-stage
compile          ; 默认流 -> build
compile-image    ; 当前 core flow 没有 image 层，主要给扩展 flow 用
flow-value
```

可选 Loko/ELF 流：

```racket
(require "racket-s-compiler/amd64/loko-compatibility/flow.rkt")
```

同一组函数名，但 flow 通过 `extend-flow` 加了：

```text
loko-compat
loko-lower
loko-image
loko-elf
```

常用 selector：

```text
'frontend / 'ir / 'backend / 'all
'loko / 'loko-manual / 'loko-near / 'elf / 'elf-manual
```

核心 seed：

```racket
'((rich-data     . ...)
  (program-items . ...)
  (data-items    . ...)
  (code          . ...)
  (layout-spec   . ...)
  (externs       . ...))
```

核心输出：

```text
build
image       ; loko-elf 流
```

### 2.2 RISC-V

```racket
(require "racket-s-compiler/riscv/riscv-compiler/flow/flow.rkt")
```

提供：

```text
stage-table
default-flow
stage-names
providers-of
stage-groups
group-names
select-stages
run-flow
run-stage
compile
flow-value
```

默认 stage：

```text
load-units
expand-struct
expand-data
flatten
lower-code
validate
emit-unit
layout
check
bind-labels
encode
emit-program
```

层组：

```text
'frontend = load-units expand-struct expand-data flatten lower-code
'backend  = validate emit-unit layout check bind-labels encode emit-program
'all      = default-flow
```

最小编码 API：

```racket
(require "racket-s-compiler/riscv/riscv-compiler/api.rkt")

encode-instruction
instruction-arity
known-instruction?
target?
target-xlen
target-extensions
target-rv64-base
target-rv64-all
target-rv32-all
integer->bytes
padding-bytes
```

### 2.3 两个后端的责任差异

| 项目 | amd64 | RISC-V |
| --- | --- | --- |
| 前端是否给 CFG | 可选；amd64 core 有 `analyze`/`dce` | 必须给 `code` 或由 `lower-code` 只做 blocks+falls；后端不建 CFG/DCE |
| 分支形式 | `expand-pseudo` 默认 near，short 显式 | 前端显式选 short/far；不自动升级 |
| 指令顺序 | 表面 item/nasm 风格 | `riscv-opcodes` native 顺序 |
| target | 显式 `target-amd64` | 显式 `target` |
| 错误 | `problems` + 层内 problem | `problems`；encode 有 problem 拒绝产物 |
| 产物 | `build` / `image` (ELF) | `build` / `program` |

---

## 3. 前端（Racket）参考

### 3.1 本地 Racket Reference

| 文件 | 重点 |
| --- | --- |
| `/usr/racket/doc/reference/syntax-model.html` | read pass / expand pass、syntax object、scope set、binding、phase |
| `/usr/racket/doc/reference/reader.html` | `read` vs `read-syntax`、source location、reader 行为 |
| `/usr/racket/doc/reference/syntax.html` | syntax object API |
| `/usr/racket/doc/reference/module.html` | `module`、`module*`、`#%module-begin` |
| `/usr/racket/doc/guide/module-languages.html` | module language、隐式 form |
| `/usr/racket/doc/guide/module-paths.html` | module path 形式 |
| `/usr/racket/doc/guide/syntax-overview.html` | s-expression / 程序模块基础 |
| `/usr/racket/doc/syntax/` | syntax helper、syntax class、phase |

最关键的 API：

```racket
read-syntax
syntax->datum
datum->syntax
syntax-source
syntax-position
syntax-line
syntax-column
syntax-span
syntax-original?
syntax-scopes
identifier-binding
identifier-transformer-binding
expand
local-expand
expand-syntax
```

### 3.2 现成实现参考

| 位置 | 可借鉴内容 |
| --- | --- |
| `/usr/share/racket/pkgs/syntax-color-lib/syntax-color/` | `racket-lexer`、`scheme-lexer`、`module-lexer`、`token-tree`、`paren-tree` |
| `/usr/share/racket/pkgs/syntax-color-lib/syntax-color/token-tree.rkt` | 增量 token tree 的形状 |
| `/home/lu96/.local/share/racket/9.3/pkgs/racket-langserver/` | `doclib/lexer/snapshot.rkt`、`token-tree.rkt`、`position-journal.rkt`、`lazy-cache.rkt` |
| `racket-langserver/doclib/check-syntax.rkt` | 用 Racket expander 做语义信息的边界 |
| `racket-langserver/doclib/autocomplete/` | 从 expanded/required 模块导出候选 |

### 3.3 本项目已有前端代码

| 文件 | 现状 |
| --- | --- |
| `edit-tui/lang/racket/base/lex.rkt` | 行级词法、跨行字符串/块注释状态 |
| `edit-tui/lang/racket/color/` | 语法/同词/括号着色 |
| `edit-tui/lang/racket/parse/source.rkt` | 启发式 `read`、`#lang`、顶层 `require` / `define` / `provide` |
| `edit-tui/lang/racket/parse/analysis.rkt` | 顶层 form + 局部绑定收集 |
| `edit-tui/lang/racket/parse/workspace.rkt` | 跨 buffer analysis 缓存 |
| `edit-tui/lang/source/` | buffer/disk/virtual snapshot 与优先级 |
| `edit-tui/lang/c/` | 非 Racket 语言的独立前端样板 |

约束：现有 `parse/source.rkt` 是“不完整文本的兜底”，不要直接当语义真源。
新前端应使用 `read-syntax` + Racket expander，再产出 backend 需要的 s-expression。

---

## 4. 外部规范与数据

| 类别 | 来源 |
| --- | --- |
| x86-64 指令语义 | Intel SDM / AMD APM |
| x86 编码表 | NASM `x86/insns.dat`，当前快照 commit `fbdc88565ccccfa0e8c69b21b1953d1eded02e89`，仓库内 `amd64/amd64-asm/nasm/` |
| RISC-V ISA | RISC-V Unprivileged / Privileged spec |
| RISC-V opcode 源 | `riscv/riscv-asm/riscv-opcodes/extensions/` |
| ELF64 | System V ABI + ELF gABI |
| Loko | `/home/lu96/work/loko`，版本约 `0.13.1-dev`；改动清单见 `amd64/loko-compatibility/UPSTREAM.md` |
| LLVM MC | 作为独立编码 oracle，见 `amd64-asm/test-oracle.rkt` |

注意：

- 后端不接受 GAS 文本；RISC-V 输入是 s-expression + native 操作数顺序。
- 后端不负责 ABI 默认值、CFG、DCE、scratch 选择、自动 short/near 升级。
- 这些必须由前端决定，或者由 amd64/RISC-V 各自的显式 stage 处理。

---

## 5. 工具与环境（2026-11 本机状态）

### 5.1 已有

| 工具 | 版本 / 用途 |
| --- | --- |
| `racket` | 9.3，运行前端/测试 |
| `raco` | `raco make` 预编译、`raco test` |
| `llvm-mc` | LLVM 19.1.7，amd64 编码 oracle |
| `llvm-objdump` / `llvm-readelf` / `llvm-objcopy` | LLVM 19.1.7 |
| `gcc` | 14.2.0，辅助构建 |
| `as` / `ld` | GNU binutils 2.44，`acprobe` 等辅助验证 |
| `objdump` / `readelf` | GNU binutils 2.44 |
| `qemu-system-x86_64` | QEMU 10.0.13，整机验证 |
| `qemu-system-riscv64` | QEMU 10.0.13，RISC-V 整机验证 |
| `gdb` | 调试 |
| `mtools` (`mcopy`/`mdir`) | 裸机 FAT 镜像验证 |
| `busybox` | `qemu-run.sh` 的最小 initramfs |
| `perl` | 刷新 NASM `insns.pre.dat` |
| `python3` | 辅助脚本 |
| `git` / `make` | 构建与版本管理 |
| `file` / `strip` / `size` | ELF 检查 |

### 5.2 缺失但不阻塞

| 工具 | 说明 |
| --- | --- |
| `nasm` 可执行文件 | 不需要；仓库已有 `insns.dat` + `insns.pre.dat`。只有刷新快照时才要 Perl + NASM 源 |
| `clang` / `cmake` / `lld` | 当前测试不需要 |
| `qemu-x86_64` / `qemu-riscv64` | 用户态 QEMU 缺失；整机 QEMU 已足够，amd64 也可直接执行 ELF |
| `riscv64-linux-gnu-gcc` | 当前 RISC-V 测试不依赖交叉 GCC |

### 5.3 常用验证命令

```sh
# amd64 全量
cd /home/lu96/work/racket-s-compiler/amd64
./run-tests.sh

# amd64 单测（从仓库根目录）
cd /home/lu96/work/racket-s-compiler
racket amd64/compiler/layout/test.rkt
racket amd64/compiler/test/end-to-end.rkt
racket amd64/amd64-asm/test-oracle.rkt

# RISC-V 全量
cd /home/lu96/work/racket-s-compiler/riscv
racket riscv-compiler-test/run.rkt
racket riscv-compiler/test/compiler-test.rkt

# riscv-asm 生成表与测试
cd /home/lu96/work/racket-s-compiler/riscv/riscv-asm
make test

# riscv-help
raco test /home/lu96/work/racket-s-compiler/riscv/riscv-help/test/*.rkt

# amd64 oracle 辅助
llvm-mc --version
llvm-mc -disassemble ...

# ELF 检查
readelf -h -l -S -s /tmp/prog.elf
objdump -d /tmp/prog.elf
file /tmp/prog.elf
```

### 5.4 Loko 验证链

| 工具 / 文件 | 用途 |
| --- | --- |
| `~/work/loko` | 外部 Loko 源码树 |
| `amd64/tools/build-loko-target.sh` | 安装 `sexp` / `sexp-pc` target，重建 Loko |
| `amd64/tools/loko-flow.rkt` | dump -> 流水线 + 产物缓存 |
| `amd64/tools/write-flat-image.rkt` | 平铺镜像 |
| `amd64/tools/write-cached-elf.rkt` | 缓存的 ELF 字节 -> 文件 |
| `amd64/tools/qemu-run.sh` | QEMU/KVM 真内核启动 |
| `amd64/tools/build-pc-image.sh` | 裸机 pc-repl 镜像 |
| `amd64/tools/smoke-loko-elf.rkt` | ELF 构建 + 执行冒烟 |
| `amd64/tools/acprobe.s` | 检查环境是否支持 #AC |
| `amd64/loko-compatibility/sexp-read.rkt` | 快速读 Loko dump |

常用命令：

```sh
# Loko -> sexp dump
cd ~/work/loko
LOKO_PROGRAM_SEXP=/tmp/prog.sexp LOKO_SOURCE=.akku/lib .akku/env ./loko-prebuilt \
    -feval -ftarget=sexp --compile tests/test-bugs.sps --output /tmp/prog.bin

# dump -> 缓存 -> ELF
cd ~/work/racket-s-compiler/amd64
racket tools/loko-flow.rkt /tmp/prog.sexp /tmp/cache elf
racket tools/write-cached-elf.rkt /tmp/cache/loko-elf.rktd /tmp/prog.elf

# 跑
/tmp/prog.elf
./tools/qemu-run.sh /tmp/prog.elf
```

注意：

- QEMU TCG 不实现 #AC，Loko 镜像会 `exit 70`；优先 KVM。
- Loko 启动会预留 1 GiB 堆，QEMU 内存至少 2 GiB。
- `loko-flow.rkt` 缓存的是**最终产物**，不是中间层；改编译器后用 `--refresh` / `--verify`。

---

## 6. 输出形状速查

### 6.1 amd64

```text
program-items / data-items
  -> measured-layout : segments + anchors + problems
  -> bound-layout    : symbols + link + provides + problems
  -> build           : (build (link ...) (provides ...) (segment ...))
```

`build` 里的 segment：

```scheme
(segment (name 名)
         (kind code|data|hole)
         (start 地址)
         (size n)
         (bytes #vu8(...)))
```

### 6.2 RISC-V

```text
code
  -> measured-layout
  -> bound-layout
  -> build
  -> program
```

最终：

```scheme
(program
  (internal
    (modules ...)
    (rich-data ...)
    (functions ...)
    (offsets ...))
  (external ...))
```

链接文件：

```racket
(require "racket-s-compiler/riscv/riscv-compiler/link-file.rkt")
```

---

## 7. 建议阅读顺序

1. `racket-s-compiler/README.md`
2. `amd64/README.md` + `amd64/ARCHITECTURE.md`
3. `amd64/SYNTAX.md` + `amd64/IR.md`
4. `riscv/riscv-compiler/USAGE.md`
5. `riscv/riscv-compiler/SYNTAX.md` + `IR.md` + `DATA.md`
6. 两个 `flow/*.rkt` 和 `compiler/flow/DESIGN.md` / `riscv-compiler/flow/DESIGN.md`
7. `amd64/tools/README.md` + `loko-compatibility/UPSTREAM.md`
8. Racket reference：`syntax-model.html`、`reader.html`、`module-languages.html`
9. `racket-langserver` 的 lexer / token-tree / position-journal
10. 现有 `edit-tui/lang/racket/parse/` 作为兜底，不当语义真源

---

## 8. 接后端前必须先定下来的前端接口

建议先定这 6 个值，不要先写具体 lowering：

```racket
;; 语言选择
(backend-spec path target selector)

;; 前端 -> 后端
(frontend->backend-seeds syntax-object language/backend-id)
  ; amd64: rich-data / program-items / data-items / code / layout-spec
  ; riscv: rich-data / program-items / data-items / code / layout-spec

;; 后端结果
(backend-result
  (or build image program)
  problems
  diagnostics)

;; 版本
(doc-id, text-version) -> backend-result 缓存键

;; 位置映射
backend span / symbol -> frontend syntax source location

;; 错误映射
backend problem kind -> editor diagnostic range + message
```

需要前端明确负责的事情：

- 顶层 form / module 结构
- `#lang` / module language
- 宏展开（暂用 Racket expander）
- 名字绑定 / scope
- amd64/RISC-V 选择：CFG、DCE、short/near/far、scratch、ABI、栈帧
- 输出 `layout-spec` 的初始策略
- 把后端 `problems` 映射回源码位置

后端只负责：

- 形式检查
- 布局 / 对齐 / 地址求解
- 编码 / 镜像
- 输出 `problems` 和产物
