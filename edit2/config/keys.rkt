#lang racket

;;; config/keys.rkt —— 命令表（**纯数据**，不 require 任何实现）
;;;
;;; entry = (binding scope op ...)
;;;   binding : (key k mod ...) | (cursor kind button) | (text) | (text "x")
;;;             （可打印字符在终端里是 text-event，用 (text "x") 而不是 (key x)）
;;;   scope   : always | editor | float | prompt | split | new | new2
;;;             | (panel name) | (region id)
;;;   op      : core 原语（见 core/step.rkt run-ops）
;;;
;;; 表按功能拆开；key-tables 是**有序**列表，core 用 compose-keymaps 按顺序并：
;;; 后面的表在 (binding scope) 相同时覆盖前面的。
;;; 「组合」与「把表绑定到 document」是两件独立的事（后者在 core/step.rkt）。
;;;
;;; 加/改一条绑定 = 改这里一行数据；加一张表 = 在这里加一个 define 并放进 key-tables。

(provide key-tables doc-key-matchers
         pointer-keys placing-keys split-keys prompt-keys global-keys float-keys
         resource-keys sidebar-keys tree-keys buffers-keys editor-keys
         rkt-keys)

;;; ---------- 指针 / 光标 ----------
(define pointer-keys
  '(((cursor press left)   placing (place-pick))
    ((cursor press left)   always (pointer))
    ((cursor scroll up)    always (scroll -1))
    ((cursor scroll down)  always (scroll 1))))

;;; ---------- 放置选择（打开时多窗口：选目标窗格替换） ----------
(define placing-keys
  '(((key enter)   placing (place-confirm))
    ((key escape)  placing (place-cancel))
    ((key tab)     placing (place-cycle 1))
    ((key n alt)   placing (place-cycle 1))
    ((key p alt)   placing (place-cycle -1))))

;;; ---------- 分屏前缀（C-s 后接方向）：新窗口放在该方向 ----------
;;;   ↑ 新窗在上   ↓ 新窗在下   ← 新窗在左   → 新窗在右（新窗留空）
(define split-keys
  '(((key s ctrl)  always (prefix-split))
    ((key up)      split  (split up))
    ((key down)    split  (split down))
    ((key left)    split  (split left))
    ((key right)   split  (split right))
    ((key escape)  split  (prefix-cancel))))

;;; ---------- 输入行（*input* 文档）：普通光标编辑 + 回车提交 / Esc 取消 ----------
(define prompt-keys
  '(((text)          prompt (insert-event-text))
    ((key backspace) prompt (delete-back))
    ((key delete)    prompt (delete))
    ((key left)      prompt (move left))
    ((key right)     prompt (move right))
    ((key home)      prompt (move home))
    ((key end)       prompt (move end))
    ((key enter)     prompt (submit-prompt))
    ((key escape)    prompt (cancel-prompt))
    ;; C-q 在输入行里也生效：先中断这次输入，再走退出（有脏文档会重新问保存）。
    ((key q ctrl)    prompt (cancel-prompt) (quit))))

;;; ---------- 全局 ----------
(define global-keys
  '(((key q ctrl)  always (quit))
    ((key s alt)   always (save))
    ((key u ctrl)  always (tree-reload))          ; 重读磁盘刷新文件树（不动已打开文档）
    ((key b ctrl)  always (region-toggle sidebar))
    ((key l ctrl)  always (region-toggle log))
    ((key t ctrl)  always (border-toggle))       ; 焦点窗口开关边框
    ((key h ctrl)  always (tree-toggle-hidden))   ; 文件树：显/隐以 . 开头的条目
    ((key e alt)   always (focus editor))
    ((key n alt)   always (focus (cycle 1)))
    ((key p alt)   always (focus (cycle -1)))))

;;; ---------- 浮窗（窗口，不是面板）：打开 / 切换 / 提到最上 / 循环 / 关闭 ----------
;;; 几何取 config/floats.rkt 的 float-specs（按名字）；Esc/Tab 只在**焦点是浮窗**时生效
;;; （scope float = 焦点 wid 是浮窗），所以焦点在编辑器时 Esc/Tab 不会被浮窗抢走。
(define float-keys
  '(((key j alt)   always (float-open log))     ; 浮起日志（已在浮窗则提到最上）
    ((key k alt)   always (float-open tree))    ; 浮起文件树（同 view 多位置）
    ((key g alt)   always (float-toggle log))   ; 开 / 关日志浮窗
    ((key j ctrl)  float  (float-raise))         ; 焦点浮窗提到最上
    ((key tab)     float  (float-cycle))        ; 在浮窗间循环焦点
    ((key escape)  float  (float-close))))      ; 关焦点浮窗（焦点落到下一个浮窗 / 编辑器）

