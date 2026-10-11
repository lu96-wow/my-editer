#lang racket

;;; edit-rebuild/core/test/engine-docs-test.rkt —— Tab 进文档 + 两窗同键（新模型）
;;;
;;; 用同步的本地 require 路径（不启 worker）打开文档窗，然后通过**新引擎**验证：
;;;   · M-d 开窗后 interaction='docs；
;;;   · Tab 在 'docs / 'complete 间切换（docs 路由，priority 1300）；
;;;   · 左右在文档可见时滚文档（docs 路由，priority 1100）；
;;;   · 文档不可见时 Tab 不命中。

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
         "../session/render.rkt"
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

;; 回归：补全接键态（interaction='complete）下，文档重查（内部 hide→reopen）
;; 不能把模式重置成 'docs（否则 up/down 会从“选候选”变成“跳去滚文档”）。
(define s7 (session-set-mode s2 'interaction 'complete))
(define s8 (session-run-hooks s7 'complete-selection
                             (list mvid "foo" '(racket/base)
                                   (list (path->string lib) "foo") #f)))
(define s9 (render s8))
(check-eq? (session-mode s9 'interaction) 'complete)

(delete-file lib) (delete-file main) (delete-directory dir)
