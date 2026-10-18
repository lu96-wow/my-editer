#lang racket
(require racket/async-channel
         "../edit-tui/command/key.rkt"
         (prefix-in app: "../edit-tui-rebuild/base/event.rkt")
         "../edit-tui-rebuild/base/id.rkt"
         "../edit-tui-rebuild/base/transition.rkt"
         "../edit-tui-rebuild/model/state.rkt"
         "../edit-tui-rebuild/model/workspace.rkt"
         "../edit-tui-rebuild/model/layout.rkt"
         "../edit-tui-rebuild/effects/engine.rkt"
         "../edit-tui-rebuild/effects/panel.rkt"
         "../edit-tui-rebuild/bootstrap/panel.rkt"
         "../edit-tui-rebuild/plugins/builtin.rkt"
         "../edit-tui-rebuild/plugins/completion/plugin.rkt"
         "../edit-tui-rebuild/runtime/run.rkt"
         "../core/editor/query.rkt")

(define did (doc-id 1))
(define vid (view-id 1))
(define erid (region-id 1))
(define crid (region-id 5))
(define engine (make-engine))
(define text "(define (square x)\n  (* x x))\n")
(void (engine-create-doc! engine did "lab.rkt" text))
(void (engine-create-view! engine vid did))
(define ws (let* ([ws (workspace-empty)]
                  [ws (workspace-add-doc ws did (make-doc-meta "lab.rkt" #:path "/tmp/lab.rkt"))]
                  [ws (workspace-add-view ws vid (view-meta did (hash)))]
                  [ws (workspace-add-region ws erid (region erid (list (view-member vid)) vid 'editor))])
            (struct-copy workspace ws [layout (make-leaf erid)])))
(define s0 (state-set-focus (make-state #:workspace ws #:ids (make-id-counter 2 2 6 1)) vid))
(define s1 (install-completion-popup! engine s0 crid))
(define s2 (startup! editor-env engine s1))
(printf "startup ok, faces at (0,1)=~a\n" (buffer-face-at (engine-doc-buffer engine did) 0 1))

(define (feed s . evs) (transition-state (process-events editor-env engine (make-async-channel) s evs)))
;; 在括号前面插入一个字符：光标到 0:0 然后输入 "(" ? 用 home 再 right
(define s3 (feed s2 (app:key-event (key 'home)) (app:key-event (key 'right))
                 (app:key-event (key 'space))))
(printf "after edit ok, faces at (0,2)=~a\n" (buffer-face-at (engine-doc-buffer engine did) 0 2))
