#lang racket

;; 由 core/text/document.rkt 的测试外移而来（core/ 只留实现）。
(require rackunit
       "../../core-rebuild/text/document.rkt"
       "../../core-rebuild/text/base/track.rkt"
       "../../core-rebuild/text/base/line.rkt"
       "../../core-rebuild/text/base/edit.rkt"
       "../../core-rebuild/text/base/point.rkt"
       "../../core-rebuild/text/base/range.rkt"
       "../../core-rebuild/text/base/change.rkt")

(define bd (document-open "abc\ndef"))

(check-equal? (document->string bd) "abc\ndef")
;; 属性轨惰性：未编辑文档的两条属性轨是 #f（整轨全默认），不分配任何属性格
(check-false (document-highlight bd))
(check-false (document-readonly bd))
(check-equal? (document-highlight-row bd 0) (vector #f #f #f))   ; 行视图自动补默认
;; 文本编辑对“全默认”封闭：文本改了，属性轨仍是 #f
(define bdt (document-edit-tracks bd (edit-insert-text 0 1 "X" 'left 'none)))
(check-equal? (document->string bdt) "aXbc\ndef")
(check-false (document-highlight bdt))
(check-false (document-readonly bdt))
(check-true (document-aligned? bdt))
(check-true (document-aligned? bd))

;; 只改高亮
(define bd1 (document-highlight-fill bd 0 0 0 3 'keyword))
(check-equal? (track-ref (document-highlight bd1) 0) (vector 'keyword 'keyword 'keyword))
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
(check-equal? (document-highlight-at bd1 0 0) 'keyword)
(check-false (document-highlight-at bd1 1 0))
(check-false (document-highlight-at bd1 0 9))
(check-true (document-highlight-range? bd1 0 0 0 3))
(check-false (document-highlight-range? bd1 1 0 1 3))

;; 文本编辑：扇出到高亮 + 只读，且保持对齐
(define bd3 (document-edit-tracks bd2 (edit-insert-text 0 1 "X" 'left 'none)))
(check-equal? (document->string bd3) "aXbc\ndef")
(check-equal? (track-ref (document-highlight bd3) 0) (vector 'keyword 'keyword 'keyword 'keyword))
(check-equal? (track-ref (document-readonly bd3) 0) (vector #f #f #t #t))  ; 新格抄左邻 #f，原 #t 后移
(check-true (document-aligned? bd3))

;; 多行粘贴：三条轨行划分一致
(define bd4 (document-edit-tracks bd3 (edit-range 0 1 0 1 "P\nQ" 'none #f)))
(check-equal? (document->string bd4) "aP\nQXbc\ndef")
(check-true (document-aligned? bd4))
(check-equal? (track-length (document-highlight bd4)) 3)
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
(define-values (bd-pnoop ch-pnoop ok-pnoop) (document-paste bd 0 0 (clipboard-of-text "")))
(check-true ok-pnoop)
(check-false ch-pnoop)
(check-eq? bd-pnoop bd)

;; --- 取文本（按区间 / 按变更） ---
(define bdr (document-open "abc\ndef\nghi"))
(check-equal? (document-range-text bdr (range (point 0 1) (point 0 3))) "bc")
(check-equal? (document-range-text bdr (range (point 0 1) (point 2 1))) "bc\ndef\ng")
(check-equal? (document-range-text bdr (range (point 1 0) (point 1 0))) "")

;; --- 复制 / 粘贴 ---
(define cd0 (document-open "abc\ndef\nghi"))
(define cd1 (document-highlight-fill cd0 0 1 0 3 'kw))
(define cd2 (document-readonly-fill cd1 1 0 1 2 #t))

;; 复制 (0,1)..(0,3) = "bc"，带高亮
(define cp (document-copy cd2 0 1 0 3))
(check-equal? (clipboard-text cp) '("bc"))
(check-equal? (clipboard-highlight cp) (list (vector 'kw 'kw)))
(check-equal? (clipboard-readonly cp) (list (vector #f #f)))

;; 富粘贴到 (2,3)：高亮跟着来
(define-values (cd3 ch3 ok3) (document-paste cd2 2 3 cp))
(check-true ok3)
(check-equal? (document->string cd3) "abc\ndef\nghibc")
(check-equal? (track-ref (document-highlight cd3) 2) (vector #f #f #f 'kw 'kw))
(check-true (document-aligned? cd3))
(check-equal? (change-post-range ch3) (range (point 2 3) (point 2 5)))
(check-equal? (document-change-text cd3 ch3) "bc")

;; 跨行复制：("bc" "de")，粘到 (0,0)
(define cp2 (document-copy cd2 0 1 1 2))
(check-equal? (clipboard-text cp2) '("bc" "de"))
(check-equal? (document->string (let-values ([(bd _ch _ok) (document-paste cd2 0 0 cp2)]) bd))
              "bc\ndeabc\ndef\nghi")

;; 多行粘贴的 change：after 跨行，文本可取回
(define-values (ml ch-ml ok-ml) (document-paste (document-open "abc") 0 1 (clipboard-of-text "XY\nZ")))
(check-true ok-ml)
(check-equal? (document->string ml) "aXY\nZbc")
(check-equal? (change-post-range ch-ml) (range (point 0 1) (point 1 1)))
(check-equal? (document-change-text ml ch-ml) "XY\nZ")

;; 纯文本剪贴板（外部来源）
(define cpt (clipboard-of-text "XY\nZ"))
(check-equal? (clipboard-text cpt) '("XY" "Z"))
(check-equal? (clipboard-highlight cpt) (list (vector #f #f) (vector #f)))

;; 惰性：纯文本粘到 #f 文档 → 属性轨保持 #f；富文本粘入才 materialize
(define lz (document-open "abc"))
(define-values (lz1 _lz1ch _lz1ok) (document-paste lz 0 1 (clipboard-of-text "XY")))
(check-equal? (document->string lz1) "aXYbc")
(check-false (document-highlight lz1))
(check-false (document-readonly lz1))
(check-true (document-aligned? lz1))
(define-values (lz2 _lz2ch _lz2ok) (document-paste lz 0 1 cp))   ; cp 带高亮 + 只读
(check-equal? (document->string lz2) "abcbc")
(check-equal? (document-highlight-row lz2 0) (vector #f 'kw 'kw #f #f))
(check-equal? (document-readonly-row lz2 0) (vector #f #f #f #f #f))
(check-true (document-aligned? lz2))

;; 守：粘到只读点被拒；程序版绕过
(check-false (let-values ([(bd _ch ok) (document-paste cd2 1 0 cp)]) ok))
(check-eq? (let-values ([(bd _ch ok) (document-paste cd2 1 0 cp)]) bd) cd2)
(check-equal? (let-values ([(bd _ch ok) (document-paste-ignore-readonly cd2 1 0 cp)]) (document->string bd))
              "abc\nbcdef\nghi")

;; 只取文本的复制
(check-equal? (clipboard-text (document-copy-text cd2 0 1 1 2)) '("bc" "de"))

(displayln "document.rkt: all tests passed")
