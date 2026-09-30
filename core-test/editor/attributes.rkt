#lang racket

;; 属性覆盖层：句柄式写回（O(1)，不碰 history）。
(require rackunit
         "../../core/editor.rkt"
         "../../core/editor/history.rkt"
         "../../core/text/document.rkt"
         "../../core/text/base/track.rkt"
         "../../core/text/base/point.rkt"
         "../../core/text/base/range.rkt")

;; 插入并取新 editor
(define (ins ed text [tag #f])
  (let-values ([(e _) (editor-view-insert ed 0 text tag)]) e))

;; 造一条与 text 对齐的高亮轨（模拟解析器输出）
(define (hl-track text l0 c0 l1 c1 face)
  (document-highlight (document-highlight-fill (document-open text) l0 c0 l1 c1 face)))
;; 造一条与 text 对齐的只读轨
(define (ro-track text l0 c0 l1 c1 flag)
  (document-readonly (document-readonly-fill (document-open text) l0 c0 l1 c1 flag)))

;;; ---------- 1. 写回当前版本：同一对象，立刻可见，不记步 ----------

(define e0 (editor-open "abc" 20 5))
(define e1 (ins e0 "X"))                                    ; "Xabc"，depth 1
(define doc1 (editor-view-document-handle e1 0))
(check-false (document-highlight doc1))
(void (editor-document-set-highlight! doc1 (hl-track "Xabc" 0 0 0 1 'kw)))
(check-equal? (editor-view-highlight-at e1 0 0 0) 'kw)
(check-equal? (editor-view-depth e1 0) 1 "属性写回不记步")

;;; ---------- 2. 写回 redo 栈里的版本：redo 回去可见 ----------

(define e2 (ins e1 "Y"))                                    ; "YXabc"，depth 2；fork 自 e1（无属性）
(define doc-e1 (editor-view-document-handle e1 0))          ; 仍指 e1 的 D1
(define e3 (editor-view-undo e2 0))                         ; current D1
(define e4 (editor-view-undo e3 0))                         ; current D0, future [D1, D2]
(void (editor-document-set-highlight! doc-e1 (hl-track "Xabc" 0 1 0 2 'hl2)))  ; 写 future 里的 D1
(check-false (document-highlight (editor-view-document e4 0))
             "当前 D0 不受写回 future 的影响")
(define e5 (editor-view-redo e4 0))                         ; current D1（同一对象）
(check-equal? (editor-view-highlight-at e5 0 0 1) 'hl2
              "redo 回到该版本看到写回的高亮")

;;; ---------- 3. undo 后编辑丢 redo → 写回静默失效 ----------

(define f0 (editor-open "abc" 20 5))
(define f1 (ins f0 "X"))                                    ; D1
(define fdoc1 (editor-view-document-handle f1 0))
(define f2 (editor-view-undo f1 0))                         ; current D0, future [D1]
(define f3 (ins f2 "Z"))                                    ; 编辑 → 清 future
(check-equal? (editor-view-string f3 0) "Zabc")
(void (editor-document-set-highlight! fdoc1 (hl-track "Xabc" 0 0 0 1 'kw)))  ; 写已丢弃的 D1
(check-false (document-highlight (editor-view-document f3 0))
             "目标已被 redo 丢弃，写回不影响当前")
(check-true (document-highlight-range? fdoc1 0 0 0 1)
            "句柄仍指旧对象，但它已不可达")

;;; ---------- 4. 写回不重建 history（无 O(深度) 操作） ----------

(define g0 (editor-open "abc" 20 5))
(define g1 (ins g0 "X"))
(define gdid (editor-view-document-id g1 0))
(define gdoc (editor-view-document-handle g1 0))
(define h-before (editor-document-history g1 gdid))
(void (editor-document-set-highlight! gdoc (hl-track "Xabc" 0 0 0 1 'kw)))
(check-eq? (editor-document-history g1 gdid) h-before "写回不重建 history")

;;; ---------- 5. 原子句柄 + 只读写回 ----------

(check-true (box? (editor-view-highlight-atom g1 0)))
(check-true (box? (editor-view-readonly-atom g1 0)))
(void (editor-document-set-readonly! gdoc (ro-track "Xabc" 0 0 0 1 #t)))
(check-true (editor-view-readonly-at? g1 0 0 0))

;;; ---------- 6. 历史移到目标版本之前 + 编辑丢 redo → 写回旧版本安全 ----------

;; 关键时序：抓句柄 → 历史移开 → 编辑清掉 redo（目标被抛弃）→ 再写回。
;; 因为文本编辑 fork 了新 box，被抛弃版本的 box 不与其他任何活文档共享，
;; 所以 set-box! 只是改一个不可达对象 → 对当前无影响。
(define p0 (editor-open "a" 20 5))
(define p1 (ins p0 "b"))                                   ; D1
(define p2 (ins p1 "c"))                                   ; D2
(define p3 (ins p2 "d"))                                   ; D3
(define pd3 (editor-view-document-handle p3 0))             ; 抓 D3 句柄
;; 撤销 3 步 → current D0, future [D1,D2,D3]
(define q0 (editor-view-undo (editor-view-undo (editor-view-undo p3 0) 0) 0))
(check-equal? (editor-view-string q0 0) "a")
;; redo 一步 → current D1, future [D2,D3]（历史移到 D3 之前）
(define q1 (editor-view-redo q0 0))
(check-equal? (editor-view-string q1 0) "ba")
;; 编辑 → history-record 整段清空 future（D2/D3 被抛弃）
(define q2 (ins q1 "Z"))
(check-equal? (history-future (editor-document-history q2 (editor-view-document-id q2 0))) '())
;; 现在写回已丢弃的 D3：不得出错、不得影响当前
(void (editor-document-set-highlight! pd3 (hl-track "dcba" 0 0 0 1 'kw)))
(check-false (document-highlight (editor-view-document q2 0))
             "写回被丢弃的版本不影响当前文档")
(check-true (document-highlight-range? pd3 0 0 0 1)
            "旧句柄仍被改，但它已不可达")

;;; ---------- 7. 同文档多视图共享同一份属性（写一个，全看到） ----------

(define m0 (editor-open "abc" 20 5))
(define-values (m1 mvid) (editor-add-view m0 0 20 5))
(check-equal? mvid 1)
(check-eq? (editor-view-document m1 0) (editor-view-document m1 1)
           "两个视图看同一份 document 对象")
(define mdoc (editor-view-document-handle m1 1))
(void (editor-document-set-highlight! mdoc (hl-track "abc" 0 0 0 1 'kw)))
(check-equal? (editor-view-highlight-at m1 0 0 0) 'kw "vid0 看到 vid1 写回的属性")
(check-equal? (editor-view-highlight-at m1 1 0 0) 'kw)
;; 作者态写 vid1：current 的 who 变 vid1，但文档共享，undo/redo 后两边都一致
(define m2 (editor-view-highlight-range m1 1 (range-of (point 0 1) (point 0 2)) 'ro))
(check-equal? (editor-view-highlight-at m2 0 0 1) 'ro)

(displayln "editor/attributes.rkt: all tests passed")
