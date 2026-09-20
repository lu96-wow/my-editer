#lang racket

(require "../atom/point.rkt" "../atom/edit.rkt" rackunit)

;;; unit/history.rkt —— 撤销/重放账本
;;;
;;; 归属：文本变更走 document；本模块只管账本——记不记、和谁并、几步。
;;; 所以它是**纯数据**：不碰 window/document，只认识 edit-change / edit-desc / point。
;;;
;;; 一步必须自含正反两向：
;;;   replay-descs  重放用（desc 自带 new-text，不需旧文本）
;;;   undo-descs    撤销用（逆只能由「编辑前的 buffer」导出，故在编辑时捕获）
;;; 两者合起来才闭合：撤销到底再重放能精确回到原状态。
;;;
;;; ⚠ 逆必须由**编辑前**的 buffer 导出（见 buffer-edit-desc-inverse）。
;;; 用编辑后的 buffer 求逆会静默写坏历史，且只在删除路径爆。
;;;
;;; 合并规则（结构判定，无时钟无状态）：新 desc 能否并进栈顶那一步——
;;;   打字连续段：两条都是「单字符、非换行」纯插入，且 d.start = after(pl)
;;;   退格连续段：两条都是「单字符、非换行」纯删除，且 d.end = pl.start
;;;   前向删除段：同上，且 d.start = pl.start
;;;   其余（换行、粘贴、跨行删除、替换…）一律不合并
;;; 合并时保留**较早**的 point（撤销回到整段之前）。

(provide
 (struct-out step)
 (struct-out history)
 history-empty
 history-record
 history-record-batch
 history-pop-undo
 history-pop-redo
 history-can-undo?
 history-can-redo?
 history-undo-depth
 history-redo-depth)

;;; ---------- 数据 ----------

