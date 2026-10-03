#lang racket

;; 与 core/text/rebase.rkt 对应的外部测试。
(require rackunit
         "../../core-rebuild/text/rebase.rkt"
         "../../core-rebuild/text/base/edit.rkt"
         "../../core-rebuild/text/base/change.rkt"
         "../../core-rebuild/text/base/point.rkt"
         "../../core-rebuild/text/base/selection.rkt")

(define (sel a b) (selection a b))
(define (ct l c) (caret (point l c)))
;; span（输入）→ change（重基准用的变更描述）
(define (ch a b text) (span->change (span a b text)))

;; ---------- 字面重基准 ----------
;; 在 (0,1) 插入 "XX"：head (0,2) 平移到 (0,4)
(define ins (list (ch (point 0 1) (point 0 1) "XX")))
(check-equal? (selections-items (selections-rebase ins (selections-one (sel (point 0 0) (point 0 2)))))
              (list (sel (point 0 0) (point 0 4))))
;; 恰在插入点的端点字面不动
(check-equal? (selections-items (selections-rebase ins (selections-one (ct 0 1))))
              (list (ct 0 1)))
;; 落在被删区间 → 吸附起点
(define del (list (ch (point 0 0) (point 0 3) "")))
(check-equal? (selections-items (selections-rebase del (selections-one (sel (point 0 1) (point 0 2)))))
              (list (ct 0 0)))

;; ---------- 前进重基准 ----------
;; 恰在插入点 → 插入之后
(check-equal? (selections-items (selections-advance ins (selections-one (ct 0 1))))
              (list (ct 0 3)))
;; 非空选区坍缩到 head 并前进
(check-equal? (selections-items (selections-advance ins (selections-one (sel (point 0 0) (point 0 1)))))
              (list (ct 0 3)))

;; ---------- 多 change（同坐标系）：右侧插入不影响左侧光标 ----------
(define chs3 (list (ch (point 0 0) (point 0 0) "XXXXX")
                   (ch (point 0 5) (point 0 5) "Y")))
(check-equal? (selections-items (selections-advance chs3 (selections-one (ct 0 4))))
              (list (ct 0 9)))          ; 只 +5，不被右侧的 Y 多推一格
;; 多光标 + 多字符插入：各自只受「在自己左边」的插入影响
(define chs4 (list (ch (point 0 1) (point 0 1) "XX")
                   (ch (point 0 3) (point 0 3) "XX")))
(check-equal? (selections-items
               (selections-advance chs4 (selections-of (list (ct 0 1) (ct 0 3)) 0)))
              (list (ct 0 3) (ct 0 7)))

;; ---------- 规范化：多个选区映到同一点 → 去重合并 ----------
(define del-all (list (ch (point 0 0) (point 0 3) "")))
(check-equal? (selections-count
               (selections-rebase del-all (selections-of (list (ct 0 1) (ct 0 2)) 0)))
              1)
;; primary 是下标 1 的那个，合并后追到同一个 caret
(check-equal? (selections-primary
               (selections-rebase del-all (selections-of (list (ct 0 1) (ct 0 2)) 1)))
              (ct 0 0))

(displayln "rebase.rkt: all tests passed")
