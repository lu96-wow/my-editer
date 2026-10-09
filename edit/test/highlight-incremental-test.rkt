#lang racket

;;; edit/test/highlight-incremental-test.rkt —— face 插件协议（headless）
;;;
;;;   raco test edit/test/highlight-incremental-test.rkt
;;;
;;; 覆盖：open/change 产出「每行向量」的层；change 只回脏行；层与全量一致；
;;;       词表状态跨次累积；活动词跳过。

(require rackunit
         "../plugin/registry.rkt"
         "../plugin/builtin/syntax.rkt"
         "../plugin/builtin/words.rkt"
         "../core/face.rkt"
         "../core/line-scan.rkt"
         "../../core/text/base/track.rkt"
         "../../core/text/base/line.rkt"
         "../../core/text/base/change.rkt"
         "../../core/text/base/range.rkt"
         "../../core/text/base/point.rkt")

(define (text-track str) (track-of-list (string->lines str)))

(define (replace-change l0 c0 l1 c1 new-len)          ; 单行替换，新长度 new-len
  (change (range-of (point l0 c0) (point l1 c1))
          (range-of (point l0 c0) (point l0 (+ c0 new-len)))))

(define (insert-change line col len)
  (change (range-of (point line col) (point line col))
          (range-of (point line col) (point line (+ col len)))))

(define (ctx old new changes active prev)
  (face-ctx old new changes (dirty-lines (changes->dirty-lines changes)) "test.rkt" active prev))

(define (line-face layer i) (track-ref layer i))

;;; ---------- syntax：行局部 + 只回脏行 ----------

(define old-s (text-track "let x 1\nfoo y 2"))
(define new-s (text-track "if x 1\nfoo y 2"))
(define-values (ss0 sl0)
  ((face-plugin-open syntax-plugin) old-s "test.rkt"))
(check-not-false (vector-ref (line-face sl0 0) 0))          ; "let" 关键字
(check-false (line-face sl0 1))         ; "foo" 不是

;; 改第 0 行（let -> if）：脏行只有 0；第 1 行层与全量一致，且结构共享
(define-values (_ss1 sl1 dirty-s)
  ((face-plugin-change syntax-plugin) ss0 sl0
   (ctx old-s new-s (list (replace-change 0 0 0 3 2)) #f #f)))
(check-false (dirty-all? dirty-s))
(check-equal? (dirty-ls dirty-s) '(0))
(check-equal? (line-face sl1 1) (line-face sl0 1))     ; 未变行共享
(define-values (_s sx)
  ((face-plugin-open syntax-plugin) new-s "test.rkt"))
(check-equal? (line-face sl1 0) (line-face sx 0))      ; 脏行与全量一致
(check-not-false (vector-ref (line-face sl1 0) 0))          ; "if" 关键字

;;; ---------- words：词表累积 + 活动词跳过 ----------

(define old-w (text-track "alpha beta"))
(define-values (wt0 wl0) ((face-plugin-open word-plugin) old-w "test.rkt"))
(check-equal? (hash-ref wt0 "alpha") 0)
(check-equal? (hash-ref wt0 "beta") 1)

;; 行尾插入 " gamma"：脏行 0；gamma 补号，旧词沿用同号
(define new-w (text-track "alpha beta gamma"))
(define-values (wt1 wl1 dirty-w)
  ((face-plugin-change word-plugin) wt0 wl0
   (ctx old-w new-w (list (insert-change 0 10 6)) #f #f)))
(check-equal? (dirty-ls dirty-w) '(0))
(check-equal? (hash-ref wt1 "alpha") 0)
(check-equal? (hash-ref wt1 "beta") 1)
(check-equal? (hash-ref wt1 "gamma") 2)

;; 活动词跳过：line 0 起点 0 的 "alpha" 本次不上色
(define-values (_wt2 wl2 _d)
  ((face-plugin-change word-plugin) wt0 wl0
   (ctx old-w old-w '() (list 0 0 5) #f)))
(check-false (vector-ref (line-face wl2 0) 0))         ; alpha 被跳过
(check-not-false (vector-ref (line-face wl2 0) 6))          ; beta 照常

;; 上一次活动词所在行重扫：prev-active 命中 0 行 → dirty 含 0，且不再跳过
(define-values (_wt3 wl3 dirty-w3)
  ((face-plugin-change word-plugin) wt0 wl0
   (ctx old-w old-w '() #f (list 0 0 5))))
(check-not-false (member 0 (dirty-ls dirty-w3)))
(check-not-false (vector-ref (line-face wl3 0) 0))          ; alpha 补上色

;;; ---------- words：hash 模式（无状态、跨文本稳定） ----------

(define (hash-open text)
  (parameterize ([word-coloring-method 'hash])
    ((face-plugin-open word-plugin) (text-track text) "test.rkt")))

(define-values (hst1 hl1) (hash-open "alpha beta"))
(define-values (hst2 hl2) (hash-open "alpha beta"))
(check-false hst1)                                      ; 无状态
(check-equal? (line-face hl1 0) (line-face hl2 0))      ; 同文本稳定
(check-not-false (vector-ref (line-face hl1 0) 0))      ; alpha 有色

;; 同词跨文本同色（"alpha" 在原文本 col0，在后文本 col4）
(define-values (_ha hla) (hash-open "alpha"))
(define-values (_hb hlb) (hash-open "zzz alpha"))
(check-equal? (vector-ref (line-face hla 0) 0)
              (vector-ref (line-face hlb 0) 4))
