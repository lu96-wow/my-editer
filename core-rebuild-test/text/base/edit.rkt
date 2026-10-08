#lang racket

;; 由 core/text/base/edit.rkt 的测试外移而来（core/ 只留实现）。
(require rackunit
       "../../../core-rebuild/text/base/edit.rkt"
       "../../../core-rebuild/text/base/track.rkt"
       "../../../core-rebuild/text/base/line.rkt"
       "../../../core-rebuild/text/base/point.rkt"
       "../../../core-rebuild/text/base/change.rkt")

(define (tlist t) (track->list t))
(define text (track-of-list '("abc" "def" "ghi")))
(define attr (track-of-list (list (vector 'none 'none 'none)
                                  (vector 'bold 'bold 'none)
                                  (vector 'none 'none 'none))))

;; 单行插入：一个编辑，两类行都对
(define ed (edit-insert-text 1 2 "X" 'left 'none))
(check-equal? (tlist (ed text)) '("abc" "deXf" "ghi"))
(check-equal? (track-ref (ed attr) 1) (vector 'bold 'bold 'bold 'none))

;; sticky 三态
(check-equal? (track-ref ((edit-insert-text 1 2 "X" 'right 'none) attr) 1)
              (vector 'bold 'bold 'none 'none))
(check-equal? (track-ref ((edit-insert-text 1 2 "X" 'none 'plain) attr) 1)
              (vector 'bold 'bold 'plain 'none))

;; 多行粘贴：文本与属性同样的行划分
(define paste (edit-range 1 1 1 1 "P\nQ\nR" 'none 'none))
(check-equal? (tlist (paste text)) '("abc" "dP" "Q" "Ref" "ghi"))
(check-equal? (tlist (paste attr))
              (list (vector 'none 'none 'none)
                    (vector 'bold 'none)
                    (vector 'none)
                    (vector 'none 'bold 'none)
                    (vector 'none 'none 'none)))

;; 跨行删除
(check-equal? (tlist ((edit-delete-range 0 1 2 1) text)) '("ahi"))
(check-equal? (track-length ((edit-delete-range 0 1 2 1) attr)) 1)

;; 属性赋值（不改行结构）
(check-equal? (track-ref ((edit-fill 0 0 0 3 'ro) attr) 0) (vector 'ro 'ro 'ro))

;; 行级
(check-equal? (tlist ((edit-insert-lines 1 '("NEW")) text)) '("abc" "NEW" "def" "ghi"))
(check-equal? (track-length ((edit-delete-lines 0 1) text)) 2)

;; string->lines：空串 → 一个空行；CRLF / 孤立 CR 归一为 LF
(check-equal? (string->lines "") '(""))
(check-equal? (string->lines "a\nb") '("a" "b"))
(check-equal? (string->lines "a\r\nb") '("a" "b"))
(check-equal? (string->lines "a\rb") '("a" "b"))

;; string-normalize-newlines：CRLF / 孤立 CR → LF，LF 不变
(check-equal? (string-normalize-newlines "a\r\nb") "a\nb")
(check-equal? (string-normalize-newlines "a\rb") "a\nb")
(check-equal? (string-normalize-newlines "a\nb") "a\nb")
(check-equal? (string-normalize-newlines "") "")

;; span->change + change 映射
(define (map1 a b text p) (changes-map-point (list (span->change (span a b text))) p))
(define (map1-lit a b text p) (changes-map-point-literal (list (span->change (span a b text))) p))
(check-equal? (span-after-position (span (point 0 3) (point 0 3) "XY")) (point 0 5))
(check-equal? (span-after-position (span (point 0 1) (point 0 1) "P\nQ")) (point 1 1))
(check-equal? (span-after-position (span (point 0 2) (point 0 5) "")) (point 0 2))
;; 映射：起点前不动 / 删除区间内 → 吸附起点 / 末尾后平移
(check-equal? (map1 (point 0 1) (point 2 1) "XY\nZ" (point 0 0)) (point 0 0))
(check-equal? (map1 (point 0 1) (point 2 1) "XY\nZ" (point 0 2)) (point 0 1))   ; 落在删除区间内 → 吸附起点
(check-equal? (map1 (point 0 1) (point 2 1) "XY\nZ" (point 2 3)) (point 1 3))
;; 零宽插入：恰在插点 → 到插入之后
(check-equal? (map1 (point 0 1) (point 0 1) "XY" (point 0 1)) (point 0 3))
;; 多条 change（不相交）：各自映射互不干扰
(check-equal? (changes-map-point (list (span->change (span (point 0 0) (point 0 0) "A"))
                                       (span->change (span (point 1 0) (point 1 0) "B")))
                                 (point 1 0))
              (point 1 1))

;; 右侧插入不得影响左侧光标：点 (0,4) 只受 (0,0) 处的插入影响
(check-equal? (changes-map-point (list (span->change (span (point 0 0) (point 0 0) "XXXXX"))
                                       (span->change (span (point 0 5) (point 0 5) "Y")))
                                 (point 0 4))
              (point 0 9))
;; 字面语义：恰在零宽插点 → 不动
(check-equal? (map1-lit (point 0 1) (point 0 1) "XY" (point 0 1)) (point 0 1))
(check-equal? (map1-lit (point 0 1) (point 0 1) "XY" (point 0 2)) (point 0 4))

;; span->edit：span（值）→ 编辑闭包；文本 / 属性两轨同效
(check-equal? (tlist ((span->edit (span (point 1 2) (point 1 2) "X")) text)) '("abc" "deXf" "ghi"))
(check-equal? (track-ref ((span->edit (span (point 1 2) (point 1 2) "X") 'left) attr) 1)
              (vector 'bold 'bold 'bold 'none))

(displayln "base/edit.rkt: all tests passed")