;;; ---------- 关闭：窗口 ≠ 视图 ≠ 文档（资源各自独立） ----------
(define resource-keys
  '(((key d ctrl)  editor (close-window))         ; 只摘窗口（pane），view / document 保留
    ((key d ctrl)  (panel buffers) (close-view))  ; 关选中视图资源（文档保留）
    ((key delete)  (panel buffers) (close-doc)))) ; 关选中文档资源（连带视图）

;;; ---------- 侧栏成员（区域显示 + 聚焦） ----------
(define sidebar-keys
  '(((key t alt)   always (region-activate sidebar tree) (region-focus sidebar))
    ((key b alt)   always (region-cycle sidebar 1) (region-focus sidebar))  ; 加成员不用加键
    ((key tab)     (region sidebar) (region-cycle sidebar 1) (region-focus sidebar))))

;;; ---------- 文件树（面板选择 = 文档导航） ----------
(define tree-keys
  '(((key down)  (panel tree)    (move down))
    ((key up)    (panel tree)    (move up))
    ((key left)  (panel tree)    (move left))
    ((key right) (panel tree)    (move right))
    ((key enter) (panel tree)    (activate))
    ;; C-h 显/隐隐藏项——终端把 C-h 发成 0x08，racket-tui 归类为 'backspace，
    ;; 所以在文件树里把 backspace 也接成同一个动作（核里两者都是同一个字节）。
    ((key backspace) (panel tree) (tree-toggle-hidden))
    ((key d ctrl) (panel tree)   (tree-delete))   ; 删除（需确认）
    ((key n ctrl) (panel tree)   (prefix-new))    ; C-n f 新文件，C-n C-n f 新目录
    ((text "f")   new            (tree-new-file))
    ((text "f")   new2           (tree-new-dir))
    ((key escape) new            (prefix-cancel))
    ((key escape) new2           (prefix-cancel))))

;;; ---------- 缓冲区面板 = 资源管理器 ----------
(define buffers-keys
  '(((key down)  (panel buffers) (move down))
    ((key up)    (panel buffers) (move up))
    ((key right) (panel buffers) (buffers-expand))
    ((key left)  (panel buffers) (buffers-collapse))
    ((text " ")   (panel buffers) (buffers-toggle))
    ((text "n")   (panel buffers) (new-view))     ; 唯一新建 view 的入口
    ((key enter) (panel buffers) (activate))))

;;; ---------- 编辑 ----------
(define editor-keys
  '(((key z ctrl) editor (undo))
    ((key y ctrl) editor (redo))
    ((key a ctrl) editor (select-all))
    ((key c ctrl) editor (copy))
    ((key x ctrl) editor (cut))
    ((key v ctrl) editor (paste))
    ((key enter)     editor (insert "\n"))
    ((key backspace) editor (delete-back))
    ((key delete)    editor (delete))
    ((key left)  editor (move left))
    ((key right) editor (move right))
    ((key up)    editor (move up))
    ((key down)  editor (move down))
    ((key home)  editor (move home))
    ((key end)   editor (move end))
    ((text)      editor (insert-event-text))))

;;; ---------- 有序组合（core 按顺序 compose，后者覆盖前者） ----------
(define key-tables
  (list pointer-keys placing-keys split-keys prompt-keys global-keys float-keys
        resource-keys sidebar-keys tree-keys buffers-keys editor-keys))

;;; ---------- 文件 → document 键表的匹配层（插件层接入点） ----------
;;;
;;; matcher = (ext "rkt") | (name "Makefile") | (regexp "…") | (any)；
;;; 打开 / 定位文件时，按顺序取第一个命中的表挂到该 document 上（core/mode.rkt 只做匹配）。
;;; 插件只要往这里加 (matcher . 表) 就行。
(define rkt-keys '())   ; 占位：将来 *.rkt 的模式命令表
(define doc-key-matchers
  (list (cons '(ext "rkt") rkt-keys)))
