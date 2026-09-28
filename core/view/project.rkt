#lang racket

(require "base/screen.rkt" "base/layout.rkt" "base/viewport.rkt"
         "../text/document.rkt" "../text/base/track.rkt" "../text/base/line.rkt" "../text/base/width.rkt")

;;; project.rkt —— 文本通道：document × vrows → 屏幕文本行（含行号装饰）
;;;
;;; 每条屏幕行的来源是一条 **vrow**（buffer 行 + 显示列区间）。本层只做：
;;;   · vrow 区间的字符 → 同 face 连续段 run（face 来自高亮轨；跨边界整字丢弃）
;;;   · 行号栏：每条 buffer 行的**首段**前加行号，正文整体右移栏宽
;;; overlay（光标 / 选区）在 overlay.rkt，二者由 render.rkt 合成。

(provide
 ;; 文本通道：vrow → runs（含行号栏）
 project-row project
 gutter-text)

;;; ---------- 一个 vrow → runs（正文坐标，不含行号栏） ----------

(define (project-row bd vr)
  (define text (document-text bd))
  (define line (vrow-line vr))
  (cond
    [(>= line (track-length text)) '()]
    [else
     (define s (track-ref text line))
     (define hlt (document-highlight bd))       ; 整轨可为 #f（全默认）
     (define hs (and hlt (track-ref hlt line)))
     (define start (vrow-start-col vr))
     (define end (vrow-end-col vr))
     (define cells '())
     (define col 0)                                  ; 当前字符的显示列
     ;; 只扫到可见窗口右端：`end` 之后（含 == end）的字全不可见，
     ;; 不必继续扫描整行 —— 长行（压缩 JSON / 日志）下这是 O(整行) 的浪费。
     (for ([i (in-range (string-length s))] #:break (>= col end))
       (define c (string-ref s i))
       (define cw (char-display-width c))
       (when (and (> cw 0) (>= col start) (<= (+ col cw) end))  ; 跨左/右边界整字丢弃
         (set! cells (cons (list (- col start) c (if hs (line-ref hs i) #f)) cells)))
       (set! col (+ col cw)))
     (cells->runs (reverse cells))]))

;; 相邻同 face 的格合成一个 run（col 连续）。
;; 逐格累加字符与显示宽，避免逐格 string-append（O(n²)）与对增长中的 run 重算宽度。
(define (cells->runs cells)
  (let loop ([cells cells] [start #f] [face #f] [width 0] [chars '()] [acc '()])
    (cond
      [(null? cells)
       (reverse (if start (cons (run start (list->string (reverse chars)) face) acc) acc))]
      [else
       (define cell (car cells))
       (define sc (car cell)) (define ch (cadr cell)) (define fc (caddr cell))
       (define cw (char-display-width ch))
       (cond
         [(and start (equal? fc face) (= (+ start width) sc))
          (loop (cdr cells) start face (+ width cw) (cons ch chars) acc)]
         [else
          (loop (cdr cells) sc fc cw (list ch)
                (if start (cons (run start (list->string (reverse chars)) face) acc) acc))])])))

;;; ---------- 行号栏 ----------

;; 一条 buffer 行的行号文本：(位数右对齐) + 1 空格分隔；line 必为合法行。
(define (gutter-text line g)
  (define w (sub1 g))                                   ; 数字占 w 列，最后一列分隔
  (define s (number->string (add1 line)))
  (string-append (make-string (max 0 (- w (string-length s))) #\space) s " "))

;; 这条屏幕行是否是它 buffer 行的第一段？wrap 续段不标行号；clip 每行只有一段。
(define (vrow-first? vp vrs r)
  (case (viewport-mode vp)
    [(clip) #t]
    [(wrap) (= 0 (vrow-start-col (vector-ref vrs r)))]
    [else #f]))

;;; ---------- 全屏文本行 ----------

;; → (values rows gutter)：rows 是 height 条屏幕行的 run 列表（含行号栏）。
(define (project bd vp vrows)
  (define t (document-text bd))
  (define g (viewport-gutter-width t vp))
  (define (row-of r)
    (define vr (vector-ref vrows r))
    (define line (vrow-line vr))
    (define body (project-row bd vr))
    (if (= g 0)
        body
        (let ([shifted (for/list ([rn (in-list body)])
                         (struct-copy run rn [col (+ g (run-col rn))]))])
          (if (and (< line (track-length t)) (vrow-first? vp vrows r))
              (cons (run 0 (gutter-text line g) 'line-number) shifted)
              shifted))))
  (values (for/vector ([r (in-range (viewport-height vp))]) (row-of r)) g))
