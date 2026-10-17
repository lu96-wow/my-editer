#lang racket

;;; app/base-keys.rkt —— 基础命令小表（编辑 / 移动 / 指针 / 焦点）
;;;
;;; 小表分开定义（逻辑分离、可单测），合并交给 document 类型或全局：
;;;
;;;   (define-doc-kind! 'text #:keymaps (list edit-keys motion-keys pointer-keys))
;;;   (make-keytable global-keys focus-keys)   ; 焦点移动与文档类型无关，放全局
;;;
;;; 命令只引用**状态模型提供的函数**（`ops.rkt` 的 `focus-*`，吃 ctx、内部解析主体
;;; view），因此本文件**不 require core、不手写 (on-view …) 组合**。行为都通过查表 /
;;; 模型函数表达，命令表只描述“哪个键 → 哪个状态操作”。
;;;
;;;   edit-keys    文本编辑：插入 / 删除 / 撤销 / 重做
;;;   motion-keys  光标移动：←→↑↓ / home / end
;;;   pointer-keys 编辑器鼠标行为：按下落点 + 起选，拖动更新选区
;;;   focus-keys   面板间焦点移动（键盘），与文档类型无关，通常合并进全局表
;;;
;;; 拖缝（resize）是布局 chrome，留在 step，不进这里。

(require "../command/main.rkt"
         "world.rkt"
         "ops.rkt")

(provide edit-keys motion-keys pointer-keys focus-keys prefix-edit-keys)

;;; ════════════════════════ 编辑 ════════════════════════

(define edit-keys
  (keys
   [(key 'enter)     (λ (ctx) (focus-insert ctx "\n"))]
   [(key 'backspace) focus-delete-backward]
   [(key 'delete)    focus-delete-forward]
   [(key 'z 'ctrl)   focus-undo]
   [(key 'y 'ctrl)   focus-redo]))

;;; ════════════════════════ 移动（光标） ════════════════════════

(define motion-keys
  (keys
   [(key 'left)  focus-cursor-left]
   [(key 'right) focus-cursor-right]
   [(key 'up)    focus-cursor-up]
   [(key 'down)  focus-cursor-down]
   [(key 'home)  focus-cursor-home]
   [(key 'end)   focus-cursor-end]))

;;; ════════════════════════ 指针（编辑器鼠标行为，下放自 step） ════════════════════════
;;; 鼠标 token 与键盘共用一张表；位置不进 token，在 ctx（panel / doc-point）。
;;; 拖选生命周期（聚焦 + drag 状态 + 落点）也封装在状态模型里，这里只喂 ctx / 当前格。

(define pointer-keys
  (keys
   [(mouse 'press 'left) focus-select-begin]
   [(mouse 'move #f)
    (λ (ctx)
      (define-values (row col) (mouse-position (ctx-event ctx)))
      (focus-select-update ctx row col))]))

;;; ════════════════════════ 前缀编辑（键序列进行中） ════════════════════════
;;; pending 非空时，step 会把这些键**单独**查（不拼进序列）：
;;;   C-d  删掉最后一个待续 token（C-x C-y → C-x）

(define prefix-edit-keys
  (keys
   [(key 'd 'ctrl) (λ (ctx) (pending-backspace))]))

;;; ════════════════════════ 焦点移动（面板间，与文档类型无关） ════════════════════════

(define focus-keys
  (keys
   [(key 'w 'ctrl) (key 'left)  (λ (ctx) (focus-panel-move ctx 'left))]
   [(key 'w 'ctrl) (key 'right) (λ (ctx) (focus-panel-move ctx 'right))]
   [(key 'w 'ctrl) (key 'up)    (λ (ctx) (focus-panel-move ctx 'up))]
   [(key 'w 'ctrl) (key 'down)  (λ (ctx) (focus-panel-move ctx 'down))]))
