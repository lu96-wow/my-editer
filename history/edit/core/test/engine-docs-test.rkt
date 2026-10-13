#lang racket

;;; edit/core/test/engine-docs-test.rkt —— 文档浮窗 + 浮层焦点栈（新模型）
;;;
;;; 用同步的本地 require 路径（不启 worker）打开文档**浮窗**，然后通过**新引擎**验证：
;;;   · M-d 开窗 → 进浮层栈头（'docs），z 序抬到最上；
;;;   · 上下/左右在文档接键 / 可见时滚文档；
;;;   · 补全接管焦点时文档退回基点 z 序，cycle 再切回；
;;;   · 鼠标点文档 → 文档回栈头；Esc 关窗；
;;;   · 补全结束（complete-selection name=#f）→ 文档**自动关闭**。

(require rackunit
         racket/file
         "../app/app.rkt"
         "../command/input.rkt"
         "../command/key.rkt"
         "../command/engine.rkt"
         "../session/session.rkt"
         "../session/adapter.rkt"
         "../session/focus.rkt"
         "../session/hook.rkt"
         "../session/mouse.rkt"
         "../session/overlay.rkt"
         "../session/render.rkt"
         "../geometry/layout.rkt"
         "../focus.rkt"
         "../path.rkt"
         "../../plugins/catalog.rkt"
         "../../plugins/ui/document.rkt")

(define (render s)
  (call-with-values (lambda () (session-render s #f)) (lambda (s* . _) s*)))
(define (in* b) (input b #f #f #f #f #f))
(define (docs-did s)
  (for/first ([d (in-list (session-document-ids s))]
              #:when (equal? (session-document-name s d) "*docs*")) d))
(define (docs-visible? s)
  (define d (docs-did s))
  (and d (session-visible? s (car (session-document-view-list s d))) #t))
(define (docs-deep-of s)
  (define d (docs-did s))
  (define v (and d (car (session-document-view-list s d))))
  (for/first ([p (in-list (session-panes s))] #:when (eqv? v (placed-vid p))) (placed-deep p)))
(define (docs-rect s)
  (define d (docs-did s))
  (define v (and d (car (session-document-view-list s d))))
  (for/first ([p (in-list (session-panes s))] #:when (eqv? v (placed-vid p)))
    (list (placed-x p) (placed-y p) (placed-w p) (placed-h p))))

(define dir (build-path (find-system-path 'temp-dir) (format "ed-~a" (random))))
(make-directory dir)
(define lib (build-path dir "lib.rkt"))
(define main (build-path dir "main.rkt"))
(display-to-file "#lang racket/base\n(provide foo)\n(define (foo x) x)\n" lib #:exists 'replace)
(display-to-file "#lang racket/base\n(require \"lib.rkt\")\n(define y foo)\n" main #:exists 'replace)

;; 每个场景用独立会话（docs 服务是可变盒子，避免场景间互扰）。
(define (fresh)
  (define s0
    (for/fold ([s (app-session 80 24 #:plugins enabled-plugins)])
              ([f (in-list (list lib main))])
      (render (session-open-file s (normalize f)))))
  (define mdid (session-file-did s0 (normalize main)))
  (define mvid (car (session-document-view-list s0 mdid)))
  (render (session-ed-set-point!
           (session-set-focus s0 (focus-set (session-focus s0) mvid)) mvid 2 10)))

;;; ---------- 1. 开窗 / 栈头 / z 序 / 滚动 ----------

(define s2 (render (engine-dispatch (fresh) (in* (key 'd 'alt)))))
(check-true (docs-visible? s2))
(check-eq? (session-overlay-focus s2) 'docs)
(check-equal? (docs-deep-of s2) 3000)

;; 文档接键时上下滚
(define s5 (engine-dispatch s2 (in* (key 'down))))
(check-eq? (session-overlay-focus s5) 'docs)
(check-true (docs-visible? s5))
;; 文档可见时左右滚
(define s6 (engine-dispatch s5 (in* (key 'right))))
(check-true (docs-visible? s6))

;; 补全接管焦点 → 文档退回基点；cycle → 文档回栈头
(define s7 (session-overlay-focus! s2 'complete))
(check-equal? (docs-deep-of s7) 100)
(define s8 (session-overlay-cycle s7))
(check-eq? (session-overlay-focus s8) 'docs)
(check-equal? (docs-deep-of s8) 3000)

;; 鼠标点文档浮窗 → 文档回栈头
(define dr (docs-rect s7))
(check-not-false dr)
(define s12 (session-mouse-press s7 (+ (first dr) 1) (+ (second dr) 1)))
(check-eq? (session-overlay-focus s12) 'docs)

;;; ---------- 2. Esc 关窗 ----------

(define e2 (render (engine-dispatch (fresh) (in* (key 'd 'alt)))))
(check-true (docs-visible? e2))
(define e3 (render (engine-dispatch e2 (in* (key 'escape)))))
(check-false (docs-visible? e3))
(check-false (session-overlay-focus e3))

;;; ---------- 3. 补全结束 → 文档自动关闭 ----------

(define c2 (render (engine-dispatch (fresh) (in* (key 'd 'alt)))))
(check-true (docs-visible? c2))
(define c3 (render (session-run-hooks c2 'complete-selection (list #f #f #f #f))))
(check-false (docs-visible? c3))
(check-false (session-overlay-focus c3))

(delete-file lib) (delete-file main) (delete-directory dir)
