#lang racket

(require "point.rkt" "buffer.rkt" "properties.rkt" rackunit)

;;; patch.rkt —— 插件输出 = 补丁（delta），而不是整块 buffer
;;;
;;; 一个 patch 对一个 key、在 [first-line, last-line] 上「清旧写新」：
;;;   应用 = 先清掉该范围该 key 的全部旧值，再写入 segs。
;;; 不同插件写不同 key → 多 patch 合并无冲突。
;;;
;;; patch 用**行号范围**（不是点）：它的语义就是「这几行我重新推导了」。
;;; 行号越界 = 过期 patch（属于旧文档）→ 报错，绝不静默夹到别的行。

(provide
 (struct-out patch)
 buffer-apply-patches
 buffer-content-eq?)

;; key        : 归属键（不同插件写不同 key）
;; first-line : 本次重推的起始行（含）
;; last-line  : 本次重推的结束行（含）
;; segs       : (listof (list line start end val))   该范围内要写入的标注
(struct patch (key first-line last-line segs) #:transparent)

;; 内容是否相同：只有 splice 才换新 content（不可变 struct），
;; 写标注不改 content。所以这是「用户改了内容」与「插件只写了标注」的精确区分。
(define (buffer-content-eq? a b) (eq? (buffer-content a) (buffer-content b)))

;; 应用一批补丁：按 key 清旧写新。只 bump tick，不置 modified?（标注不是用户编辑）。
(define (buffer-apply-patches b patches)
  (cond
    [(null? patches) b]
    [else
     (define n (buffer-line-count b))
     (for ([pt (in-list patches)])
       (define f (patch-first-line pt)) (define l (patch-last-line pt))
       (unless (and (exact-nonnegative-integer? f) (exact-nonnegative-integer? l)
                    (<= f l) (< l n))
         (error 'buffer-apply-patches
                "patch 行范围越界: [~a,~a]（buffer 有 ~a 行；过期 patch 应由消费方丢弃）"
                f l n)))
     (define props* (for/fold ([p (buffer-properties b)]) ([pt (in-list patches)])
                      (properties-replace-key p (patch-first-line pt) (patch-last-line pt)
                                              (patch-key pt) (patch-segs pt))))
     (struct-copy buffer b
       [properties props*]
       [tick (add1 (buffer-tick b))])]))

;;; ---------- 测试 ----------

(module+ test
  (define b0 (buffer-open "hello\nworld\nfoo"))

  ;; 内容版本：编辑换 content，写标注不换
  (check-true (buffer-content-eq? b0 b0))
  (check-false (buffer-content-eq? b0 (let-values ([(b _) (buffer-edit b0 (point 0 0) (edit-insert-char #\X))]) b)))
  (define b2 (buffer-apply-patches b0 (list (patch 'face 0 0 (list (list 0 0 5 'bold))))))
  (check-true (buffer-content-eq? b0 b2))
  (check-equal? (buffer-get-property b2 (point 0 2) 'face) 'bold)

  ;; 清旧写新：同 key 的旧段被清掉
  (define b3 (buffer-put-property b0 (point 1 0) (point 1 5) 'face 'bold))
  (define b4 (buffer-apply-patches b3 (list (patch 'face 1 1 (list (list 1 1 3 'red))))))
  (check-equal? (buffer-get-property b4 (point 1 0) 'face) #f)
  (check-equal? (buffer-get-property b4 (point 1 2) 'face) 'red)

  ;; 多 patch 不同 key → 并集
  (define b5 (buffer-apply-patches b0 (list (patch 'face 0 0 (list (list 0 0 5 'bold)))
                                            (patch 'diag 0 0 (list (list 0 0 5 "err"))))))
  (check-equal? (buffer-get-property b5 (point 0 1) 'face) 'bold)
  (check-equal? (buffer-get-property b5 (point 0 1) 'diag) "err")

  ;; 空补丁 → 原样
  (check-eq? (buffer-apply-patches b0 '()) b0)
  ;; 标注不置 modified?
  (check-false (buffer-modified? b5))

  ;; 过期 patch（行范围越界）→ 报错
  (check-exn exn:fail? (lambda () (buffer-apply-patches b0 (list (patch 'face 0 99 '())))))
  (check-exn exn:fail? (lambda () (buffer-apply-patches b0 (list (patch 'face 2 0 '())))))

  (displayln "patch.rkt: all tests passed"))
