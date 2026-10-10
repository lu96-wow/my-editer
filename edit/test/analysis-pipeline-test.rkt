#lang racket

;;; edit/test/analysis-pipeline-test.rkt —— 分析流水线（headless）
;;;
;;;   raco test edit/test/analysis-pipeline-test.rkt
;;;
;;; 验证：每个 document 版本产出一次分析值、交给 sink；同一版本不重复；编辑后产新版本；
;;;       值不进任何文档槽。

(require rackunit
         racket/file
         "../demo.rkt"
         "../session.rkt"
         "../document/document.rkt"
         "../core/path.rkt"
         "../plugin/analysis/adapter/pipeline.rkt"
         "../plugin/analysis/tools/span.rkt")

(define p (make-temporary-file "an-~a.rkt"))
(display-to-file "#lang racket\n(define (f x) (+ x 1))\n(f 2)\n" p #:exists 'replace)

;; sink：把每次产出的 (did handle result) 收集起来（由 sink 决定怎么用）
(define got (box '()))
(define (sink s did handle result)
  (set-box! got (cons (list did handle result) (unbox got)))
  s)

(define base (analysis-pipeline-install (demo-session 80 24) sink))
(define s1 (session-open-file base (normalize p)))
(define did (session-file-did s1 (normalize p)))

(define (pump-until s n want)
  (cond [(>= (length (unbox got)) want) s]
        [(zero? n) s]
        [else (sleep 0.05) (pump-until (analysis-pipeline-step s sink) (sub1 n) want)]))

;; --- 打开后产出一次 ---
(define s2 (pump-until s1 400 1))
(check-equal? (length (unbox got)) 1)
(define e1 (car (unbox got)))
(check-equal? (car e1) did)
(check-true (eq? (cadr e1) (session-document-handle s2 did)))
(define ar (caddr e1))
(check-pred analysis-result? ar)

;; 结果内容正确：定义 f @22..23 带 definition 修饰
(define sem (expand-result-sem-tokens (analysis-result-expand ar)))
(check-not-false
 (for/first ([t (in-list sem)]
             #:when (and (equal? (sem-token-span t) (span 22 23))
                         (memq 'definition (sem-token-modifiers t))))
   #t))

;; --- 同一版本不重复产出 ---
(define s2b (analysis-pipeline-step s2 sink))
(check-equal? (length (unbox got)) 1)

;; --- 编辑 → 新版本 → 再产出一次 ---
(define vid (session-edit-vid s2b))
(define s3 (session-ed-replace! s2b vid 3 0 3 0 ";; x"))
(define s4 (pump-until s3 400 2))
(check-equal? (length (unbox got)) 2)
(define e2 (car (unbox got)))
(check-true (eq? (cadr e2) (session-document-handle s4 did)))
(check-not-equal? (cadr e2) (cadr e1))                 ; 新版本 = 新句柄

(delete-file p)
