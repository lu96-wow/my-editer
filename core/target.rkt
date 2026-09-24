#lang racket

(require "atom/width.rkt"
         "unit/screen.rkt"
         rackunit)

(provide
 ;; 绘制项 / 脏矩形
 (struct-out draw-item)
 (struct-out rect)
 ;; 层常量（列表已按层排序，后端通常不必读 layer）
 text-layer selection-layer cursor-layer
 ;; 帧（不透明值 + 尺寸）
 frame? frame-width frame-height
 ;; 三个入口：全量绘制项 / 全量补丁 / 增量补丁
 frame->draw-list frame->patch frame->patch/incremental)

;;; target.rkt —— 后端绘制接口：把内部「帧 screen」摊平成**绘制项列表 + 脏矩形**
;;;
;;; 后端只需要知道：
;;;   · 绘制项 = (layer x y width height text attr)   —— x/y 是屏幕坐标，text 是字符串，attr 是语义值
;;;   · 脏矩形 = (x y width height)
;;; 不需要知道 screen / run / cursor / region / pane 的内部结构，也不需要 width 换算。
;;;
;;; 通道**不合并**：文档文本、选区、光标各是独立的绘制项，用 layer 表达叠放次序
;;; （小 = 先画 / 在下，大 = 后画 / 在上）。选区与光标**重发被覆盖的文本**，
;;; 所以后端永远只做一件事：在 (x,y) 画一段带属性的文本。
;;;
;;; 帧（screen）本身仍是内部可组合/可 diff 的值（window->screen / screen-compose 照常）；
;;; 本模块只是它的**后端视图**。

;;; ---------- 绘制项 / 脏矩形 ----------

