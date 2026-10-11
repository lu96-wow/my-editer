#lang racket

;;; edit-rebuild/core/test/engine-docs-test.rkt —— Tab 进文档 + 两窗同键（新模型）
;;;
;;; 用同步的本地 require 路径（不启 worker）打开文档**浮窗**，然后通过**新引擎**验证：
;;;   · M-d 开窗后 interaction='docs；
;;;   · Tab 在 'docs / 'complete 间切换（docs 路由，priority 1300）；
;;;   · 左右在文档可见时滚文档（docs 路由，priority 1100）；
;;;   · 文档不可见时 Tab 不命中；鼠标点文档 → 'docs；Esc 关窗。

(require rackunit
         racket/file
         "../app/app.rkt"
         "../command/input.rkt"        ; 旧 input
         "../command/key.rkt"             ; 旧 binding 构造
         "../command/engine.rkt"          ; 新引擎
         "../session/session.rkt"
         "../session/adapter.rkt"
         "../session/focus.rkt"
         "../session/hook.rkt"
         "../session/mouse.rkt"
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
;; 文档窗所在窗格的 z 序（大 = 上）。
(define (docs-deep-of s)
  (define d (docs-did s))
  (define v (and d (car (session-document-view-list s d))))
  (for/first ([p (in-list (session-panes s))] #:when (eqv? v (placed-vid p))) (placed-deep p)))
;; 文档浮窗矩形 → (list x y w h) | #f
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

(define s0
  (for/fold ([s (app-session 80 24 #:plugins enabled-plugins)])
            ([f (in-list (list lib main))])
    (render (session-open-file s (normalize f)))))
(define mdid (session-file-did s0 (normalize main)))
(define mvid (car (session-document-view-list s0 mdid)))
(define s1 (render (session-ed-set-point!
                    (session-set-focus s0 (focus-set (session-focus s0) mvid))
                    mvid 2 10)))

;; M-d → 同步本地路径，一帧后文档窗显示，模式 'docs
(define s2 (render (engine-dispatch s1 (in* (key 'd 'alt)))))
(check-true (docs-visible? s2))
(check-eq? (session-mode s2 'interaction) 'docs)

;; Tab → 'complete
(define s3 (engine-dispatch s2 (in* (key 'tab))))
(check-eq? (session-mode s3 'interaction) 'complete)

;; Tab → 'docs
(define s4 (engine-dispatch s3 (in* (key 'tab))))
(check-eq? (session-mode s4 'interaction) 'docs)

;; 文档接键时上下滚文档（不崩、模式不变、仍可见）
(define s5 (engine-dispatch s4 (in* (key 'down))))
(check-eq? (session-mode s5 'interaction) 'docs)
(check-true (docs-visible? s5))

;; 左右在文档可见时滚文档
(define s6 (engine-dispatch s5 (in* (key 'right))))
(check-true (docs-visible? s6))

;; 回归：补全接键态（interaction='complete）下重查不同符号，不能把模式重置成 'docs。
(define s7 (session-set-mode s2 'interaction 'complete))
(define s8 (session-run-hooks s7 'complete-selection
                             (list mvid "foo" '(racket/base)
                                   (list (path->string lib) "foo"))))
(define s9 (render s8))
(check-eq? (session-mode s9 'interaction) 'complete)

;; z 序：谁接键谁在上。interaction='docs → 文档 3000（盖过补全 2000）；
;; interaction='complete → 文档退回基点 100（让补全盖住文档）。
(check-equal? (docs-deep-of s2) 3000)
(check-equal? (docs-deep-of s7) 100)

;; 鼠标点文档浮窗 → interaction 切到 'docs（文档抬起）。
(define dr (docs-rect s3))
(check-not-false dr)
(define s12 (session-mouse-press s3 (+ (first dr) 1) (+ (second dr) 1)))
(check-eq? (session-mode s12 'interaction) 'docs)
(check-equal? (docs-deep-of s12) 3000)

;; 补全菜单关闭（complete-selection #f）后文档**不**自动收回。
(define s10 (render (session-run-hooks s2 'complete-selection (list mvid #f #f #f))))
(check-true (docs-visible? s10))

;; Esc：文档接键时关窗（放最后：文档窗状态是共享可变盒子，关了就影响其它会话值）。
(define s11 (render (engine-dispatch s2 (in* (key 'escape)))))
(check-false (docs-visible? s11))
(check-eq? (session-mode s11 'interaction) #f)

(delete-file lib) (delete-file main) (delete-directory dir)
