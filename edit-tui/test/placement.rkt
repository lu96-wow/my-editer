#lang racket

;;; placement：方向键换目标 / Enter 提交 / Esc 取消 / 鼠标点 editor 放入。

(require rackunit
         racket/file
         racket/path
         "../editor/host-api.rkt"
         "../core/layout/api.rkt"
         "../host/final.rkt"
         "fixture.rkt"
         "../features/placement/api.rkt"
         "../host/open.rkt")

(define root (make-temporary-directory))
(define (make-file name text)
  (define p (build-path root name))
  (display-to-file text p #:exists 'replace)
  p)

(define-values (ed state) (make-test-editor))
(define s0 (state-with-area state (rect 0 0 60 15)))
(define-values (s1 _a1) (editor-split! ed s0 'right))
(check-equal? (length (editor-visible-editor-panels s1)) 2)

;; 打开文件 -> placement；默认焦点保持当前 editor。
(define f1 (make-file "one.txt" "one"))
(define-values (s2 _a2) (editor-open-file! ed s1 f1))
(check-true (editor-placement-active? s2))
(define vid1 (editor-placement-view-id s2))

;; 方向键换目标 -> commit
(define-values (s3 _a3) (editor-placement-focus! ed s2 'left))
(check-equal? (editor-focus-panel-id s3) 'editor)
(define-values (s4 _a4) (editor-placement-commit ed s3))
(check-false (editor-placement-active? s4))
(check-equal? (layout-panel-for-view (state-layout s4) vid1) 'editor)

;; Esc 取消：resource 仍存在，但 view 不挂 panel。
(define f2 (make-file "two.txt" "two"))
(define-values (s5 _a5) (editor-open-file! ed s4 f2))
(check-true (editor-placement-active? s5))
(define vid2 (editor-placement-view-id s5))
(define-values (s6 _a6) (editor-placement-cancel ed s5))
(check-false (editor-placement-active? s6))
(check-false (layout-panel-for-view (state-layout s6) vid2))
(check-not-false (state-resource-for-view s6 vid2))

;; 鼠标点 editor panel 放入。
(define f3 (make-file "three.txt" "three"))
(define-values (s7 _a7) (editor-open-file! ed s6 f3))
(define vid3 (editor-placement-view-id s7))
(define rects (layout-panel-rects (state-layout s7) (state-area s7)))
(define rr (hash-ref rects 100))
(define-values (s8 _a8 handled?)
  (editor-placement-mouse! ed s7 (+ (rect-y rr) 1) (+ (rect-x rr) 1)))
(check-true handled?)
(check-false (editor-placement-active? s8))
(check-equal? (layout-panel-for-view (state-layout s8) vid3) 100)

(delete-directory/files root)
(displayln "edit-tui-rebuild/test/placement.rkt: ok")
