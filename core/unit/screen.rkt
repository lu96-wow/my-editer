#lang racket

(require "../atom/width.rkt" rackunit)

;;; unit/screen.rkt —— 后端无关的屏幕帧
;;;
;;; 屏幕有**两条独立通道**：
;;;   1) 文档文本：row-runs（同 face 的连续文本段） —— 来自 buffer 的文本/标注
;;;   2) 视图 overlay：cursors（光标点）+ selections（选中区间） —— 来自 window 的选区
;;;
;;; 分开的理由：文本/标注是**文档**状态（存 buffer，随文本移动、可编辑）；
;;; 光标/选区是**视图**状态（存 window，临时）。drawing 上后者是叠加层，绘制方式不同。
;;;
;;; face 一律是**语义 hash**（core 不解释，更不给颜色）；前端把 face 映射成样式/颜色。
;;; 宽字符不做特殊处理：run.text 是原字符，col 是**显示列**（0-based）。

(provide
 (struct-out run)
 (struct-out cursor)
 (struct-out region)
 (struct-out screen)
 make-screen
 screen-diff-rows
 screen-compose
 screen->string)

(struct run (col text face) #:transparent)
;; col  : 显示列（0-based，已按宽字符换算）
;; text : 文本（不含换行）
;; face : 语义 face（hash）

;; 视图 overlay - 光标点
(struct cursor (row col face primary?) #:transparent)
;; row/col  : 显示坐标（0-based）
;; face     : 语义 face（hash），如 (hash 'face 'cursor)
;; primary? : 是否主光标

;; 视图 overlay - 选中区间（一段连续显示列；一个跨行选区会切成多段）
(struct region (row start-col end-col face) #:transparent)
;; row            : 显示行
;; [start-col,end-col) : 显示列区间（0-based，相对本行）
;; face           : 语义 face（hash），如 (hash 'face 'selection)

(struct screen (rows cols row-runs cursor-row cursor-col cursors selections) #:transparent)
;; row-runs   : (vectorof (listof run))   文档文本
;; cursor-row : primary 光标显示行；-1 = 不画（兼容字段）
;; cursor-col : primary 光标显示列
;; cursors    : (listof cursor)           所有光标（含 primary）
;; selections : (listof region)           所有选中区间段

(define (make-screen rows cols)
  (screen rows cols (make-vector rows '()) -1 -1 '() '()))

;; 把一帧摊平成纯文本（只含文档文本；不给光标/选区上色）。给测试/无前端驱动用。
(define (screen->string s)
  (string-join
   (for/list ([runs (in-vector (screen-row-runs s))])
     (define out (open-output-string))
     (define col 0)
     (for ([r (in-list runs)])
       (when (> (run-col r) col) (display (make-string (- (run-col r) col) #\space) out))
       (display (run-text r) out)
       (set! col (+ (run-col r) (string-display-width (run-text r)))))
     (get-output-string out))
   "\n"))

;; 两屏（同尺寸）之间发生变化的行号（增量绘制的依据；只比文档文本）。
(define (screen-diff-rows old new)
  (for/list ([row (in-range (screen-rows new))]
             #:unless (equal? (vector-ref (screen-row-runs old) row)
                              (vector-ref (screen-row-runs new) row)))
    row))

(define (shift-run rn x) (run (+ x (run-col rn)) (run-text rn) (run-face rn)))
(define (shift-cursor c x y) (cursor (+ y (cursor-row c)) (+ x (cursor-col c)) (cursor-face c) (cursor-primary? c)))
(define (shift-region rg x y) (region (+ y (region-row rg)) (+ x (region-start-col rg)) (+ x (region-end-col rg)) (region-face rg)))

;; 拼屏：把若干块 (list id x y screen) 贴到 (rows cols) 大屏。
;; 文本 + 选区按 x/y 平移自各块；**只有 active 块的光标**被透出（非活动窗格不显示光标）。
(define (screen-compose rows cols pieces active-id)
  (define row-runs (make-vector rows '()))
  (define sel-out '())
  (for ([piece (in-list pieces)])
    (match-define (list _id x y s) piece)
    (for ([r (in-range (screen-rows s))])
      (define dst (+ y r))
      (when (and (>= dst 0) (< dst rows))
        (vector-set! row-runs dst (append (vector-ref row-runs dst)
                                          (map (lambda (rn) (shift-run rn x))
                                               (vector-ref (screen-row-runs s) r))))))
    (for ([rg (in-list (screen-selections s))])
      (set! sel-out (cons (shift-region rg x y) sel-out))))
  (define sorted (for/vector ([runs (in-vector row-runs)])
                   (sort runs (lambda (a b) (< (run-col a) (run-col b))))))
  (define active (for/first ([piece (in-list pieces)] #:when (eq? (car piece) active-id)) piece))
  (define-values (cr cc)
    (cond
      [(not active) (values -1 -1)]
      [else
       (match-define (list _ x y s) active)
       (if (>= (screen-cursor-row s) 0)
           (values (+ y (screen-cursor-row s)) (+ x (screen-cursor-col s)))
           (values -1 -1))]))
  (define active-cursors
    (if active
        (let ()
          (match-define (list _ x y s) active)
          (map (lambda (c) (shift-cursor c x y)) (screen-cursors s)))
        '()))
  (screen rows cols sorted cr cc active-cursors sel-out))

;;; ---------- 测试 ----------

(module+ test
  (define s0 (make-screen 2 10))
  (check-equal? (vector-length (screen-row-runs s0)) 2)
  (check-equal? (screen-cursor-row s0) -1)
  (check-equal? (screen-cursors s0) '())
  (check-equal? (screen-selections s0) '())

  ;; 构造 / screen->string
  (define r1 (run 0 "ab" (hash 'face 'bold)))
  (define r2 (run 2 "中" (hash 'face 'keyword)))
  (define c1 (cursor 0 3 (hash 'face 'cursor) #t))
  (define g1 (region 0 0 2 (hash 'face 'selection)))
  (define s1 (screen 2 10 (vector (list r1 r2) '()) 0 3 (list c1) (list g1)))
  (check-equal? (screen->string s1) (string-append "ab中\n"))
  (check-equal? (screen-cursor-col s1) 3)
  (check-equal? (cursor-primary? (car (screen-cursors s1))) #t)
  (check-equal? (region-end-col (car (screen-selections s1))) 2)

  ;; diff
  (define s2 (screen 2 10 (vector (list r1 (run 2 "文" (hash 'face 'keyword))) '()) 0 3 '() '()))
  (check-equal? (screen-diff-rows s1 s2) '(0))
  (check-equal? (screen-diff-rows s1 s1) '())

  ;; compose：文本/选区平移；只有 active 块的光标出现
  (define sa (screen 2 4 (vector (list (run 0 "ab" (hash))) (list (run 0 "cd" (hash))))
                     1 1 (list (cursor 1 1 (hash 'face 'cursor) #t)) (list (region 0 0 2 (hash 'face 'selection)))))
  (define sb (screen 2 4 (vector (list (run 0 "XY" (hash))) (list (run 0 "ZW" (hash))))
                     0 0 (list (cursor 0 0 (hash 'face 'cursor) #t)) '()))
  (define comp (screen-compose 2 8 (list (list 'a 0 0 sa) (list 'b 4 0 sb)) 'b))
  (check-equal? (vector-ref (screen-row-runs comp) 0)
                (list (run 0 "ab" (hash)) (run 4 "XY" (hash))))
  (check-equal? (vector-ref (screen-row-runs comp) 1)
                (list (run 0 "cd" (hash)) (run 4 "ZW" (hash))))
  (check-equal? (screen-cursor-row comp) 0)
  (check-equal? (screen-cursor-col comp) 4)
  (check-equal? (map cursor-col (screen-cursors comp)) '(4))          ; 只透 active(b)
  (check-equal? (map region-row (screen-selections comp)) '(0))       ; 选区来自 a，row+0
  (check-equal? (map region-start-col (screen-selections comp)) '(0))
  ;; active 不在 pieces → 隐藏光标
  (check-equal? (screen-cursor-row (screen-compose 2 8 (list (list 'a 0 0 sa)) 'b)) -1)

  (displayln "screen.rkt: all tests passed"))
