#lang racket

;;; C-x c：主选区文本作为源，当前 buffer 内全局替换。

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
(define (type-text s text)
  (for/fold ([s s]) ([c (in-string text)])
    (handle-editor-event ed s (key-event (key c)))))
(define (select-xs! s)
  (define-values (s* _actions)
    (editor-select! ed s 1
                    (selections-one
                     (selection (point 2 14) (point 2 16)))))
  s*)

;; C-x c -> Replace prompt；源是选中的 "xs"。
(define s-selected (select-xs! s0))
(define s-x (handle-editor-event ed s-selected (key-event* 'x 'ctrl)))
(define s-c (handle-editor-event ed s-x (key-event* 'c)))
(check-true (editor-input-active? s-c))
(check-eq? (editor-input-kind s-c) 'replace-global)

;; 输入 "ys" 后提交：当前 buffer 两处 xs 全部替换。
(define s-typed (type-text s-c "ys"))
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
(define s-x2 (handle-editor-event ed s-selected2 (key-event* 'x 'ctrl)))
(define s-c2 (handle-editor-event ed s-x2 (key-event* 'c)))
(define s-deleted (handle-editor-event ed s-c2 (key-event* 'enter)))
(check-equal? (editor-view-text ed 1)
              (string-replace original "xs" ""))

;; 目标包含源字符串时只替换原文里的匹配，不递归。
(define-values (s-undone2 _a2) (editor-undo! ed s-deleted 1))
(define s-selected3 (select-xs! s-undone2))
(define s-x3 (handle-editor-event ed s-selected3 (key-event* 'x 'ctrl)))
(define s-c3 (handle-editor-event ed s-x3 (key-event* 'c)))
(define s-typed2 (type-text s-c3 "xsy"))
(define s-expanded (handle-editor-event ed s-typed2 (key-event* 'enter)))
(check-equal? (editor-view-text ed 1)
              (string-replace original "xs" "xsy"))

;; 没有选区：不打开输入栏。
(define-values (s-point _a3) (editor-set-point! ed s-undone2 1 1 0))
(define s-x4 (handle-editor-event ed s-point (key-event* 'x 'ctrl)))
(define s-c4 (handle-editor-event ed s-x4 (key-event* 'c)))
(check-false (editor-input-active? s-c4))
(check-true (string-contains? (state-flash s-c4) "no selection"))

(displayln "edit-tui/test/replace.rkt: ok")
