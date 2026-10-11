#lang racket

;;; config/keys.rkt —— 命令表（**纯数据**，不 require 任何实现）
;;;
;;; entry = (binding scope op ...)
;;;   binding : (key k mod ...) | (cursor kind button) | (text)
;;;   scope   : always | editor | float | prompt | (panel name)
;;;   op      : core 原语（见 core/step.rkt run-ops）
;;;
;;; 加/改一条绑定 = 改这里一行数据；用已有原语组合出新行为，也能这样写。

(provide key-table)

(define key-table
  '(
    ;; ---------- 指针 / 光标 ----------
    ((cursor press left)   placing (place-pick))
    ((cursor press left)   always (pointer))
    ((cursor scroll up)    always (scroll -1))
    ((cursor scroll down)  always (scroll 1))

    ;; ---------- 放置选择（打开时多窗口：选目标窗格替换） ----------
    ((key enter)   placing (place-confirm))
    ((key escape)  placing (place-cancel))
    ((key tab)     placing (place-cycle 1))
    ((key n alt)   placing (place-cycle 1))
    ((key p alt)   placing (place-cycle -1))

    ;; ---------- 分屏前缀（C-s 后接方向）：方向沿哪条轴，就沿那条轴分 ----------
    ;;   ↑/↓ 上/下堆叠（横分割线）    ←/→ 左右并排（竖分割线）
    ((key s ctrl)  always (prefix-split))
    ((key up)      split  (split v))
    ((key down)    split  (split v))
    ((key left)    split  (split h))
    ((key right)   split  (split h))
    ((key escape)  split  (prefix-cancel))

    ;; ---------- 全局 ----------
    ((key q ctrl)  always (quit))
    ((key s alt)   always (save))
    ((key u ctrl)  always (tree-reload))          ; 重读磁盘刷新文件树（不动已打开文档）
    ((key b ctrl)  always (region-toggle sidebar))
    ((key l ctrl)  always (region-toggle log))
    ((key t ctrl)  always (border-toggle))       ; 焦点窗口开关边框
    ((key h ctrl)  always (tree-toggle-hidden))   ; 文件树：显/隐以 . 开头的条目
    ((key h alt)   always (float-open help))
    ((key e alt)   always (focus editor))
    ((key n alt)   always (focus (cycle 1)))
    ((key p alt)   always (focus (cycle -1)))
    ((key escape)  float  (float-close))
    ((key tab)     float  (float-cycle))

    ;; ---------- 关闭：窗口 ≠ 视图 ≠ 文档（资源各自独立） ----------
    ;; C-d 只摘窗口（pane），view / document 资源保留，可从缓冲区面板再显示。
    ((key d ctrl)  editor (close-window))
    ;; 缓冲区面板 = 资源管理器：C-d 关选中视图资源（文档保留），Delete 关选中文档资源（连带视图）。
    ((key d ctrl)  (panel buffers) (close-view))
    ((key delete)  (panel buffers) (close-doc))

    ;; ---------- 侧栏成员（区域显示 + 聚焦） ----------
    ((key t alt)   always (region-activate sidebar tree) (region-focus sidebar))
    ;; 通用切换：循环侧栏成员（加成员不用加键）
    ((key b alt)   always (region-cycle sidebar 1) (region-focus sidebar))
    ;; 在侧栏里也能切换成员
    ((key tab)     (region sidebar) (region-cycle sidebar 1) (region-focus sidebar))

    ;; ---------- 面板选择 = 文档导航（一切皆 document） ----------
    ;; 文件树：↑↓←→ 都是光标移动（一行一个条目）；Enter 展开/折叠（文件则打开）
    ((key down)  (panel tree)    (move down))
    ((key up)    (panel tree)    (move up))
    ((key left)  (panel tree)    (move left))
    ((key right) (panel tree)    (move right))
    ((key enter) (panel tree)    (activate))
    ;; 文件树：C-d 删除（需确认）；C-n f 新文件，C-n C-n f 新目录
    ((key d ctrl) (panel tree)   (tree-delete))
    ((key n ctrl) (panel tree)   (prefix-new))
    ((key f)      new            (tree-new-file))
    ((key f)      new2           (tree-new-dir))
    ((key escape) new            (prefix-cancel))
    ((key escape) new2           (prefix-cancel))
    ((key down)  (panel buffers) (move down))
    ((key up)    (panel buffers) (move up))
    ((key right) (panel buffers) (buffers-expand))
    ((key left)  (panel buffers) (buffers-collapse))
    ((key space) (panel buffers) (buffers-toggle))
    ((key n)     (panel buffers) (new-view))       ; 唯一新建 view 的入口
    ((key enter) (panel buffers) (activate))

    ;; ---------- 编辑 ----------
    ((key z ctrl) editor (undo))
    ((key y ctrl) editor (redo))
    ((key a ctrl) editor (select-all))
    ((key c ctrl) editor (copy))
    ((key x ctrl) editor (cut))
    ((key v ctrl) editor (paste))
    ((key w ctrl) editor (split h))    ; 分屏：左右（垂直分割线）
    ((key w alt)  editor (split v))    ; 分屏：上下（水平分割线）
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
