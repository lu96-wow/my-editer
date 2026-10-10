#lang racket

;;; plugins/test/word-color-test.rkt —— 词着色与会话（headless）
;;;
;;;   raco test edit-rebuild/plugins/test/word-color-test.rkt
;;;
;;; 不变量：
;;;   1. 色只随文本变；**光标移动不改色**；
;;;   2. 正在输入的词（编辑点所在 token）不上色，下一次编辑后才上色 → 输入时不闪。

(require rackunit
         racket/file
         "../../core/app/app.rkt"
         "../../core/session/session.rkt"
         "../../core/session/adapter.rkt"
         "../../core/session/edit.rkt"
         "../../core/session/render.rkt"
         "../../core/path.rkt"
         "../catalog.rkt"
         "../ui/document.rkt"
         "../../../core/text/document.rkt"
         "../../../core/text/base/track.rkt"
         "../../../core/text/base/line.rkt")

(define (render s)
  (call-with-values (lambda () (session-render s #f)) (lambda (s* . _) s*)))

;; 文档某行的 face 向量（未写回 → #f）。
(define (face-line s did line)
  (define face (document-face (session-document-handle s did)))
  (and face (track-ref face line)))

;; 该行是否整体有色。
(define (colored? s did line)
  (define vec (face-line s did line))
  (and (vector? vec) (for/and ([f (in-vector vec)]) (and f #t))))

(define p (make-temporary-file "wc-~a.rkt"))
(display-to-file "alpha\nbeta\n" p #:exists 'replace)
(define s0 (render (session-open-file (app-session 80 24 #:plugins enabled-plugins) (normalize p))))
(define did (session-file-did s0 (normalize p)))
(check-not-false did)

;; 开文件：所有词都有色（没有「正在输入」的词）。
(check-true (colored? s0 did 0))
(check-true (colored? s0 did 1))

;; 光标上下移动：face 完全不变（移到词上也不会变色）。
(define f0 (face-line s0 did 0))
(define f1 (face-line s0 did 1))
(define s1 (render (session-nav s0 'down #f)))
(check-equal? (face-line s1 did 0) f0)
(check-equal? (face-line s1 did 1) f1)
(define s2 (render (session-nav s1 'up #f)))
(check-equal? (face-line s2 did 0) f0)
(check-equal? (face-line s2 did 1) f1)

;; 在第 1 行输入：正在输入的词不上色，其余行照旧。
(define s3 (render (session-insert (session-nav s2 'down #f) "x")))   ; 第 1 行 "xbeta"
(check-equal? (session-view-string s3 (session-edit-vid s3)) "alpha\nxbeta\n")
(check-false (colored? s3 did 1))                       ; 输入中的词 → 无色
(check-equal? (face-line s3 did 0) f0)                  ; 第 0 行未变

;; 复现用户场景：上移到第 0 行再输入 → 之前输入完的 "xbeta" 上色；新词不上色。
(define s4 (render (session-insert (session-nav s3 'up #f) "z")))     ; 第 0 行 "zalpha"
(check-true (colored? s4 did 1))                        ; xbeta 已上色
(check-false (colored? s4 did 0))                       ; zalpha 正在输入 → 无色
(define f1* (face-line s4 did 1))

;; 光标移到第 1 行的词上：不改色（不会因为「移到词上」而变色）。
(define s5 (render (session-nav s4 'down #f)))
(check-equal? (face-line s5 did 1) f1*)

(delete-file p)
