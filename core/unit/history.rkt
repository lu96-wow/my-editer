#lang racket

(require "../atom/point.rkt" "../atom/edit.rkt" "../atom/attr.rkt" "../atom/change.rkt" rackunit)

;;; unit/history.rkt —— 撤销/重放账本
;;;
;;; 归属：文本与属性变更都走 document；本模块只管账本——记不记、和谁并、几步。
;;; 所以它是**纯数据**：不碰 window/document，只认识 change / edit-desc / point。
;;;
;;; 一步必须自含正反两向：
;;;   replay : (listof change)  重放：**正序依次施加**（每条坐标基于上一条之后）
;;;   undo   : (listof change)  撤销：正序依次施加
;;;   pre-point : point         该步开始前 active 视图的光标
;;;
;;; 一步是 change 的**序列**而非单个 change：连续打字合并成一步时，每条 desc 的坐标
;;; 都基于前一条之后，不能塞进一个批语义的 change。
;;;
;;; ⚠ 逆必须由**编辑前**的 buffer 导出（见 doc/document.rkt 的 change-result）。
;;; 用编辑后的 buffer 求逆会静默写坏历史；属性的逆还必须额外补回被文本抹掉的段。
;;;
;;; 合并规则（结构判定，无时钟无状态）：只对**纯文本、单字符**的连续段合并——
;;;   打字连续段：两条都是「单字符、非换行」纯插入，且 d.start = after(pl)
;;;   退格连续段：两条都是「单字符、非换行」纯删除，且 d.end = pl.start
;;;   前向删除段：同上，且 d.start = pl.start
;;;   其余（换行、粘贴、跨行删除、替换、任何带属性的变更…）一律不合并
;;; 合并时保留**较早**的 point（撤销回到整段之前）。

(provide
 (struct-out step)
 (struct-out history)
 history-empty
 history-record
 history-pop-undo
 history-pop-redo
 history-can-undo?
 history-can-redo?
 history-undo-depth
 history-redo-depth)

;;; ---------- 数据 ----------

