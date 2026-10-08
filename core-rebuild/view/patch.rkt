#lang racket

(require "base/screen.rkt" "../text/base/width.rkt")

;;; patch.rkt —— 增量更新：旧帧 → 新帧 的**纯差量**（格级 diff，覆盖输出）
;;;
;;; 逐**显示格**比较旧 / 新帧，只输出变化的格，两份：
;;;     render    →  变化的文本格（含被擦成空白的格：face = #f、text = 空格）
;;;     selection →  变化的光标 / 选区格，**携带完整外观** attr = (overlay . face)
;;;
;;; 一格的外观 = 字符 ⊕ face ⊕ overlay 三个正交分量；overlay 格同时带上 face，
;;; 否则「高亮 + 选中」这类格会丢 face。piece 自足：后端不需要回头查 screen。
;;; piece = (row col text attr)；row/col 是屏幕坐标（行 / 显示列），attr 不透明。
;;; 坐标是 row/col（先行再列）。

(provide
 ;; ---------- 类型 ----------
 (struct-out piece)

 ;; ---------- 差量 ----------
 screen-patch)

(struct piece (row column text attr) #:transparent)

;;; ---------- 对外 ----------

;; → (values render selection)
(define (screen-patch old new)
  (define h (screen-height new))
  (define fresh? (or (not old)
                     (not (= (screen-width old) (screen-width new)))
                     (not (= (screen-height old) (screen-height new)))))
  (define old* (and (not fresh?) old))
  (define-values (rends sels)
    (for/lists (rn sl) ([r (in-range h)]) (row-patch old* new r)))
  (values (append* rends) (append* sels)))

;;; ---------- 一格的状态 ----------
;;; #f = 空白；'tail = 宽字符的右半格；(list char face overlay)，overlay ∈ {#f, 'selection, 'cursor}
;;; 空白格的“新内容”用 (list #\space #f #f) 表示，于是它自然成为 render 里的空格段。

(define (row-cells s r)
  (define w (screen-width s))
  (define cells (make-vector w #f))
  (for ([rn (in-list (screen-row s r))])
    (define col (run-column rn))
    (for ([ch (in-string (run-text rn))])
      (define cw (char-display-width ch))
      (when (and (> cw 0) (>= col 0) (< col w))
        (vector-set! cells col (list ch (run-face rn) #f))
        (when (= cw 2) (when (< (add1 col) w) (vector-set! cells (add1 col) 'tail))))
      (set! col (+ col cw))))
  (for ([g (in-list (screen-regions s))] #:when (= (region-row g) r))
    (for ([c (in-range (max 0 (region-start-column g)) (min w (region-end-column g)))])
      (set-overlay! cells c 'selection)))
  (for ([cu (in-list (screen-cursors s))] #:when (= (cursor-row cu) r))
    (when (and (>= (cursor-column cu) 0) (< (cursor-column cu) w))
      (set-overlay! cells (cursor-column cu) 'cursor)))
  cells)

(define (set-overlay! cells c ov)
  (define cell (vector-ref cells c))
  (cond
    [(pair? cell) (vector-set! cells c (list (car cell) (cadr cell) ov))]
    [(eq? cell 'tail) (void)]                          ; 宽字符右半：随其字符
    [else (vector-set! cells c (list #\space #f ov))]))

;;; ---------- 一行 → (render selection) ----------

(define (row-patch old new r)
  (define w (screen-width new))
  (define nc (row-cells new r))
  (define oc (and old (row-cells old r)))
  (define rends '()) (define sels '())
  (define (emit! key start chars)
    (when (pair? chars)
      (define text (list->string (reverse chars)))
      (if (eq? (car key) 'render)
          (set! rends (cons (piece r start text (cadr key)) rends))
          (set! sels (cons (piece r start text key) sels)))))   ; key = (overlay . face)
  (let loop ([i 0] [key #f] [start 0] [end 0] [chars '()])
    (cond
      [(>= i w)
       (emit! key start chars)
       (values (reverse rends) (reverse sels))]
      [else
       (define n (vector-ref nc i))
       (define o (and oc (vector-ref oc i)))
       (cond
         [(or (equal? n o) (eq? n 'tail))            ; 未变 / 宽字符右半格
          (emit! key start chars)
          (loop (add1 i) #f 0 0 '())]
         [else
          ;; 空白格的“新内容” = 空格 + 无 face；文本格 = 其字符 + face。
          ;; overlay 格：key 带上 face → attr = (overlay . face)，外观完整。
          (define ch (if (pair? n) (car n) #\space))
          (define k (cond [(not (pair? n)) (list 'render #f)]
                          [(eq? (caddr n) 'selection) (cons 'selection (cadr n))]
                          [(eq? (caddr n) 'cursor) (cons 'cursor (cadr n))]
                          [else (list 'render (cadr n))]))
          (define cw (char-display-width ch))
          (cond
            [(and key (equal? k key) (= i end))       ; 同类且相邻 → 并进当前段
             (loop (+ i cw) key start (+ end cw) (cons ch chars))]
            [else
             (emit! key start chars)
             (loop (+ i cw) k i (+ i cw) (list ch))])])])))
