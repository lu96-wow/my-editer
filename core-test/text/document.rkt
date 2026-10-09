#lang racket

;; 由 core/text/document.rkt 的测试外移而来（core/ 只留实现）。
(require rackunit
       "../../core/text/document.rkt"
       "../../core/text/base/track.rkt"
       "../../core/text/base/line.rkt"
       "../../core/text/base/edit.rkt"
       "../../core/text/base/point.rkt"
       "../../core/text/base/range.rkt"
       "../../core/text/base/change.rkt")

(define bd (document-open "abc\ndef"))

(check-equal? (document->string bd) "abc\ndef")
;; 属性轨惰性：未编辑文档的两条属性轨是 #f（整轨全默认），不分配任何属性格
(check-false (document-face bd))
(check-false (document-readonly bd))
(check-equal? (document-face-row bd 0) (vector #f #f #f))   ; 行视图自动补默认
;; 文本编辑对“全默认”封闭：文本改了，属性轨仍是 #f
(define bdt (document-edit-tracks bd (edit-insert-text 0 1 "X" 'left 'none)))
(check-equal? (document->string bdt) "aXbc\ndef")
(check-false (document-face bdt))
(check-false (document-readonly bdt))
(check-true (document-aligned? bdt))
(check-true (document-aligned? bd))

;; 只改高亮
(define bd1 (document-face-fill bd 0 0 0 3 'keyword))
(check-equal? (track-ref (document-face bd1) 0) (vector 'keyword 'keyword 'keyword))
(check-equal? (document->string bd1) "abc\ndef")            ; 文本不动
(check-equal? (document-readonly-row bd1 0) (vector #f #f #f))
(check-false (document-readonly bd1))                       ; 只读未被碰过 → 仍惰性

;; 只改只读
(define bd2 (document-readonly-fill bd1 0 1 0 3 #t))
(check-true (document-readonly-at? bd2 0 1))
(check-false (document-readonly-at? bd2 0 0))
(check-true (document-readonly-range? bd2 0 0 0 3))
(check-false (document-readonly-range? bd2 1 0 1 3))

;; 高亮读取（与只读成对）
(check-equal? (document-face-at bd1 0 0) 'keyword)
(check-false (document-face-at bd1 1 0))
(check-false (document-face-at bd1 0 9))
(check-true (document-face-range? bd1 0 0 0 3))
(check-false (document-face-range? bd1 1 0 1 3))

;; 文本编辑：扇出到高亮 + 只读，且保持对齐
(define bd3 (document-edit-tracks bd2 (edit-insert-text 0 1 "X" 'left 'none)))
(check-equal? (document->string bd3) "aXbc\ndef")
(check-equal? (track-ref (document-face bd3) 0) (vector 'keyword 'keyword 'keyword 'keyword))
(check-equal? (track-ref (document-readonly bd3) 0) (vector #f #f #t #t))  ; 新格抄左邻 #f，原 #t 后移
(check-true (document-aligned? bd3))

;; 多行粘贴：三条轨行划分一致
(define bd4 (document-edit-tracks bd3 (edit-range 0 1 0 1 "P\nQ" 'none #f)))
(check-equal? (document->string bd4) "aP\nQXbc\ndef")
(check-true (document-aligned? bd4))
(check-equal? (track-length (document-face bd4)) 3)
(check-equal? (track-length (document-readonly bd4)) 3)

;; 只读跨行查询
(check-true (document-readonly-range? bd2 0 0 0 3))
(check-false (document-readonly-range? (document-open "abc") 0 0 0 3))

;; --- 用户糖：守（先查后改） ---
;; bd2 的第 0 行只读 = (#f #t #t)；在只读格上插入 → 被拒、文档不变、change = #f
(define-values (bd2r ch-r ok-r) (document-insert bd2 0 1 "X"))
(check-false ok-r)
(check-false ch-r)
(check-eq? bd2r bd2)
;; 在可写处插入 → 通过，并给出变更描述（零宽 before → 插了 "X"）
(define-values (bd2a ch-a ok-a) (document-insert bd2 0 0 "X"))
(check-true ok-a)
(check-equal? (document->string bd2a) "Xabc\ndef")
(check-equal? (change-kind ch-a) 'insert)
(check-equal? (change-post-range ch-a) (range (point 0 0) (point 0 1)))
(check-equal? (document-change-text bd2a ch-a) "X")
(check-equal? (document-range-text bd2a (change-after ch-a)) "X")
;; 行尾插入允许
(define-values (_bd2e _ch-e ok-e) (document-insert bd2 0 3 "X"))
(check-true ok-e)
;; 删可写格 → 通过；删到只读格 → 拒
(check-true (let-values ([(bd ch ok) (document-delete bd2 0 0 0 1)])
              (and ok
                   (equal? (document->string bd) "bc\ndef")
                   (eq? (change-kind ch) 'delete)
                   (equal? (change-post-range ch) (range (point 0 0) (point 0 0)))
                   (equal? (document-change-text bd ch) ""))))
(check-false (let-values ([(bd ch ok) (document-delete bd2 0 1 0 2)]) (and ok #t)))
(check-false (let-values ([(bd ch ok) (document-delete bd2 0 0 0 3)]) ok))
;; 显式查询
(check-false (document-editable? bd2 0 1 0 1))
(check-true (document-editable? bd2 0 0 0 1))

;; --- 程序糖：-ignore-readonly 绕过守卫，签名与守版一致 ---
(check-equal? (let-values ([(bd _ch ok) (document-insert-ignore-readonly bd2 0 1 "X")])
                (list (document->string bd) ok))
              (list "aXbc\ndef" #t))
(check-equal? (let-values ([(bd _ch ok) (document-delete-ignore-readonly bd2 0 1 0 2)])
                (list (document->string bd) ok))
              (list "ac\ndef" #t))
(check-equal? (let-values ([(bd _ch ok) (document-replace-ignore-readonly bd2 0 0 0 3 "Z")])
                (list (document->string bd) ok))
              (list "Z\ndef" #t))

;; --- 空编辑 = 无变更：change = #f 且 ok? = #t（与“被只读拦”用 ok? 区分）---
(define-values (bd-noop ch-noop ok-noop) (document-insert bd 0 0 ""))
(check-true ok-noop)
(check-false ch-noop)
(check-eq? bd-noop bd)

;; --- 取文本（按区间 / 按变更） ---
(define bdr (document-open "abc\ndef\nghi"))
(check-equal? (document-range-text bdr (range (point 0 1) (point 0 3))) "bc")
(check-equal? (document-range-text bdr (range (point 0 1) (point 2 1))) "bc\ndef\ng")
(check-equal? (document-range-text bdr (range (point 1 0) (point 1 0))) "")

;; --- 复制（纯文本）/ 粘贴（纯文本插入） ---
(define cd0 (document-open "abc\ndef\nghi"))
(define cd1 (document-face-fill cd0 0 1 0 3 'kw))
(define cd2 (document-readonly-fill cd1 1 0 1 2 #t))

;; 复制就是取文本（属性不随剪贴板走）
(check-equal? (document-copy cd2 0 1 0 3) "bc")
(check-equal? (document-copy cd2 0 1 1 2) "bc\nde")

;; 粘贴 = 纯文本插入；粘入不带属性，已有高亮随编辑搬运
(define-values (cd3 ch3 ok3) (document-insert cd2 2 3 "bc"))
(check-true ok3)
(check-equal? (document->string cd3) "abc\ndef\nghibc")
(check-equal? (track-ref (document-face cd3) 2) (vector #f #f #f #f #f))  ; 粘入无高亮
(check-true (document-aligned? cd3))
(check-equal? (change-post-range ch3) (range (point 2 3) (point 2 5)))
(check-equal? (document-change-text cd3 ch3) "bc")

;; 跨行插入
(check-equal? (document->string (let-values ([(bd _ch _ok) (document-insert cd2 0 0 "bc\nde")]) bd))
              "bc\ndeabc\ndef\nghi")

;; 多行插入的 change：after 跨行，文本可取回
(define-values (ml ch-ml ok-ml) (document-insert (document-open "abc") 0 1 "XY\nZ"))
(check-true ok-ml)
(check-equal? (document->string ml) "aXY\nZbc")
(check-equal? (change-post-range ch-ml) (range (point 0 1) (point 1 1)))
(check-equal? (document-change-text ml ch-ml) "XY\nZ")

;; 惰性：纯文本插入 #f 文档 → 属性轨保持 #f
(define lz (document-open "abc"))
(define-values (lz1 _lz1ch _lz1ok) (document-insert lz 0 1 "XY"))
(check-equal? (document->string lz1) "aXYbc")
(check-false (document-face lz1))
(check-false (document-readonly lz1))
(check-true (document-aligned? lz1))

;; 已有高亮时插入：高亮随编辑搬运
(define hl0 (document-face-fill (document-open "abc") 0 1 0 3 'kw))   ; "bc" 高亮
(define-values (hl1 _hl1ch _hl1ok) (document-insert hl0 0 0 "X"))     ; "Xabc"
(check-equal? (document->string hl1) "Xabc")
(check-equal? (document-face-row hl1 0) (vector #f #f 'kw 'kw))       ; 高亮右移一格
(check-true (document-aligned? hl1))

;; 守：插到只读点被拒；程序版绕过
(check-false (let-values ([(bd _ch ok) (document-insert cd2 1 0 "bc")]) ok))
(check-eq? (let-values ([(bd _ch ok) (document-insert cd2 1 0 "bc")]) bd) cd2)
(check-equal? (let-values ([(bd _ch ok) (document-insert-ignore-readonly cd2 1 0 "bc")]) (document->string bd))
              "abc\nbcdef\nghi")

(displayln "document.rkt: all tests passed")
