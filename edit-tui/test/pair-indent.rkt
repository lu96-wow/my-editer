#lang racket

;;; 两个辅助编辑插件：括号自动配对 / Racket 换行缩进。

(require rackunit
         "../main.rkt"
         "../config/mode.rkt"
         "../lang/racket/api.rkt")

(define (make-editor text path)
  (define engine (make-engine))
  (define mode (buffer-mode-for-creation path text))
  (define-values (store actions)
    (resource-open resource-store-empty
                   #:name "test.rkt"
                   #:path path
                   #:text text
                   #:key-table (buffer-mode-key-table mode)
                   #:mode mode))
  (define state0
    (make-app-state #:resources store
                    #:area (rect 0 0 40 10)))
  (define state1 (run-actions state0 engine actions))
  (define vid 1)
  (define panel (make-panel 'editor 'editor #:views (list vid) #:active vid))
  (define layout (make-layout #:root (make-leaf 'editor)
                              #:panels (hash 'editor panel)
                              #:focus 'editor))
  (values engine vid (struct-copy app-state state1 [layout layout])))

;;; ════════════════ 自动配对 ════════════════

(define-values (pair-engine pair-vid pair-state)
  (make-editor "" "/tmp/edit-tui-pair-test.rkt"))

(define-values (pair-state* pair-actions)
  (step pair-state (key-event (key #\())))
(check-true (pair? pair-actions))
(define pair-state** (run-actions pair-state* pair-engine pair-actions))
(check-equal? (engine-view-text pair-engine pair-vid) "()")
(check-equal? (engine-view-point-column pair-engine pair-vid) 1)

;; text mode 不配对，仍然是普通自插入。
(define-values (_txt-engine txt-vid txt-state)
  (make-editor "" "/tmp/edit-tui-pair-test.txt"))
(define-values (txt-state* txt-actions)
  (step txt-state (key-event (key #\())))
(define _txt-state** (run-actions txt-state* _txt-engine txt-actions))
(check-equal? (engine-view-text _txt-engine txt-vid) "(")

;;; ════════════════ Racket 换行缩进 ════════════════

(check-equal? (racket-indent-for-newline "(define x" 0 9) "  ")
(check-equal? (racket-indent-for-newline "(define (f x)\n  (let ([y 1])\n" 2 0)
              "    ")
(check-equal? (racket-indent-for-newline "foo\n" 1 0) "")

(define-values (indent-engine indent-vid indent-state)
  (make-editor "(define x" "/tmp/edit-tui-indent-test.rkt"))

(void (engine-apply-view-action!
       indent-engine
       (view-action 'select indent-vid
                    (selections-one (caret (point 0 9))))))

(define-values (indent-state* indent-actions)
  (step indent-state (key-event (key 'enter))))
(define indent-state** (run-actions indent-state* indent-engine indent-actions))

(check-equal? (engine-view-text indent-engine indent-vid) "(define x\n  ")
(check-equal? (engine-view-point-line indent-engine indent-vid) 1)
(check-equal? (engine-view-point-column indent-engine indent-vid) 2)

(displayln "edit-tui-rebuild/test/pair-indent.rkt: ok")