(struct draw-item (layer x y width height text attr) #:transparent)
;; layer  : integer   叠放次序（小在下）
;; x/y    : integer   屏幕坐标（显示列 / 行，0-based）
;; width  : integer   显示宽（列）
;; height : integer   显示高（行，当前恒为 1）
;; text   : string    要画的文本（非空）
;; attr   : any/c     语义属性（core 不解释；后端映射成样式）

(struct rect (x y width height) #:transparent)

(define text-layer 0)       ; 文档文本 + 行号栏 + 边框
(define selection-layer 10) ; 选中区
(define cursor-layer 20)    ; 光标

;; 帧 = 内部 screen（对外只透出「不透明值 + 尺寸」）。
(define frame? screen?)
(define frame-width screen-width)
(define frame-height screen-height)

;;; ---------- 文本切列（宽字符安全） ----------

;; 某显示列上的字符（跳过 0 宽字符）。无 → #f。
(define (char-at-col text col)
  (define n (string-length text))
  (let loop ([i 0] [c 0])
    (cond
      [(>= i n) #f]
      [else
       (define w (char-display-width (string-ref text i)))
       (cond
         [(zero? w) (loop (add1 i) c)]
         [(and (<= c col) (< col (+ c w))) (string-ref text i)]
         [else (loop (add1 i) (+ c w))])])))

;; 屏幕（合成后）某行某显示列上的字符（跨 run 查找）。无 → #f。
(define (screen-char-at s row col)
  (for/or ([r (in-list (screen-row s row))])
    (define rcol (run-col r))
    (define rw (string-display-width (run-text r)))
    (and (<= rcol col) (< col (+ rcol rw))
         (char-at-col (run-text r) (- col rcol)))))

;; 把文本的显示列区间裁到 [0,width)；返回 (list x text') 或 #f。
(define (clip-text text x0 width)
  (define w (string-display-width text))
  (define lo (max 0 x0))
  (define hi (min width (+ x0 w)))
  (and (< lo hi)
       (list lo
             (substring text
                        (column->index text (- lo x0))
                        (column->index text (- hi x0))))))

;; 第 row 行显示列 [start,end) 的文本：run 间空隙补空格、末尾不足补空格。
;; 用于选区 / 光标把「被覆盖的文字」重发出来。**严格**只产出 [start,end) 那么多列，
;; 不会把 end 之后的 run（如右窗格）也补进来。
(define (row-span-text s row start end)
  (define out (open-output-string))
  (define col*
    (let loop ([runs (screen-row s row)] [col start])
      (cond
        [(or (null? runs) (>= col end)) col]
        [else
         (define r (car runs))
         (define rcol (run-col r))
         (cond
           [(>= rcol end) col]                       ; runs 按列升序，后面都在右界外 → 停
           [else
            (define rw (string-display-width (run-text r)))
            (define rlo (max start rcol))
            (define rhi (min end (+ rcol rw)))
            (if (>= col rhi)                          ; 本段已在当前输出位置左侧
                (loop (cdr runs) col)
                (let ([c0 (max col rlo)])
                  (when (< col c0) (display (make-string (- c0 col) #\space) out))
                  (display (substring (run-text r)
                                      (column->index (run-text r) (- c0 rcol))
                                      (column->index (run-text r) (- rhi rcol)))
                           out)
                  (loop (cdr runs) rhi)))])])))
  (when (< col* end) (display (make-string (- end col*) #\space) out))
  (get-output-string out))

;;; ---------- 帧 → 绘制项列表 ----------

;; 单行的绘制项：文本 runs + 落在该行的选区 / 光标；按 (layer, x) 排序。
(define (row->draw-items s row)
  (define w (screen-width s))
  (define texts
    (for/list ([r (in-list (screen-row s row))]
               #:do [(define cl (clip-text (run-text r) (run-col r) w))]
               #:when cl)
      (draw-item text-layer (car cl) row (string-display-width (cadr cl)) 1 (cadr cl) (run-face r))))
  (define sels
    (filter values
            (for/list ([g (in-list (screen-selections s))] #:when (= row (region-row g)))
              (define x0 (max 0 (region-start-col g)))
              (define x1 (min w (region-end-col g)))
              (and (< x0 x1)
                   (draw-item selection-layer x0 row (- x1 x0) 1
                              (row-span-text s row x0 x1) (region-face g))))))
  (define curs
    (for/list ([c (in-list (screen-cursors s))] #:when (= row (cursor-row c))
               #:when (and (>= (cursor-col c) 0) (< (cursor-col c) w)))
      ;; 光标要覆盖**整个字符**：宽字符占 2 列，不能只取 1 列（否则切半取不到 → 不可见）。
      ;; 同时把 主光标? 带进属性（多光标时后端可区分主/次）。
      (define ch (screen-char-at s row (cursor-col c)))
      (define cw (if ch (max 1 (char-display-width ch)) 1))
      (draw-item cursor-layer (cursor-col c) row cw 1
                 (row-span-text s row (cursor-col c) (+ (cursor-col c) cw))
                 (let ([f (cursor-face c)])
                   (if (hash? f) (hash-set f 'primary? (cursor-primary? c)) f)))))
  (sort (append texts sels curs)
        (lambda (a b)
          (define la (draw-item-layer a)) (define lb (draw-item-layer b))
          (cond [(< la lb) #t] [(> la lb) #f]
                [else (< (draw-item-x a) (draw-item-x b))]))))

(define (frame->draw-list s)
  (append* (for/list ([row (in-range (screen-height s))]) (row->draw-items s row))))

;;; ---------- 帧 × 帧 → 脏矩形 + 修补绘制项 ----------

;; 把某一行的绘制项涂成「按显示列」的 cell 向量：每格 = (char . attr) 或 #f。
(define (row-cells items width)
  (define cells (make-vector width #f))
  (for ([it (in-list items)])
    (define x (draw-item-x it))
    (define t (draw-item-text it))
    (for ([c (in-range (draw-item-width it))])
      (define col (+ x c))
      (when (and (>= col 0) (< col width))
        (define ch (char-at-col t c))
        (vector-set! cells col
                     (cons (if ch ch #\space) (draw-item-attr it))))))
  cells)

;; 相邻的变化列 → 矩形。
(define (columns->rects row cols)
  (if (null? cols)
      '()
      (let loop ([cs (cdr cols)] [start (car cols)] [prev (car cols)] [acc '()])
        (cond
          [(null? cs) (reverse (cons (rect start row (- (add1 prev) start) 1) acc))]
          [(= (car cs) (add1 prev)) (loop (cdr cs) start (car cs) acc)]
          [else (loop (cdr cs) (car cs) (car cs)
                      (cons (rect start row (- (add1 prev) start) 1) acc))]))))

;; 把绘制项裁到显示列 [lo,hi)：文本按列切、x/宽调整；不相交 → #f。
;; **关键**：修补项必须裁到脏列区间，否则整条 run 重绘会覆盖区间外
;; 未变化的光标/选区格子（多选区增量渲染的错误来源）。
(define (clip-draw-item it lo hi)
  (define x (draw-item-x it))
  (define lo* (max x lo))
  (define hi* (min (+ x (draw-item-width it)) hi))
  (and (< lo* hi*)
       (let* ([t (draw-item-text it)]
              [t* (substring t (column->index t (- lo* x)) (column->index t (- hi* x)))])
         (draw-item (draw-item-layer it) lo* (draw-item-y it)
                    (string-display-width t*) (draw-item-height it) t* (draw-item-attr it)))))

;; 两帧 → (values 脏矩形集 修补绘制项)：等价于对**所有行**调用增量版。
;; 需要整屏 / 不用增量信息时用它。
(define (frame->patch old new)
  (frame->patch/incremental old new (for/list ([r (in-range (screen-height new))]) r)))

;; 只在 dirty-rows 上算增量：逐行按列 diff（含 attr），
;; 脏矩形 = 变化列区间；修补项 = 该行新绘制项**裁到变化列区间**（保证区间外不动）。
;; 帧尺寸变了 → (values #f 全量绘制项)。
(define (frame->patch/incremental old new dirty-rows)
  (cond
    [(or (not (= (screen-height old) (screen-height new)))
         (not (= (screen-width old) (screen-width new))))
     (values #f (frame->draw-list new))]
    [else
     (define w (screen-width new))
     (define h (screen-height new))
     ;; 逐行算：无变化 → 空；有变化 → 本行脏矩形 + 本行修补项。
     (define rows
       (for/list ([row (in-list (sort (remove-duplicates (filter exact-nonnegative-integer? dirty-rows)) <))]
                  #:when (< row h))
         (define oi (row->draw-items old row))
         (define ni (row->draw-items new row))
         (cond
           [(equal? oi ni) (cons '() '())]
           [else
            (define a (row-cells oi w))
            (define b (row-cells ni w))
            (define cols (for/list ([c (in-range w)]
                                    #:when (not (equal? (vector-ref a c) (vector-ref b c))))
                           c))
            (cond
              [(null? cols) (cons '() '())]
              [else
               (define x0 (car cols))
               (define x1 (add1 (last cols)))
               (cons (columns->rects row cols)
                     (filter values
                             (for/list ([it (in-list ni)])
                               (clip-draw-item it x0 x1))))])])))
     (values (append* (map car rows)) (append* (map cdr rows)))]))

;;; ---------- 测试 ----------

(module+ test
  (require "viewport/project.rkt" "viewport/window.rkt" "doc/document.rkt" "atom/point.rkt")

  ;; 一个 2×5 帧：row0 = "ab"(face f)，primary 光标在 (0,1)
  (define s0 (screen 2 5 (vector (list (run 0 "ab" 'f)) '()) '() '()))
  (define s1 (screen 2 5 (vector (list (run 0 "ab" 'f)) '())
                    (list (cursor 0 1 (hash 'face 'cursor) #t)) '()))

  ;; 绘制列表：文本 + 光标（光标重发该格文字）
  (check-equal? (frame->draw-list s0)
                (list (draw-item text-layer 0 0 2 1 "ab" 'f)))
  (check-equal? (frame->draw-list s1)
                (list (draw-item text-layer 0 0 2 1 "ab" 'f)
                      (draw-item cursor-layer 1 0 1 1 "b" (hash 'face 'cursor 'primary? #t))))

  ;; 光标移动 → 列级脏矩形（不是整行）
  (define s2 (screen 2 5 (vector (list (run 0 "ab" 'f)) '())
                    (list (cursor 0 0 (hash 'face 'cursor) #t)) '()))
  (define-values (d2 p2) (frame->patch s1 s2))
  (check-equal? d2 (list (rect 0 0 2 1)))   ; 相邻变化列合并成一个矩形
  (check-true (ormap (lambda (it) (= (draw-item-layer it) cursor-layer)) p2))

  ;; 文本改一个字符 → 1 列脏矩形
  (define s3 (screen 2 5 (vector (list (run 0 "aX" 'f)) '()) '() '()))
  (define-values (d3 _p3) (frame->patch s0 s3))
  (check-equal? d3 (list (rect 1 0 1 1)))
  (check-equal? (call-with-values (lambda () (frame->patch s0 s0)) list)
                (list '() '()))

  ;; 尺寸变 → 全屏（#f）
  (define-values (d4 p4) (frame->patch s0 (screen 3 5 (vector (list (run 0 "ab" 'f)) '() '()) '() '())))
  (check-false d4)
  (define-values (d4b _p4b) (frame->patch/incremental s0 (screen 3 5 (vector (list (run 0 "ab" 'f)) '() '()) '() '()) '()))
  (check-false d4b)
  (check-equal? p4 (frame->draw-list (screen 3 5 (vector (list (run 0 "ab" 'f)) '() '()) '() '())))

  ;; 增量投影（彻底版）：只改第 1 行 → 只脏第 1 屏行
  (define dA (document-open "aaaa\nbbbb\ncccc\ndddd"))
  (define dB (document-open "aaaa\nbXbb\ncccc\ndddd"))
  (define wA (window-open dA 4 10))
  (define pA (window->projection wA))
  (define-values (pB dirty) (window->projection/incremental pA (window-open dB 4 10) '(1)))
  (check-equal? dirty '(1))
  (define-values (drects _ditems) (frame->patch/incremental (projection-screen pA) (projection-screen pB) dirty))
  (check-equal? drects (list (rect 1 1 1 1)))          ; 只列 1 变了

  ;; 改两行 → 两行脏
  (define dC (document-open "aaaa\nbXbb\ncYcc\ndddd"))
  (define-values (_pC dirty2) (window->projection/incremental pA (window-open dC 4 10) '(1 2)))
  (check-equal? dirty2 '(1 2))

  ;; layout 变（行数变）→ 退回全量，脏行 = 全部
  (define-values (_pD dirty3) (window->projection/incremental pA (window-open (document-open "aaaa") 4 10) '(0)))
  (check-equal? dirty3 '(0 1 2 3))

  ;; 回归：光标/选区重发文字必须严格限定在 [start,end)，不能把右侧 run 也补进来
  (define sgap (screen 1 30 (vector (list (run 0 "ab" 'f) (run 10 "XY" 'g))) '() '()))
  (check-equal? (map draw-item-text (frame->draw-list sgap)) '("ab" "XY"))
  (define scursor (screen 1 30 (vector (list (run 0 "ab" 'f) (run 10 "XY" 'g)))
                            (list (cursor 0 1 'c #t)) '()))
  (define cur-items (filter (lambda (it) (= (draw-item-layer it) cursor-layer)) (frame->draw-list scursor)))
  (check-equal? (map draw-item-text cur-items) '("b"))     ; 不是 "b" + 空格尾巴
  (check-equal? (map draw-item-width cur-items) '(1))
  (define ssel (screen 1 30 (vector (list (run 0 "ab" 'f) (run 10 "XY" 'g))) '()
                       (list (region 0 0 2 'sel))))
  (define sel-items (filter (lambda (it) (= (draw-item-layer it) selection-layer)) (frame->draw-list ssel)))
  (check-equal? (map draw-item-text sel-items) '("ab"))
  (check-equal? (map draw-item-width sel-items) '(2))

  ;; 回归：光标落在宽字符上必须覆盖整个字符（宽 2），否则按 1 列切半取不到 → 不可见
  (define swide (screen 1 10 (vector (list (run 0 "中a" 'f))) (list (cursor 0 0 'c #t)) '()))
  (define wc (filter (lambda (it) (= (draw-item-layer it) cursor-layer)) (frame->draw-list swide)))
  (check-equal? (map draw-item-text wc) '("中"))
  (check-equal? (map draw-item-width wc) '(2))
  ;; 光标在宽字符之后的 'a'（列 2）：1 列
  (define swide2 (screen 1 10 (vector (list (run 0 "中a" 'f))) (list (cursor 0 2 'c #t)) '()))
  (define wc2 (filter (lambda (it) (= (draw-item-layer it) cursor-layer)) (frame->draw-list swide2)))
  (check-equal? (map draw-item-text wc2) '("a"))
  (check-equal? (map draw-item-width wc2) '(1))

  (displayln "target.rkt: all tests passed"))
