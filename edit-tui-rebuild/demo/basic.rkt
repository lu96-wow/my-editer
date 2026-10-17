#lang racket

;;; edit-tui-rebuild/demo/basic.rkt —— 最小可交互 demo
;;;
;;;   racket edit-tui-rebuild/demo/basic.rkt
;;;
;;; 编辑区 + 底部状态栏：
;;;   ←→↑↓ Home End       移动
;;;   Enter/Backspace/Del  编辑
;;;   C-z / C-y            undo / redo
;;;   C-w ←→↑↓             左/右/上/下拆出一个空窗口
;;;   C-w C-w              关闭当前 view
;;;   M-方向               焦点在 region 间移动
;;;   C-q                  退出

(require "../../edit-tui/theme/main.rkt"
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
(define status-rid (region-id 2))

(define engine (make-engine))
(void (engine-create-doc! engine did "main.rkt"
                          "hello, rebuild!\n\nC-w arrows split, C-w C-w close view, M-w close panel, C-n new doc,
C-x C-f open file, C-x C-k close doc, C-x C-d detach view, C-x C-a reattach, C-q quit (asks to save if dirty).\n"))
(void (engine-create-view! engine vid did))

(define ws0 (workspace-empty))
(define baseline0 (engine-view-doc-version (make-engine-view engine) did))
(define ws1 (workspace-add-doc ws0 did (make-doc-meta "main.rkt" #:path "main.rkt" #:saved-version baseline0)))
(define ws2 (workspace-add-view ws1 vid (view-meta did (hash))))
(define ws3 (workspace-add-region ws2 editor-rid
                                  (region editor-rid (list (view-member vid)) vid 'editor)))
(define state0
  (make-state #:workspace ws3
              #:ids (make-id-counter 2 2 3 1)))
(define state1 (install-chrome! engine state0 status-rid))
(define layout*
  (make-split 'tb
              (list (make-leaf editor-rid (flex 1))
                    (make-leaf status-rid (fixed 1) #:borders '()))
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
