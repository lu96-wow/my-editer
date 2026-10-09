#lang racket

;;; edit/keys.rkt —— 键表配置（纯数据）
;;;
;;; 编辑命令表 = core 编辑命令 ⊕ 焦点命令（两张可组合的键表 merge）：
;;;     edit-command-keys   插入 / 删除 / 光标移动 / 选区 / 剪贴板 / 撤销重做
;;;     focus-keys          视图间焦点移动（Alt+方向）
;;;     edit-keys           = merge(edit-command-keys, focus-keys)   ← 编辑命令表
;;;     global-keys         全局（退出 / 开关侧栏 / 状态窗口互换 / resize）
;;;     base-keys           = merge(edit-keys, global-keys)
;;;
;;; 编辑命令表可单独替换 / 叠到 document 上；状态窗口自带键表（panel keys）优先。

(require tui "binding.rkt" "../core/keymap.rkt" "command.rkt")

(provide base-keys edit-keys edit-command-keys focus-keys focus-prefix resize-prefix global-keys)

;;; ---------- core 编辑命令（方向键 = 光标） ----------

(define edit-command-keys
  (kbd
   ;; 文本输入
   text-binding     (lambda (ev) (cmd-insert (event-text ev)))
   (key 'enter)     (cmd-insert "\n")
   (key 'backspace) (cmd-backspace)
   (key 'delete)    (cmd-delete)
   ;; 光标移动
   (key 'left)      (cmd-nav 'left #f)
   (key 'right)     (cmd-nav 'right #f)
   (key 'up)        (cmd-nav 'up #f)
   (key 'down)      (cmd-nav 'down #f)
   (key 'home)      (cmd-nav 'home #f)
   (key 'end)       (cmd-nav 'end #f)
   ;; 选区 / 剪贴板
   (key 'a 'ctrl)   (cmd-select-all)
   (key 'c 'ctrl)   (cmd-copy)
   (key 'x 'ctrl)   (cmd-cut)
   (key 'v 'ctrl)   (cmd-paste)
   ;; 历史
   (key 'z 'ctrl)   (cmd-undo)
   (key 'y 'ctrl)   (cmd-redo)))

;;; ---------- 焦点命令（Alt+方向 = 视图间移动；C-p 后接方向） ----------

;; C-p 前缀层：方向键移动焦点，Escape 取消。
(define focus-prefix
  (kbd
   (key 'up)     (cmd-focus 'up)
   (key 'down)   (cmd-focus 'down)
   (key 'left)   (cmd-focus 'left)
   (key 'right)  (cmd-focus 'right)
   (key 'escape) (cmd-prefix-cancel)))

;; C-o 前缀层：左右改宽、上下改高。
(define resize-prefix
  (kbd
   (key 'left)   (cmd-resize-view 'width  -1)
   (key 'right)  (cmd-resize-view 'width   1)
   (key 'up)     (cmd-resize-view 'height -1)
   (key 'down)   (cmd-resize-view 'height  1)
   (key 'escape) (cmd-prefix-cancel)))

(define focus-keys
  (kbd
   (key 'left 'alt)  (cmd-focus 'left)
   (key 'right 'alt) (cmd-focus 'right)
   (key 'up 'alt)    (cmd-focus 'up)
   (key 'down 'alt)  (cmd-focus 'down)
   ;; 前缀：C-p 后接方向 = 焦点移动
   (key 'p 'ctrl)    (prefix "C-p" focus-prefix)
   ;; 前缀：C-o 后接方向 = 改焦点视图尺寸（左/右宽，上/下高）
   (key 'o 'ctrl)    (prefix "C-o" resize-prefix)))

;;; ---------- 编辑命令表 = 编辑 ⊕ 焦点 ----------

(define edit-keys (keymap-merge (list edit-command-keys focus-keys)))

;;; ---------- 全局 ----------

(define global-keys
  (kbd
   (key 'q 'ctrl) (cmd-quit)
   (key 'b 'ctrl) (cmd-toggle 'side)
   (key 'tab)     (cmd-panel-swap)
   ;; resize 需要事件里的尺寸 → spec 用过程
   resize-binding (lambda (ev) (cmd-resize (resize-event-cols ev) (resize-event-rows ev)))
   ;; 鼠标：点击 = 聚焦 + 定位；滚轮 = 滚动光标所在视图
   (mouse 'press 'left '())  (lambda (ev) (cmd-mouse-press (mouse-col ev) (mouse-row ev)))
   (mouse 'scroll 'up '())   (lambda (ev) (cmd-mouse-scroll (mouse-col ev) (mouse-row ev) -1))
   (mouse 'scroll 'down '()) (lambda (ev) (cmd-mouse-scroll (mouse-col ev) (mouse-row ev)  1))))

(define base-keys (keymap-merge (list edit-keys global-keys)))
