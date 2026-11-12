#lang racket

;;; C-x f 查找；C-left / C-right 前后移动匹配项。

(require rackunit
         racket/string
         "../editor/host-api.rkt"
         "../core/command/api.rkt"
         "../host/event.rkt"
         "../edit.rkt"
         "../features/input/api.rkt"
         "../features/find/model.rkt"
         "fixture.rkt")

(define-values (ed state) (make-test-editor))
(define s0 (state-with-area state (rect 0 0 60 15)))
(engine-set-view-cursor! (editor-engine ed) 1 0 #:column 0)

(define (key-event* name . mods)
  (key-event (apply key name mods)))
(define (type-text s text)
  (for/fold ([s s]) ([c (in-string text)])
    (handle-editor-event ed s (key-event (key c)))))

;; C-x f -> Find prompt
(define s-x (handle-editor-event ed s0 (key-event* 'x 'ctrl)))
(define s-f (handle-editor-event ed s-x (key-event* 'f)))
(check-true (editor-input-active? s-f))
(check-eq? (editor-input-kind s-f) 'find)

;; 查找 "xs"：样例文本里有两个。
(define s-typed (type-text s-f "xs"))
(define s-found (handle-editor-event ed s-typed (key-event* 'enter)))
(check-false (editor-input-active? s-found))
(define f1 (state-find s-found))
(check-true (find-state? f1))
(check-equal? (find-state-index f1) 0)
(check-equal? (length (find-state-matches f1)) 2)
(check-true (string-contains? (state-flash s-found) "1/2"))

;; C-right -> 下一个
(define s-next (handle-editor-event ed s-found (key-event (key 'right 'ctrl))))
(check-equal? (find-state-index (state-find s-next)) 1)
(check-true (string-contains? (state-flash s-next) "2/2"))

;; C-left -> 上一个
(define s-prev (handle-editor-event ed s-next (key-event (key 'left 'ctrl))))
(check-equal? (find-state-index (state-find s-prev)) 0)
(check-true (string-contains? (state-flash s-prev) "1/2"))

(displayln "edit-tui/test/find.rkt: ok")
