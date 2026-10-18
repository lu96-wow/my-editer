#lang racket

;;; edit-tui/demo/state.rkt —— 主编辑区 + 一行 State 观察条
;;;
;;;   racket edit-tui/demo/state.rkt
;;;
;;; 底部一行不是普通状态栏，而是把底层 State 压成一行：
;;;   focus / 光标 / docs / views / regions / pending / message
;;; 操作时可以直接看到 State 的变化。
;;;
;;; 键位：
;;;   ←→↑↓ Home End       移动
;;;   Enter/Backspace/Del  编辑
;;;   C-z / C-y            undo / redo
;;;   C-w ←→↑↓             左/右/上/下拆出一个空窗口
;;;   C-w C-w              关闭当前 view
;;;   M-方向               焦点在 region 间移动
;;;   C-q                  退出

(require "../theme/main.rkt"
         "../base/id.rkt"
         "../model/layout.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/chrome.rkt"
         "../effects/engine.rkt"
         "../chrome/slot.rkt"
         "../bootstrap/defaults.rkt"
         "../plugins/builtin.rkt"
         "../runtime/run.rkt")

(define did (doc-id 1))
(define vid (view-id 1))
(define editor-rid (region-id 1))
(define state-rid (region-id 2))

(define engine (make-engine))
(void (engine-create-doc! engine did "main.rkt"
                          "State observer demo\n\nEdit this buffer. The bottom line is the raw app State:\n  focus / cursor / docs / views / regions / pending / message\n\nTry:\n  C-b  split right\n  C-v  split down\n  C-w  close view\n  M-w  close panel/region\n  M-←  move focus\n  C-q  quit (asks to save if dirty)\n"))
(void (engine-create-view! engine vid did))

(define ws0 (workspace-empty))
(define baseline (engine-view-doc-version (make-engine-view engine) did))
(define ws1 (workspace-add-doc ws0 did (make-doc-meta "main.rkt" #:path "main.rkt"
                                                      #:saved-version baseline)))
(define ws2 (workspace-add-view ws1 vid (view-meta did (hash))))
(define ws3 (workspace-add-region ws2 editor-rid
                                  (region editor-rid (list (view-member vid)) vid 'editor)))
(define state0 (make-state #:workspace ws3 #:ids (make-id-counter 2 2 3 1)))
(define state1 (install-chrome! engine state0 state-rid #:status-mode 'state))
(define layout*
  (make-split 'tb
              (list (make-leaf editor-rid (flex 1))
                    (make-leaf state-rid (fixed 1) #:borders '()))
              (flex 1)))
(define state2 (state-set-workspace state1
                                    (struct-copy workspace (state-workspace state1)
                                                 [layout layout*])))
(define state
  (state-set-focus
   (state-chrome* state2 (λ (c) (chrome-set-message c "ready")))
   vid))

(module+ main
  (run-app default-env state engine))