;; replay : (listof change)  正序依次施加
;; undo   : (listof change)  正序依次施加（新编辑的逆在前）
(struct step (replay undo pre-point) #:transparent)

(struct history (undo redo) #:transparent)
;; undo / redo : (listof step)  栈顶在前

(define (history-empty) (history '() '()))
(define (history-can-undo? h) (pair? (history-undo h)))
(define (history-can-redo? h) (pair? (history-redo h)))
(define (history-undo-depth h) (length (history-undo h)))
(define (history-redo-depth h) (length (history-redo h)))

;;; ---------- 合并规则 ----------

(define (char-insert? d)
  (define t (edit-desc-new-text d))
  (and (point=? (edit-desc-start d) (edit-desc-end d))
       (= 1 (string-length t))
       (not (memv (string-ref t 0) '(#\newline #\return)))))

(define (char-delete? d)
  (and (= (point-line (edit-desc-start d)) (point-line (edit-desc-end d)))
       (= (point-col (edit-desc-end d)) (add1 (point-col (edit-desc-start d))))
       (string=? (edit-desc-new-text d) "")))

;; 只有「纯文本单条」才可能参与合并。
(define (single-text ch)
  (and (null? (change-attrs ch))
       (= 1 (length (change-texts ch)))
       (car (change-texts ch))))

;; 本次 replay 是单条纯文本 change；返回其 desc。
(define (single-change-text replay)
  (and (= 1 (length replay)) (single-text (car replay))))

(define (replay-merge? prev replay)
  (define pch (and (pair? (step-replay prev)) (last (step-replay prev))))
  (define pl (and pch (null? (change-attrs pch))
                  (pair? (change-texts pch))
                  (last (change-texts pch))))
  (define d (single-change-text replay))
  (and pl d
       (cond
         [(and (char-insert? pl) (char-insert? d))
          (point=? (edit-desc-start d) (edit-desc-after-position pl))]
         [(and (char-delete? pl) (char-delete? d))
          (or (point=? (edit-desc-end d) (edit-desc-start pl))     ; 退格：向左推进
              (point=? (edit-desc-start d) (edit-desc-start pl)))] ; 前向删除：同点继续
         [else #f])))

;;; ---------- 记录 / 取出 ----------

;; 记一步：replay / undo 都是 change 的序列（正序施加）。任何记录都清空 redo 栈。
(define (history-record h replay undo pre-point)
  (define top (and (pair? (history-undo h)) (car (history-undo h))))
  (cond
    [(and top (replay-merge? top replay))
     (struct-copy history h
       [undo (cons (step (append (step-replay top) replay)
                         ;; 新的逆在前，旧的在后（撤销顺序）
                         (append undo (step-undo top))
                         (step-pre-point top))
                   (cdr (history-undo h)))]
       [redo '()])]
    [else
     (struct-copy history h
       [undo (cons (step replay undo pre-point) (history-undo h))]
       [redo '()])]))

;; 取出下一步。空栈 → (values #f h)（原样，不报错）。
(define (history-pop-undo h)
  (cond
    [(null? (history-undo h)) (values #f h)]
    [else
     (define st (car (history-undo h)))
     (values st (struct-copy history h
                  [undo (cdr (history-undo h))]
                  [redo (cons st (history-redo h))]))]))

(define (history-pop-redo h)
  (cond
    [(null? (history-redo h)) (values #f h)]
    [else
     (define st (car (history-redo h)))
     (values st (struct-copy history h
                  [redo (cdr (history-redo h))]
                  [undo (cons st (history-undo h))]))]))

;;; ---------- 测试（纯数据 + doc 帮助构造逆） ----------

(module+ test
  (require "../doc/buffer.rkt" "../doc/document.rkt")

  ;; 施加一条文本 desc，并给出 (replay undo pre-point)
  (define (step-of b d p)
    (define-values (b* res) (document-apply-change-trusted b (change/edits (list d))))
    (values b* (list (change-result-replay res)) (change-result-undo res)))
  ;; 模拟一次编辑并记账
  (define (rec h b d p)
    (define-values (b* replay undo) (step-of b d p))
    (values (history-record h replay undo p) b*))
  (define (apply-undo b undo) (for/fold ([x b]) ([c (in-list undo)]) (let-values ([(x* _) (document-apply-change-trusted x c)]) x*)))
  (define (apply-replay b replay) (for/fold ([x b]) ([c (in-list replay)]) (let-values ([(x* _) (document-apply-change-trusted x c)]) x*)))

  ;; 打字连续段并成 1 步
  (define-values (t1 b1) (rec (history-empty) (document-open "") (edit-desc (point 0 0) (point 0 0) "a") (point 0 0)))
  (define-values (t2 b2) (rec t1 b1 (edit-desc (point 0 1) (point 0 1) "b") (point 0 1)))
  (define-values (t3 b3) (rec t2 b2 (edit-desc (point 0 2) (point 0 2) "c") (point 0 2)))
  (check-equal? (document->string b3) "abc")
  (check-equal? (history-undo-depth t3) 1)
  (define-values (s1 t4) (history-pop-undo t3))
  (check-equal? (document->string (apply-undo b3 (step-undo s1))) "")
  (check-equal? (step-pre-point s1) (point 0 0))
  (check-equal? (history-redo-depth t4) 1)
  (define-values (s2 _u1) (history-pop-redo t4))
  (check-equal? (document->string (apply-replay (document-open "") (step-replay s2))) "abc")

  ;; 换行打断连续段
  (define-values (n1 nb1) (rec (history-empty) (document-open "") (edit-desc (point 0 0) (point 0 0) "a") (point 0 0)))
  (define-values (n2 nb2) (rec n1 nb1 (edit-desc (point 0 1) (point 0 1) "\n") (point 0 1)))
  (define-values (n3 _u2) (rec n2 nb2 (edit-desc (point 1 0) (point 1 0) "b") (point 1 0)))
  (check-equal? (history-undo-depth n3) 3)

  ;; 退格连续段
  (define-values (k1 kb1) (rec (history-empty) (document-open "abc") (edit-desc (point 0 2) (point 0 3) "") (point 0 3)))
  (define-values (k2 kb2) (rec k1 kb1 (edit-desc (point 0 1) (point 0 2) "") (point 0 2)))
  (check-equal? (document->string kb2) "a")
  (check-equal? (history-undo-depth k2) 1)
  (define-values (ks1 _u3) (history-pop-undo k2))
  (check-equal? (document->string (apply-undo kb2 (step-undo ks1))) "abc")

  ;; 前向删除连续段
  (define-values (f1 fb1) (rec (history-empty) (document-open "abcde") (edit-desc (point 0 2) (point 0 3) "") (point 0 2)))
  (define-values (f2 fb2) (rec f1 fb1 (edit-desc (point 0 2) (point 0 3) "") (point 0 2)))
  (check-equal? (document->string fb2) "abe")
  (check-equal? (history-undo-depth f2) 1)

  ;; 粘贴（多字符）不并
  (define-values (p1 pb1) (rec (history-empty) (document-open "") (edit-desc (point 0 0) (point 0 0) "a") (point 0 0)))
  (define-values (p2 _u4) (rec p1 pb1 (edit-desc (point 0 1) (point 0 1) "XY") (point 0 1)))
  (check-equal? (history-undo-depth p2) 2)

  ;; 记录新编辑 → redo 清空
  (define-values (_c1 c2) (history-pop-undo t3))
  (check-equal? (history-redo-depth c2) 1)
  (define-values (c3 _u5) (rec c2 (document-open "") (edit-desc (point 0 0) (point 0 0) "z") (point 0 0)))
  (check-equal? (history-redo-depth c3) 0)

  ;; 文本 + 属性一步：可撤销
  (define ab0 (document-open "abcd"))
  (define-values (ab1 res)
    (document-apply-change-trusted ab0
      (change (list (edit-desc (point 0 1) (point 0 1) "X"))
              (list (attr-set (point 0 1) (point 0 2) read-only-key #t)))))
  (define ah (history-record (history-empty) (list (change-result-replay res)) (change-result-undo res) (point 0 1)))
  (check-equal? (document->string ab1) "aXbcd")
  (check-equal? (history-undo-depth ah) 1)
  (define-values (as _bpu) (history-pop-undo ah))
  (check-equal? (document->string (apply-undo ab1 (step-undo as))) "abcd")
  (check-false (attr-read-only? (document-attr-at (apply-undo ab1 (step-undo as)) (point 0 1))))

  ;; 空栈
  (define eh (history-empty))
  (check-false (let-values ([(s _) (history-pop-undo eh)]) s))
  (check-false (let-values ([(s _) (history-pop-redo eh)]) s))
  (check-false (history-can-undo? eh))

  (displayln "history.rkt: all tests passed"))
