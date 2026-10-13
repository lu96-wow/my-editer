#lang racket

;;; edit/plugins/test/docs-instant-test.rkt —— 文档窗当帧显示（不需要下一次按键）
;;;
;;;   raco test edit/plugins/test/docs-instant-test.rkt
;;;
;;; 背景：文档窗的“pending → 标准库 → 本地定义”状态机以前每帧只走一步，且 doc-job
;;; 的 poll 在 tick 之后跑，导致要等下一次事件循环才显示。
;;; 这里用**完全同步**的本地 require 路径锁住：一次 cmd-docs-show 之后只渲染一帧，
;;; 文档窗就该已经打开并带上本地定义。

(require rackunit
         racket/file
         "../../core/app/app.rkt"
         "../../core/focus.rkt"
         "../../core/session/session.rkt"
         "../../core/session/adapter.rkt"
         "../../core/session/focus.rkt"
         "../../core/session/render.rkt"
         "../../core/command/command.rkt"
         "../../core/path.rkt"
         "../catalog.rkt"
         "../ui/document.rkt")

(define (render s)
  (call-with-values (lambda () (session-render s #f)) (lambda (s* . _) s*)))

(define (docs-did s)
  (for/first ([d (in-list (session-document-ids s))]
              #:when (equal? (session-document-name s d) "*docs*")) d))

(define (docs-visible? s)
  (define d (docs-did s))
  (and d (session-visible? s (car (session-document-view-list s d))) #t))

;; 本地 require：lib.rkt 提供 foo，main.rkt require 它并在光标处用 foo。
(define dir (build-path (find-system-path 'temp-dir) (format "di-~a" (random))))
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
                    mvid 2 10)))                    ; 光标在 foo 上

(define s2 (step s1 (cmd-docs-show)))
(define s3 (render s2))                             ; **只渲染一帧**

(check-true (docs-visible? s3))
(check-not-false (regexp-match? #rx"本地定义" (session-document-string s3 (docs-did s3))))
(check-not-false (regexp-match? #rx"\\(define \\(foo" (session-document-string s3 (docs-did s3))))

(delete-file lib)
(delete-file main)
(delete-directory dir)