;; 字段名自带方向与次序：两个 desc 列表存的是**相反次序**，不许用中性名。
(struct step (replay-descs undo-descs pre-point) #:transparent)
;; replay-descs : (listof edit-desc)  重放：正序依次 apply
;; undo-descs   : (listof edit-desc)  撤销：正序依次 apply（与 replay 相反次序）
;; pre-point    : point               该步开始前 active 视图的光标

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

(define (step-merge? prev d)
  (define pl (last (step-replay-descs prev)))
  (cond
    [(and (char-insert? pl) (char-insert? d))
     (point=? (edit-desc-start d) (edit-desc-after-position pl))]
    [(and (char-delete? pl) (char-delete? d))
     (or (point=? (edit-desc-end d) (edit-desc-start pl))     ; 退格：向左推进
         (point=? (edit-desc-start d) (edit-desc-start pl)))] ; 前向删除：同点继续
    [else #f]))

;;; ---------- 记录 / 取出 ----------

;; 记一步。参数是 document-edit 交回的 edit-change。
;; 与栈顶可并 → 并进去并保留**较早**的 point。任何记录都清空 redo 栈。
(define (history-record h ch)
  (define d (edit-change-desc ch))
  (define inverse (edit-change-inverse ch))
  (define p (edit-change-pre-point ch))
  (define top (and (pair? (history-undo h)) (car (history-undo h))))
  (cond
    [(and top (step-merge? top d))
     (struct-copy history h
       [undo (cons (step (append (step-replay-descs top) (list d))
                         (cons inverse (step-undo-descs top))
                         (step-pre-point top))
                   (cdr (history-undo h)))]
       [redo '()])]
    [else
     (struct-copy history h
       [undo (cons (step (list d) (list inverse) p) (history-undo h))]
       [redo '()])]))

;; 记一步「批量」：整批自含正反两向。replay-descs 正序重放；undo-descs 正序撤销
;; （= 各逆的反序）。不与栈顶合并（批量是原子的独立一步）。清空 redo。
(define (history-record-batch h replay-descs undo-descs pre-point)
  (struct-copy history h
    [undo (cons (step replay-descs undo-descs pre-point) (history-undo h))]
    [redo '()]))

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

;;; ---------- 测试（纯数据）----------

(module+ test
  (require "../doc/buffer.rkt" "../doc/batch.rkt")
  (define (ap b d) (let-values ([(b* _) (buffer-apply-edit-trusted b d)]) b*))
  (define (ap-all b ds) (for/fold ([x b]) ([d (in-list ds)]) (ap x d)))
  ;; 模拟：编辑前 buffer、edit-change、编辑后 buffer
  (define (rec h b op p)
    (define-values (b* d) (buffer-edit b p op))
    (if (not d)
        (values h b)
        (values (history-record h (edit-change d (buffer-edit-desc-inverse b d) p)) b*)))

  ;; 打字连续段并成 1 步
  (define-values (t1 b1) (rec (history-empty) (buffer-open "") (edit-insert "a") (point 0 0)))
  (define-values (t2 b2) (rec t1 b1 (edit-insert "b") (point 0 1)))
  (define-values (t3 b3) (rec t2 b2 (edit-insert "c") (point 0 2)))
  (check-equal? (buffer->string b3) "abc")
  (check-equal? (history-undo-depth t3) 1)
  (define-values (s1 t4) (history-pop-undo t3))
  (check-equal? (buffer->string (ap-all b3 (step-undo-descs s1))) "")
  (check-equal? (step-pre-point s1) (point 0 0))
  (check-equal? (history-redo-depth t4) 1)
  (define-values (s2 _u1) (history-pop-redo t4))
  (check-equal? (buffer->string (ap-all (buffer-open "") (step-replay-descs s2))) "abc")

  ;; 换行打断连续段
  (define-values (n1 nb1) (rec (history-empty) (buffer-open "") (edit-insert "a") (point 0 0)))
  (define-values (n2 nb2) (rec n1 nb1 (edit-newline) (point 0 1)))
  (define-values (n3 _u2) (rec n2 nb2 (edit-insert "b") (point 1 0)))
  (check-equal? (history-undo-depth n3) 3)

  ;; 退格连续段
  (define-values (k1 kb1) (rec (history-empty) (buffer-open "abc") (edit-backspace) (point 0 3)))
  (define-values (k2 kb2) (rec k1 kb1 (edit-backspace) (point 0 2)))
  (check-equal? (buffer->string kb2) "a")
  (check-equal? (history-undo-depth k2) 1)
  (define-values (ks1 _u3) (history-pop-undo k2))
  (check-equal? (buffer->string (ap-all kb2 (step-undo-descs ks1))) "abc")

  ;; 前向删除连续段
  (define-values (f1 fb1) (rec (history-empty) (buffer-open "abcde") (edit-delete) (point 0 2)))
  (define-values (f2 fb2) (rec f1 fb1 (edit-delete) (point 0 2)))
  (check-equal? (buffer->string fb2) "abe")
  (check-equal? (history-undo-depth f2) 1)

  ;; 粘贴（多字符）不并
  (define-values (p1 pb1) (rec (history-empty) (buffer-open "") (edit-insert "a") (point 0 0)))
  (define-values (p2 _u4) (rec p1 pb1 (edit-insert "XY") (point 0 1)))
  (check-equal? (history-undo-depth p2) 2)

  ;; 记录新编辑 → redo 清空
  (define-values (_c1 c2) (history-pop-undo t3))
  (check-equal? (history-redo-depth c2) 1)
  (define-values (c3 _u5) (rec c2 (buffer-open "") (edit-insert "z") (point 0 0)))
  (check-equal? (history-redo-depth c3) 0)

  ;; 批量记一步：整批可撤销 / 重放
  (define bb0 (buffer-open "abcd"))
  (define-values (bb* bds bis)
    (buffer-apply-edit-batch bb0 (list (edit-desc (point 0 0) (point 0 0) "X")
                                       (edit-desc (point 0 3) (point 0 3) "Y"))))
  (define bh (history-record-batch (history-empty) bds (reverse bis) (point 0 0)))
  (check-equal? (buffer->string bb*) "XabcYd")
  (check-equal? (history-undo-depth bh) 1)
  (define-values (bs _bpu) (history-pop-undo bh))
  (check-equal? (buffer->string (ap-all bb* (step-undo-descs bs))) "abcd")
  (check-equal? (buffer->string (ap-all bb0 (step-replay-descs bs))) "XabcYd")

  ;; 空栈
  (define eh (history-empty))
  (check-false (let-values ([(s _) (history-pop-undo eh)]) s))
  (check-false (let-values ([(s _) (history-pop-redo eh)]) s))
  (check-false (history-can-undo? eh))

  (displayln "history.rkt: all tests passed"))
