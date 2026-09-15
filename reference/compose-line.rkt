#lang racket

(require racket/list
         "../core/view/screen.rkt" "../core/view/width.rkt"
         "../framework/slots.rkt" rackunit)

;;; compose-line.rkt —— 组合/装饰插件（参考实现）
;;;
;;; plain-compose : 无边框（= screen-compose 原语包装）
;;; line-compose  : 在窗口之间的分隔槽（GUTTER）画 | / - 边框，交叠处画 +
;;;
;;; 关键：分隔符按「段」绘制（带跨度），而非整列/整行——
;;;   竖线只画在两窗口纵向重叠的行内，横线只画在两窗口横向重叠的列内；
;;;   遇到垂直/水平分隔槽交叉处，向交叉方向各扩展一格，形成 +。

(provide plain-compose line-compose)

(define border-face (hash 'face 'border))

;; piece = (list window-id x y w h screen)
(define (p-id p) (list-ref p 0))
(define (p-x  p) (list-ref p 1))
(define (p-y  p) (list-ref p 2))
(define (p-w  p) (list-ref p 3))
(define (p-h  p) (list-ref p 4))
(define (p-s  p) (list-ref p 5))

(define (plain-compose-fn rows cols pieces active)
  ;; screen-compose 原语期望 (id x y screen)，这里剥掉 w h
  (screen-compose rows cols
                  (for/list ([p (in-list pieces)])
                    (list (p-id p) (p-x p) (p-y p) (p-s p)))
                  active))

;;; ---------- 分隔段 ----------

