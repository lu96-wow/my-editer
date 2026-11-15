#lang racket

;;; C-x c f / C-x c s：主选区文本作为源，当前 buffer 内全局替换。

(require rackunit
         racket/string
         "../editor/host-api.rkt"
         "../core/command/api.rkt"
         "../host/event.rkt"
         "../edit.rkt"
         "../features/input/api.rkt"
         "fixture.rkt")

(define-values (ed state) (make-test-editor))
(define s0 (state-with-screen state (rect 0 0 60 15)))
(engine-set-view-cursor! (editor-engine ed) 1 0 #:column 0)
(define original (editor-view-text ed 1))

(define (key-event* name . mods)
  (key-event (apply key name mods)))
(define (type-text ed s text)
  (for/fold ([s s]) ([c (in-string text)])
    (handle-editor-event ed s (key-event (key c)))))
(define (start-replace! ed s mode-key)
  (define s-x (handle-editor-event ed s (key-event* 'x 'ctrl)))
  (define s-c (handle-editor-event ed s-x (key-event* 'c)))
  (handle-editor-event ed s-c (key-event (key mode-key))))
(define (select-xs! s)
  (define-values (s* _actions)
    (editor-select! ed s 1
                    (selections-one
                     (selection (point 2 14) (point 2 16)))))
  s*)

;; C-x c s -> 子字符串替换；源是选中的 "xs"。
(define s-selected (select-xs! s0))
(define s-c (start-replace! ed s-selected 's))
(check-true (editor-input-active? s-c))
(check-eq? (editor-input-kind s-c) 'replace-global)

;; 输入 "ys" 后提交：当前 buffer 两处 xs 全部替换。
(define s-typed (type-text ed s-c "ys"))
(define s-replaced (handle-editor-event ed s-typed (key-event* 'enter)))
(check-false (editor-input-active? s-replaced))
(check-equal? (editor-view-text ed 1)
              (string-replace original "xs" "ys"))
(check-equal? (state-flash s-replaced) "replaced 2 occurrences")

;; 一次 undo 回退整次全局替换。
(define-values (s-undone _a1) (editor-undo! ed s-replaced 1))
(check-equal? (editor-view-text ed 1) original)

;; 目标为空：删除所有匹配。
(define s-selected2 (select-xs! s-undone))
(define s-c2 (start-replace! ed s-selected2 's))
(define s-deleted (handle-editor-event ed s-c2 (key-event* 'enter)))
(check-equal? (editor-view-text ed 1)
              (string-replace original "xs" ""))

;; 目标包含源字符串时只替换原文里的匹配，不递归。
(define-values (s-undone2 _a2) (editor-undo! ed s-deleted 1))
(define s-selected3 (select-xs! s-undone2))
(define s-c3 (start-replace! ed s-selected3 's))
(define s-typed2 (type-text ed s-c3 "xsy"))
(define s-expanded (handle-editor-event ed s-typed2 (key-event* 'enter)))
(check-equal? (editor-view-text ed 1)
              (string-replace original "xs" "xsy"))

;; C-x c f -> 完整匹配：define 不命中 define-value。
(define-values (ed2 state2)
  (make-editor-app #:initial-text "define define-value\n"
                   #:initial-name "defs.rkt"
                   #:initial-resource? #t))
(define s2-0 (state-with-screen state2 (rect 0 0 60 15)))
(define-values (s2-selected _a2b)
  (editor-select! ed2 s2-0 1
                  (selections-one
                   (selection (point 0 0) (point 0 6)))))
(define s2-c (start-replace! ed2 s2-selected 'f))
(check-true (editor-input-active? s2-c))
(define s2-typed (type-text ed2 s2-c "definition"))
(define s2-replaced (handle-editor-event ed2 s2-typed (key-event* 'enter)))
(check-equal? (editor-view-text ed2 1)
              "definition define-value\n")
(check-equal? (state-flash s2-replaced) "replaced 1 occurrence")

;; 没有选区：不打开输入栏。
(define-values (s-point _a3) (editor-set-point! ed s-undone2 1 1 0))
(define s-c4 (start-replace! ed s-point 's))
(check-false (editor-input-active? s-c4))
(check-true (string-contains? (state-flash s-c4) "no selection"))

(displayln "edit-tui/test/replace.rkt: ok")
