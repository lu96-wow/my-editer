#lang racket

(require "buffer.rkt" "properties.rkt" rackunit)

;;; patch.rkt —— 插件输出 = 补丁（delta），而非整块 buffer
;;;
;;; 为什么插件要返回 patch 而不是 buffer：
;;;   · 并行/异步时，各分支各自算 delta，最后「并集合并」才与顺序无关；
;;;   · 异步结果可以延后应用（先更新 UI，算完再合并）；
;;;   · 失效判定只丢 delta，不丢文档。
;;;
;;; 一个 patch 对一个 key 在 [first-line,last-line] 上「清旧写新」：
;;;   应用 = 清掉该范围内该 key 的全部旧值，再写入 segs。
;;; 不同插件写不同 key（annotator 约定）→ 多 patch 合并无冲突。

(provide
 (struct-out patch)
 buffer-apply-patches
 buffer-content-eq?)

;; key        : 归属键（不同插件写不同 key）
;; first-line : 本次重新推导的起始行（含）
;; last-line  : 本次重新推导的结束行（含）
;; segs       : (listof (list line start end val))  该范围内要写入的标注
(struct patch (key first-line last-line segs) #:transparent)

;; 内容是否相同（async 失效判定的依据）：
;; 插件应用标注不改 content；只有 splice 编辑才换新 content（不可变 struct）。
;; 所以 (eq? content) 精确地区分「用户改了内容」与「插件只写了标注」，
;; 而现有 tick 两者都涨，不能当版本号用。
(define (buffer-content-eq? a b)
  (eq? (buffer-content a) (buffer-content b)))

;; 应用一批补丁：按 key 清旧写新。只 bump tick（触发重渲染），
;; 不置 modified?（标注不是用户编辑）。
(define (buffer-apply-patches b patches)
  (if (null? patches)
      b
      (begin
        ;; 行范围越界 = 过期 patch（它的行号属于旧文档）→ 报错，绝不静默夹到**别的行**
        ;; 去清旧写新。"过期就丢弃"仍是消费方的责任（见 ARCHITECTURE §8.5 A6）。
        (for ([pt (in-list patches)])
          (define n (buffer-line-count b))
          (define f (patch-first-line pt))
          (define l (patch-last-line pt))
          (unless (and (exact-nonnegative-integer? f) (exact-nonnegative-integer? l)
                       (<= f l) (< l n))
            (error 'buffer-apply-patches
                   "patch 行范围越界: [~a,~a]（buffer 有 ~a 行；过期 patch 应由消费方丢弃）"
                   f l n)))
        (let ([properties*
               (for/fold ([p (buffer-properties b)])
                         ([pt (in-list patches)])
                 (properties-replace-key p
                                  (patch-first-line pt) (patch-last-line pt)
                                  (patch-key pt) (patch-segs pt)))])
          (struct-copy buffer b
            [properties properties*]
            [tick (add1 (buffer-tick b))])))))

(module+ test
  (define b0 (buffer-open "hello\nworld\nfoo"))

  ;; 内容版本：同 buffer / 编辑后 / 应用补丁后
  (check-true (buffer-content-eq? b0 b0))
  (define-values (b1 _) (buffer-insert-char b0 0 0 #\X))
  (check-false (buffer-content-eq? b0 b1))
  (define b2 (buffer-apply-patches b0 (list (patch 'face 0 0 (list (list 0 0 5 'bold))))))
  (check-true (buffer-content-eq? b0 b2))          ; 写标注不改内容
  (check-equal? (buffer-get-property b2 0 2 'face) 'bold)

  ;; 清旧写新：同 key 覆盖（旧段被清掉）
  (define b3 (buffer-put-property b0 1 0 5 'face 'bold))
  (define b4 (buffer-apply-patches b3 (list (patch 'face 1 1 (list (list 1 1 3 'red))))))
  (check-equal? (buffer-get-property b4 1 0 'face) #f)   ; 旧 [0,5) 已清
  (check-equal? (buffer-get-property b4 1 2 'face) 'red)

  ;; 多 patch 不同 key → 并集合并
  (define b5 (buffer-apply-patches b0
               (list (patch 'face 0 0 (list (list 0 0 5 'bold)))
                     (patch 'diag 0 0 (list (list 0 0 5 "err"))))))
  (check-equal? (buffer-get-property b5 0 1 'face) 'bold)
  (check-equal? (buffer-get-property b5 0 1 'diag) "err")

  ;; 空补丁 → 原样返回
  (check-eq? (buffer-apply-patches b0 '()) b0)

  ;; A6 回归：过期 patch 的行范围越界 → 报错（原来静默夹到别的行去清旧写新）
  (check-exn exn:fail?
             (lambda () (buffer-apply-patches b0 (list (patch 'face 0 99 '())))))
  (check-exn exn:fail?
             (lambda () (buffer-apply-patches b0 (list (patch 'face 2 0 '())))))   ; 反向

  (displayln "patch.rkt: all tests passed"))
