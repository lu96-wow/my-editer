#lang racket

;;; lab-re-rebuild/kernel/effect.rkt —— 状态变换的描述（数据）。
;;;
;;; 命令只返回 (listof effect)，不直接改 session / editor；施加在 pipeline.apply-effect。
;;; 通用能力（prompt 询问 / 通知 / 装文档）在这里留 tag；特性注册 handler（contrib 'effect）。

(provide (struct-out effect) fx
         ;; 编辑
         e-type e-backspace e-delete e-nav
         e-undo e-redo e-select-all e-copy e-cut e-paste
         e-move e-reload
         ;; 文档
         e-doc-add e-doc-show e-close e-save
         ;; 视图
         e-show-view e-view-new e-view-close
         ;; 通用
         e-prompt e-notify
         ;; 输入层（layer 栈）
         e-layer-push e-layer-pop e-layer-set e-layer-pop-until
         ;; 焦点
         e-focus e-focus-push e-focus-restore e-focus-dir
         ;; 主区
         e-split e-pane-close e-pane-swap e-pane-resize
         ;; 停靠区
         e-dock-visible e-dock-toggle e-dock-resize e-dock-cycle
         ;; 鼠标
         e-pointer e-scroll
         ;; 属性
         e-attr-face!
         ;; 会话
         e-session-size e-quit
         ;; 异步
         e-await e-deliver)

(struct effect (tag args) #:transparent)
(define (fx tag . args) (effect tag args))

;; 编辑
(define (e-type vid text [tag #f] [typing? #t]) (fx 'type vid text tag typing?))
(define (e-backspace vid [tag #f])   (fx 'backspace vid tag))
(define (e-delete vid [tag #f])      (fx 'delete vid tag))
(define (e-nav vid dir extend?)      (fx 'nav vid dir extend?))
(define (e-undo vid)                 (fx 'undo vid))
(define (e-redo vid)                 (fx 'redo vid))
(define (e-select-all vid)           (fx 'select-all vid))
(define (e-copy vid)                 (fx 'copy vid))
(define (e-cut vid)                  (fx 'cut vid))
(define (e-paste vid)                (fx 'paste vid))
(define (e-move vid sels)            (fx 'move vid sels))
(define (e-reload vid value)         (fx 'reload vid value))

;; 文档（内核只做「装文档 / 显示文档」；文件 I/O 是特性的事）
(define (e-doc-add text name placement focus?) (fx 'doc-add text name placement focus?))
(define (e-doc-show did placement focus?)      (fx 'doc-show did placement focus?))
(define (e-close dids)                          (fx 'close dids))
(define (e-save did)                            (fx 'save did))

;; 视图：显示已存在 view / 新建 view（不放置）/ 关单个 view
(define (e-show-view vid focus? [placement 'replace]) (fx 'show-view vid focus? placement))
(define (e-view-new did)                              (fx 'view-new did))
(define (e-view-close vid)                            (fx 'view-close vid))

;; 通用：询问一行文本（prompt 特性注册 handler）；发一个生命周期通知
(define (e-prompt label on-submit) (fx 'prompt label on-submit))
(define (e-notify point args)      (fx 'notify point args))

;; 输入层（layer 栈）
(define (e-layer-push spec-id state) (fx 'layer-push spec-id state))
(define (e-layer-pop spec-id)        (fx 'layer-pop spec-id))
(define (e-layer-set spec-id state)  (fx 'layer-set spec-id state))
(define (e-layer-pop-until spec-id)  (fx 'layer-pop-until spec-id))

;; 焦点
(define (e-focus vid)           (fx 'focus vid))
(define (e-focus-push vid)      (fx 'focus-push vid))
(define e-focus-restore         (fx 'focus-restore))
(define (e-focus-dir dir)       (fx 'focus-dir dir))

;; 主区
(define (e-split dir)      (fx 'split dir))
(define e-pane-close       (fx 'pane-close))
(define (e-pane-swap dir)  (fx 'pane-swap dir))
(define (e-pane-resize dir) (fx 'pane-resize dir))

;; 停靠区
(define (e-dock-visible id flag) (fx 'dock-visible id flag))
(define (e-dock-toggle id)       (fx 'dock-toggle id))
(define (e-dock-resize id delta) (fx 'dock-resize id delta))
(define (e-dock-cycle side)      (fx 'dock-cycle side))

;; 鼠标（特性注册处理器）
(define (e-pointer vid row col) (fx 'pointer vid row col))
(define (e-scroll vid delta)    (fx 'scroll vid delta))

;; 属性写回（高亮轨）：先清空、再分层合成 fills；O(1)，不进 history。
(define (e-attr-face! did fills combine) (fx 'attr-face did fills combine))

;; 会话
(define (e-session-size w h) (fx 'session-size w h))
(define e-quit               (fx 'quit))

;; 异步版本闸门：登记挂起（结果由特性传输回灌 e-deliver）。
(define (e-await id version current? on-result) (fx 'await id version current? on-result))
(define (e-deliver id result)                   (fx 'deliver id result))