;; 垂直分隔段 (x y0 y1)：列 x，从行 y0 到 y1（半开），由左右相邻窗口的纵向重叠决定
(define (v-segments pieces)
  (apply append
         (for*/list ([a (in-list pieces)] [b (in-list pieces)]
                     #:when (v-adjacent? a b pieces))
           (define y0 (max (p-y a) (p-y b)))
           (define y1 (min (+ (p-y a) (p-h a)) (+ (p-y b) (p-h b))))
           (for/list ([x (in-range (+ (p-x a) (p-w a)) (p-x b))])
             (list x y0 y1)))))

;; 水平分隔段 (y x0 x1)：行 y，从列 x0 到 x1（半开）
(define (h-segments pieces)
  (apply append
         (for*/list ([a (in-list pieces)] [b (in-list pieces)]
                     #:when (h-adjacent? a b pieces))
           (define x0 (max (p-x a) (p-x b)))
           (define x1 (min (+ (p-x a) (p-w a)) (+ (p-x b) (p-w b))))
           (for/list ([y (in-range (+ (p-y a) (p-h a)) (p-y b))])
             (list y x0 x1)))))

;; a 在 b 左边（或上边），且中间空隙内没有其它（纵向/横向重叠的）窗口 → 才是直接相邻
(define (v-adjacent? a b pieces)
  (and (not (= (p-id a) (p-id b)))
       (< (+ (p-x a) (p-w a)) (p-x b))
       (y-overlap? a b)
       (no-window-in-x-gap? a b pieces)))

(define (h-adjacent? a b pieces)
  (and (not (= (p-id a) (p-id b)))
       (< (+ (p-y a) (p-h a)) (p-y b))
       (x-overlap? a b)
       (no-window-in-y-gap? a b pieces)))

(define (no-window-in-x-gap? a b pieces)
  (define lo (+ (p-x a) (p-w a)))
  (define hi (p-x b))
  (for/and ([c (in-list pieces)]
            #:unless (memq (p-id c) (list (p-id a) (p-id b))))
    (not (and (y-overlap? a c)
              (< (p-x c) hi)
              (> (+ (p-x c) (p-w c)) lo)))))

(define (no-window-in-y-gap? a b pieces)
  (define lo (+ (p-y a) (p-h a)))
  (define hi (p-y b))
  (for/and ([c (in-list pieces)]
            #:unless (memq (p-id c) (list (p-id a) (p-id b))))
    (not (and (x-overlap? a c)
              (< (p-y c) hi)
              (> (+ (p-y c) (p-h c)) lo)))))

(define (y-overlap? a b)
  (and (< (p-y a) (+ (p-y b) (p-h b)))
       (< (p-y b) (+ (p-y a) (p-h a)))))

(define (x-overlap? a b)
  (and (< (p-x a) (+ (p-x b) (p-w b)))
       (< (p-x b) (+ (p-x a) (p-w a)))))

;; 分隔槽列/行集合（用于把分隔段扩展到交叉处，形成 +）
(define (gutter-col-set pieces)
  (remove-duplicates (map car (v-segments pieces)) =))

(define (gutter-row-set pieces)
  (remove-duplicates (map car (h-segments pieces)) =))

;; 横线向左右各扩展一格到相邻竖槽，形成连续横线 + 交叉点
(define (extend-h pieces)
  (define gcols (gutter-col-set pieces))
  (for/list ([seg (in-list (h-segments pieces))])
    (match-define (list y x0 x1) seg)
    (list y
          (if (memv (sub1 x0) gcols) (sub1 x0) x0)
          (if (memv x1 gcols) (add1 x1) x1))))

;; 竖线向上下各扩展一格到相邻横槽，形成交叉点
(define (extend-v pieces)
  (define grows (gutter-row-set pieces))
  (for/list ([seg (in-list (v-segments pieces))])
    (match-define (list x y0 y1) seg)
    (list x
          (if (memv (sub1 y0) grows) (sub1 y0) y0)
          (if (memv y1 grows) (add1 y1) y1))))

;;; ---------- runs ↔ cell 网格 ----------

;; runs → cell 网格：每个 cell = 1 显示列；(char . face)，宽字符第 2 列标记 'cont
(define (runs->cells runs cols)
  (define v (make-vector cols #f))
  (for ([rn (in-list runs)])
    (define acc (run-col rn))
    (for ([ch (in-string (run-text rn))])
      (define w (char-display-width ch))
      (when (< acc cols) (vector-set! v acc (cons ch (run-face rn))))
      (for ([k (in-range 1 w)])
        (when (< (+ acc k) cols)
          (vector-set! v (+ acc k) (cons 'cont (run-face rn)))))
      (set! acc (+ acc w))))
  v)

;; cell 网格 → runs
(define (cells->runs v)
  (let loop ([gx 0] [cur #f] [out '()])
    (cond
      [(>= gx (vector-length v))
       (reverse (if cur (cons cur out) out))]
      [else
       (define cell (vector-ref v gx))
       (cond
         [(not cell) (loop (add1 gx) #f (if cur (cons cur out) out))]
         [(and cur (equal? (cdr cell) (run-face cur)) (not (eq? (car cell) 'cont)))
          (loop (add1 gx)
                (struct-copy run cur [text (string-append (run-text cur) (string (car cell)))])
                out)]
         [(eq? (car cell) 'cont) (loop (add1 gx) cur out)]
         [else
          (loop (add1 gx) (run gx (string (car cell)) (cdr cell))
                (if cur (cons cur out) out))])])))

;;; ---------- line-compose ----------

(define (line-compose-fn rows cols pieces active)
  ;; 1. 贴窗口内容（cell 网格）
  (define grid (make-vector rows #f))
  (for ([p (in-list pieces)])
    (define s (p-s p))
    (for ([r (in-range (screen-rows s))])
      (define gy (+ (p-y p) r))
      (when (and (>= gy 0) (< gy rows))
        (unless (vector-ref grid gy) (vector-set! grid gy (make-vector cols #f)))
        (define rowc (vector-ref grid gy))
        (define cells (runs->cells (vector-ref (screen-row-runs s) r) (screen-cols s)))
        (for ([gx (in-range (screen-cols s))])
          (define cell (vector-ref cells gx))
          (define dst (+ (p-x p) gx))
          (when (and cell (>= dst 0) (< dst cols))
            (vector-set! rowc dst cell))))))
  ;; 2. 先画横线（含交叉扩展）
  (for ([seg (in-list (extend-h pieces))])
    (match-define (list y x0 x1) seg)
    (when (and (>= y 0) (< y rows))
      (define rowc (or (vector-ref grid y) (make-vector cols #f)))
      (vector-set! grid y rowc)
      (for ([gx (in-range (max 0 x0) (min cols x1))])
        (vector-set! rowc gx (cons #\- border-face)))))
  ;; 3. 再画竖线（若该格已是 -，则 +）
  (for ([seg (in-list (extend-v pieces))])
    (match-define (list x y0 y1) seg)
    (when (and (>= x 0) (< x cols))
      (for ([gy (in-range (max 0 y0) (min rows y1))])
        (define rowc (or (vector-ref grid gy) (make-vector cols #f)))
        (vector-set! grid gy rowc)
        (define cell (vector-ref rowc x))
        (vector-set! rowc x
          (cons (if (and cell (char=? (car cell) #\-)) #\+ #\|) border-face)))))
  ;; 4. grid → runs
  (define row-runs (for/vector ([rowc (in-vector grid)]) (cells->runs rowc)))
  ;; 5. 光标：active 块的 cursor 平移
  (define ap (for/first ([p (in-list pieces)] #:when (= (p-id p) active)) p))
  (define-values (cr cc)
    (if (and ap (>= (screen-cursor-row (p-s ap)) 0))
        (values (+ (p-y ap) (screen-cursor-row (p-s ap)))
                (+ (p-x ap) (screen-cursor-col (p-s ap))))
        (values -1 -1)))
  (screen rows cols row-runs cr cc))

(define plain-compose (compose plain-compose-fn))
(define line-compose  (compose line-compose-fn))

;;; ---------- 测试 ----------

(module+ test
  (require "../core/view/frame.rkt" "../core/text/buffer.rkt"
           "layout-tree.rkt")

  ;; 左右各 5，中间 1 列分隔槽（总宽 11）
  (define-values (f _nid) (frame-add-window (frame-open (buffer-open "hello\nworld") 2 11)))
  (define rects (list (list 0 0 0 5 2) (list 1 6 0 5 2)))
  (define pieces (frame-pieces f rects))
  (define s ((compose-compose line-compose) 2 11 pieces 1))
  (check-equal? (vector-ref (screen-row-runs s) 0)
                (list (run 0 "hello" (hash))
                      (run 5 "|" (hash 'face 'border))
                      (run 6 "hello" (hash))))
  (check-equal? (screen-cursor-col s) 6)

  ;; plain-compose：无边框，分隔槽留白
  (define sp ((compose-compose plain-compose) 2 11 pieces 1))
  (check-equal? (vector-ref (screen-row-runs sp) 0)
                (list (run 0 "hello" (hash)) (run 6 "hello" (hash))))

  ;; 嵌套（先上下后左右）：竖线不得切穿上方全宽窗口；交叉处为 +
  (define f0 (frame-open (buffer-open "aaa\naaa\naaa") 3 11))
  (define f1 ((layout-split tree-layout) f0 'vsplit))
  (define f2 (frame-set-active f1 1))
  (define f3 ((layout-split tree-layout) f2 'hsplit))
  (define nested ((compose-compose line-compose) 3 11
                  (frame-pieces f3 ((layout-rects tree-layout) f3)) 0))
  (check-equal? (vector-ref (screen-row-runs nested) 0)
                (list (run 0 "aaa" (hash))))                       ; 上方全宽窗口不被切开
  (check-equal? (vector-ref (screen-row-runs nested) 1)
                (list (run 0 "-----+-----" (hash 'face 'border)))) ; 横线 + 交叉 +
  (check-equal? (vector-ref (screen-row-runs nested) 2)
                (list (run 0 "aaa" (hash))
                      (run 5 "|" (hash 'face 'border))
                      (run 6 "aaa" (hash))))

  (displayln "compose-line.rkt: all tests passed"))
