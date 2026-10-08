#lang racket

;; 与 core/editor/query.rkt 对应的外部测试。
(require rackunit
         "../../core-rebuild/editor.rkt"
         "../../core-rebuild/text/base/point.rkt"
         "../../core-rebuild/text/base/selection.rkt")

;;; ---------- 焦点糖 shim（core 不再管焦点；本测试焦点恒 0）----------
(define (editor-string ed) (editor-view-string ed 0))
(define (editor-document-name ed) (editor-view-document-name ed 0))
(define (editor-document-id ed) (editor-view-document-id ed 0))
(define (editor-point ed) (editor-view-point ed 0))
(define (editor-point-line ed) (editor-view-point-line ed 0))
(define (editor-point-column ed) (editor-view-point-column ed 0))
(define (editor-primary ed) (editor-view-primary ed 0))
(define (editor-primary-index ed) (editor-view-primary-index ed 0))
(define (editor-selection-count ed) (editor-view-selection-count ed 0))
(define (editor-point->screen-position ed p) (editor-view-point->screen-position ed 0 p))
(define (editor-screen-position->point ed r c) (editor-view-screen-position->point ed 0 r c))
(define (editor-mode ed) (editor-view-mode ed 0))
(define (editor-set-mode ed m) (editor-view-set-mode! ed 0 m) ed)
(define (editor-line-numbers? ed) (editor-view-line-numbers? ed 0))
(define (editor-top-line ed) (editor-view-top-line ed 0))
(define (editor-top-segment ed) (editor-view-top-segment ed 0))
(define (editor-left-column ed) (editor-view-left-column ed 0))
(define (editor-width ed) (editor-view-width ed 0))
(define (editor-height ed) (editor-view-height ed 0))
(define (editor-can-undo? ed) (editor-view-can-undo? ed 0))
(define (editor-can-redo? ed) (editor-view-can-redo? ed 0))
(define (editor-depth ed) (editor-view-depth ed 0))
(define (editor-history-enabled? ed) (editor-view-history-enabled? ed 0))
(define (editor-set-history-enabled ed f) (editor-view-set-history-enabled! ed 0 f) ed)
(define (editor-face-at ed l c) (editor-view-face-at ed 0 l c))
(define (editor-readonly-at? ed l c) (editor-view-readonly-at? ed 0 l c))
(define (editor-face-row ed l) (editor-view-face-row ed 0 l))
(define (editor-readonly-row ed l) (editor-view-readonly-row ed 0 l))
(define (editor-face-range? ed l0 c0 l1 c1) (editor-view-face-range? ed 0 l0 c0 l1 c1))
(define (editor-readonly-range? ed l0 c0 l1 c1) (editor-view-readonly-range? ed 0 l0 c0 l1 c1))
(define (editor-editable? ed l0 c0 l1 c1) (editor-view-editable? ed 0 l0 c0 l1 c1))
(define (editor-face-range ed r f) (editor-document-face-range! ed 0 r f) ed)
(define (editor-readonly-range ed r f) (editor-document-readonly-range! ed 0 r f) ed)
(define (editor-insert ed text [tag #f]) (editor-view-insert! ed 0 text tag) ed)
(define (editor-undo ed) (editor-view-undo! ed 0) ed)

(define ed (editor-open "abc\ndef" 20 4 "doc"))

;; 文本
(check-equal? (editor-string ed) "abc\ndef")
(check-equal? (editor-view-string ed 0) "abc\ndef")

;; 点
(check-equal? (editor-point-line ed) 0)
(check-equal? (editor-point-column ed) 0)
(check-equal? (editor-view-point-line ed 0) 0)
(check-equal? (editor-view-point-column ed 0) 0)

;; 屏幕坐标往返
(editor-view-set-point! ed 0 (point 1 2))
(define ed2 ed)
(check-equal? (call-with-values (lambda () (editor-view-point->screen-position ed2 0 (point 1 2))) list) '(1 2))
(check-equal? (call-with-values (lambda () (editor-view-screen-position->point ed2 0 1 2)) list) '(1 2))
;; 行越界 → #f
(check-equal? (call-with-values (lambda () (editor-view-screen-position->point ed2 0 9 0)) list) '(#f #f))

;; 视口状态
(check-equal? (editor-mode ed) 'clip)
(check-equal? (editor-view-mode ed 0) 'clip)
(check-equal? (editor-mode (editor-set-mode ed 'wrap)) 'wrap)   ; set-mode 后焦点读口跟着变
(check-false (editor-view-line-numbers? ed 0))
(check-equal? (editor-view-top-line ed 0) 0)
(check-equal? (editor-view-left-column ed 0) 0)
(check-equal? (editor-view-height ed 0) 4)

;; 视口锚点：取 / 放
(define an (editor-open "abcdefghij\nsecond line here" 6 4))
(check-equal? (call-with-values (lambda () (editor-view-anchor an 0)) list) '(0 0))
(check-equal? (editor-view-anchor-point an 0) (point 0 0))
(editor-view-set-anchor! an 0 1 4)
(check-equal? (call-with-values (lambda () (editor-view-anchor an 0)) list) '(1 4))
(editor-view-set-anchor-point! an 0 (point 1 3))
(check-equal? (editor-view-anchor-point an 0) (point 1 3))
;; 同一个锚跨 mode：wrap 下落成段
(editor-view-set-mode! an 0 'wrap)
(editor-view-set-anchor-point! an 0 (point 0 7))
(check-equal? (list (editor-view-top-line an 0) (editor-view-top-segment an 0)) '(0 1))

;; 名称 / 计数 / 身份
(check-equal? (editor-document-name ed) "doc")
(check-equal? (editor-view-document-name ed 0) "doc")
(check-equal? (length (editor-document-id-list ed)) 1)
(check-equal? (length (editor-view-id-list ed)) 1)
(check-equal? (editor-view-document-id ed 0) 0)
(check-equal? (editor-document-id ed) 0)

;; 焦点读口（editor-* 与 editor-view-* 成对）
(check-equal? (editor-point ed) (editor-view-point ed 0))
(check-equal? (editor-primary ed) (editor-view-primary ed 0))
(check-equal? (editor-primary-index ed) (editor-view-primary-index ed 0))
(check-equal? (editor-selection-count ed) 1)
(check-equal? (editor-width ed) (editor-view-width ed 0))
(check-equal? (editor-height ed) (editor-view-height ed 0))
(check-equal? (editor-top-segment ed) (editor-view-top-segment ed 0))
(check-equal? (editor-line-numbers? ed) (editor-view-line-numbers? ed 0))
(check-equal? (editor-top-line ed) (editor-view-top-line ed 0))
(check-equal? (editor-left-column ed) (editor-view-left-column ed 0))
(check-equal? (call-with-values (lambda () (editor-point->screen-position ed (point 1 2))) list)
              (call-with-values (lambda () (editor-view-point->screen-position ed 0 (point 1 2))) list))
(check-equal? (call-with-values (lambda () (editor-screen-position->point ed 1 2)) list)
              (call-with-values (lambda () (editor-view-screen-position->point ed 0 1 2)) list))
(check-equal? (editor-view-can-undo? ed 0) (editor-can-undo? ed))
(check-equal? (editor-view-can-redo? ed 0) (editor-can-redo? ed))
(check-equal? (editor-view-depth ed 0) (editor-depth ed))

;; 属性读口（高亮 / 只读；写口用步骤 4 的 -range）
(define at0 (editor-open "abcd\nef" 20 5 "attr"))
(define at1 (editor-face-range at0 (range (point 0 1) (point 1 1)) 'kw))
(define at2 (editor-readonly-range at1 (range (point 0 0) (point 0 2)) #t))
(check-equal? (editor-face-at at2 0 0) #f)
(check-equal? (editor-face-at at2 0 1) 'kw)
(check-equal? (editor-face-at at2 1 0) 'kw)
(check-equal? (editor-face-at at2 1 1) #f)
(check-equal? (editor-view-face-at at2 0 0 1) 'kw)
(check-equal? (editor-face-row at2 0) (vector #f 'kw 'kw 'kw))
(check-equal? (editor-view-face-row at2 0 1) (vector 'kw #f))
(check-true (editor-face-range? at2 0 1 0 2))
(check-false (editor-face-range? at2 1 1 1 2))
(check-true (editor-readonly-at? at2 0 0))
(check-false (editor-readonly-at? at2 0 2))
(check-equal? (editor-readonly-row at2 0) (vector #t #t #f #f))
(check-true (editor-readonly-range? at2 0 0 0 1))
(check-false (editor-readonly-range? at2 0 2 0 4))
;; editable?：被只读挡 → #f；未标 → #t；零宽看插入点的格（行尾除外）
(check-false (editor-editable? at2 0 0 0 1))
(check-true (editor-editable? at2 0 2 0 4))
(check-false (editor-editable? at2 0 0 0 0))
(check-true (editor-editable? at2 0 4 0 4))
;; 无属性轨时读口给全默认
(check-equal? (editor-face-at ed 0 0) #f)
(check-equal? (editor-readonly-row ed 0) (vector #f #f #f))
(check-false (editor-face-range? ed 0 0 0 3))

;; 历史
(check-false (editor-can-undo? ed))
(check-false (editor-can-redo? ed))
(check-equal? (editor-depth ed) 0)
(define ed3 (editor-insert ed "X" 'typing))
(check-true (editor-can-undo? ed3))
(check-equal? (editor-depth ed3) 1)
(check-true (editor-can-redo? (editor-undo ed3)))

;; 历史开关读口
(check-true (editor-history-enabled? ed))
(check-equal? (editor-view-history-enabled? ed 0) (editor-history-enabled? ed))
(check-true (editor-document-history-enabled? ed 0))
(check-false (editor-history-enabled? (editor-set-history-enabled ed #f)))
(check-false (editor-document-history-enabled? ed 0))
;; did 版 can-undo/redo/depth 与 vid 版一致
(check-equal? (editor-document-can-undo? ed 0) (editor-view-can-undo? ed 0))
(check-equal? (editor-document-can-redo? ed 0) (editor-view-can-redo? ed 0))
(check-equal? (editor-document-depth ed 0) (editor-view-depth ed 0))

;; 主选区两端点
(editor-view-set-selections! ed 0 (selections-of (list (selection (point 0 0) (point 1 2))) 0))
(define pr1 ed)
(check-equal? (range-start (editor-view-primary-range pr1 0)) (point 0 0))
(check-equal? (range-end (editor-view-primary-range pr1 0)) (point 1 2))

;; ---------- 可见文档区间 editor-view-visible-range ----------
;; clip：10 行、视口高 3、top=5 → 覆盖第 5..7 行
(define vr-ed (editor-open "l0\nl1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9" 20 3 "vr"))
(editor-view-set-top-line! vr-ed 0 5)
(define vr1 (editor-view-visible-range vr-ed 0))
(check-equal? (range-start vr1) (point 5 0))
(check-equal? (range-end vr1) (point 7 2))
;; 软滚过文末：底行空白不算，只剩最后一行
(editor-view-set-top-line! vr-ed 0 9)
(define vr2 (editor-view-visible-range vr-ed 0))
(check-equal? (range-start vr2) (point 9 0))
(check-equal? (range-end vr2) (point 9 2))
;; 完全在文末之后 → 零宽
(editor-view-set-top-line! vr-ed 0 10)
(check-equal? (editor-view-visible-range vr-ed 0) (range (point 0 0) (point 0 0)))

;; wrap：宽 8 的两条长行 → 底行落在第 1 行、第 8 列
(define vw-ed (editor-open "aaaaaaaaaaaa\nbbbbbbbbbbbb" 8 3 "vw" #:mode 'wrap))
(define vw (editor-view-visible-range vw-ed 0))
(check-equal? (range-start vw) (point 0 0))
(check-equal? (range-end vw) (point 1 8))

;; 有行号栏时按正文列取（栏宽不影响区间）
(define vl-ed (editor-open "abcdefghij\nklmnopqrst" 10 2 "vl" #:line-numbers? #t))
(editor-view-set-left-column! vl-ed 0 3)
(define vl (editor-view-visible-range vl-ed 0))
(check-equal? (range-start vl) (point 0 3))
(check-equal? (range-end vl) (point 1 10))

;;; ---------- did / vid 读补齐：整轨、区间文本 ----------

;; 区间文本
(check-equal? (editor-document-range-text ed 0 (range (point 0 1) (point 1 1))) "bc\nd")
(check-equal? (editor-view-range-text ed 0 (range (point 0 0) (point 0 2))) "ab")

;; 整轨读：未设 → #f
(check-false (editor-document-face ed 0))
(check-false (editor-view-face ed 0))
(check-false (editor-document-readonly ed 0))
(check-false (editor-view-readonly ed 0))

;; 写回后 did / vid 读到同一条轨
(define rq1 (editor-face-range ed (range (point 0 0) (point 0 2)) 'kw))
(check-equal? (editor-view-face-row rq1 0) (vector 'kw 'kw #f))
(check-equal? (editor-document-face rq1 0) (editor-view-face rq1 0))
(define rq2 (editor-readonly-range rq1 (range (point 1 0) (point 1 1)) #t))
(check-equal? (editor-view-readonly-row rq2 1) (vector #t #f #f))
(check-equal? (editor-document-readonly rq2 0) (editor-view-readonly rq2 0))

(displayln "editor/query.rkt: all tests passed")
