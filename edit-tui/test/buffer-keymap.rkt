#lang racket

;;; 键表跟着 resource（core buffer）走：同一个 editor panel 换成另一个 view 时，
;;; active view 对应的 resource 决定键表。

(require rackunit
         "../editor/host-api.rkt"
         "../core/command/api.rkt"
         "../core/layout/api.rkt"
         "../host/event.rkt"
         "../host/final.rkt"
         "../host/keymap.rkt"
         "../host/layout.rkt")

(define engine (make-engine))
(void (engine-create-buffer! engine 1 "a.txt" ""))
(void (engine-create-view! engine 1 1))
(void (engine-create-buffer! engine 2 "b.txt" ""))
(void (engine-create-view! engine 2 2))
(void (engine-create-buffer! engine 6 "c.rkt" ""))
(void (engine-create-view! engine 6 6))

(define (custom-stack text)
  (command-table-stack-from-tables
   (list (keys [(key 't 'ctrl) (insert-command text)]))))

(define r1 (make-resource 1 1 #f "a.txt" (list 1) 'text 0
                          #:command-stack (custom-stack "A")))
(define r2 (make-resource 2 2 #f "b.txt" (list 2) 'text 0
                          #:command-stack (custom-stack "B")))
(define r3 (make-resource 6 6 #f "c.rkt" (list 6) 'racket 0))

(define mode-plugin
  (make-plugin
   #:id 'mode-test
   #:state #t
   #:command-scope 'racket
   #:commands (keys
               [(key 'l 'ctrl)
                (λ (ed state ps)
                  (values (state-with-flash state "racket-key") ps '()))])))

(define layout0 (make-editor-layout #:editor-view 1))
(define-values (layout0b _ok0b?)
  (layout-panel-add-view layout0 'editor 2))
(define-values (layout1* _ok?)
  (layout-panel-add-view layout0b 'editor 6))
(define-values (layout1 _ok1?)
  (layout-panel-set-active-view layout1* 'editor 1))
(define state0
  (make-app-state #:area (rect 0 0 40 10)
                  #:layout layout1
                  #:plugin-states (plugins->states (list mode-plugin))
                  #:resources (resources-add
                               (resources-add
                                (resources-add empty-resources r1) r2)
                               r3)))
(define ed (make-editor #:engine engine
                        #:registry (make-hook-registry '())
                        #:plugins (list mode-plugin)))

(define s-a (handle-editor-event ed state0 (key-event (key 't 'ctrl))))
(check-equal? (engine-view-text engine 1) "A")

;; text resource 没有 racket mode scope。
(define s-text-l (handle-editor-event ed s-a (key-event (key 'l 'ctrl))))
(check-not-equal? (state-flash s-text-l) "racket-key")

;; 同一个 panel 切到 active view 2 -> resource 2 的键表生效。
(define-values (l2 _ok2?) (layout-panel-set-active-view
                           (state-layout s-a) 'editor 2))
(define state2 (state-with-layout s-a l2))
(define s-b (handle-editor-event ed state2 (key-event (key 't 'ctrl))))
(check-equal? (engine-view-text engine 2) "B")
(check-equal? (engine-view-text engine 1) "A")

;; racket resource 使用 mode scope；同一个 panel 换 view 后立即生效。
(define-values (l3 _ok3?) (layout-panel-set-active-view
                           (state-layout s-b) 'editor 6))
(define state3 (state-with-layout s-b l3))
(define s-racket (handle-editor-event ed state3 (key-event (key 'l 'ctrl))))
(check-equal? (state-flash s-racket) "racket-key")

(displayln "edit-tui-rebuild/test/buffer-keymap.rkt: ok")
