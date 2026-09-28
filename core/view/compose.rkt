#lang racket

(require "base/screen.rkt" "../text/base/width.rkt")

;;; compose.rkt —— 多窗格合成（把若干子屏贴成一张大屏）
;;;
;;;   pane        贴在合成屏上的一块子屏（id 供 active 匹配；row/col 可负，超出按合成宽度裁掉）
;;;   composition 合成后的屏幕 + 参与合成的 pane + active id
;;;
;;; run / region 按 (x,y) 平移并**裁剪到合成宽度**；只有 active pane 的光标透出，
;;; 选区来自所有 pane。**假定 pane 不重叠**（重叠按列交错，不保证层序）。

(provide
 ;; ---------- 类型 ----------
 (struct-out pane)
 (struct-out composition)

 ;; ---------- 合成 ----------
 panes->screen panes->composition)

(struct pane (id row col screen) #:transparent)
(struct composition (width height panes active-id screen) #:transparent)

;;; ---------- 全量合成 ----------

(define (panes->screen width height panes active-id)
  (define-values (cursors regions) (compose-overlay width panes active-id))
  (screen width height
          (for/vector ([row (in-range height)]) (compose-row width panes row))
          cursors regions))

;; 合成一行：所有覆盖该行的 pane 片段平移 + 裁剪后，按列排序。
(define (compose-row width panes row)
  (sort (append*
         (for/list ([p (in-list panes)])
           (define lr (- row (pane-row p)))
           (if (and (>= lr 0) (< lr (screen-height (pane-screen p))))
               (filter values
                       (for/list ([rn (in-list (screen-row (pane-screen p) lr))])
                         (clip-run (shift-run rn (pane-col p)) width)))
               '())))
        < #:key run-col))

(define (shift-run rn x) (struct-copy run rn [col (+ x (run-col rn))]))
(define (shift-cursor c x y)
  (struct-copy cursor c [row (+ y (cursor-row c))] [col (+ x (cursor-col c))]))
(define (shift-region g x y)
  (struct-copy region g [row (+ y (region-row g))]
                      [start-col (+ x (region-start-col g))]
                      [end-col (+ x (region-end-col g))]))

;; 把 run 水平裁剪到 [0, limit)；整字丢弃（宽字符跨边界不切半）。
(define (clip-run rn limit)
  (define c0 (run-col rn))
  (define s (run-text rn))
  (define out (open-output-string))
  (define col c0)
  (define new-col #f)
  (for ([ch (in-string s)])
    (define cw (char-display-width ch))
    (when (and (> cw 0) (>= col 0) (<= (+ col cw) limit))
      (unless new-col (set! new-col col))
      (write-char ch out))
    (set! col (+ col cw)))
  (define text* (get-output-string out))
  (if (zero? (string-length text*)) #f (run new-col text* (run-face rn))))

(define (clip-region g width)
  (define c0 (max 0 (region-start-col g)))
  (define c1 (min width (region-end-col g)))
  (if (>= c0 c1) #f (struct-copy region g [start-col c0] [end-col c1])))

;; overlay：只有 active pane 的光标 + 所有 pane 的选区。
(define (compose-overlay width panes active-id)
  (define active (for/first ([p (in-list panes)] #:when (equal? (pane-id p) active-id)) p))
  (values
   (if active
       (filter values
               (for/list ([c (in-list (screen-cursors (pane-screen active)))])
                 (define c* (shift-cursor c (pane-col active) (pane-row active)))
                 (and (>= (cursor-col c*) 0) (< (cursor-col c*) width) c*)))
       '())
   (append*
    (for/list ([p (in-list panes)])
      (filter values
              (for/list ([g (in-list (screen-regions (pane-screen p)))])
                (clip-region (shift-region g (pane-col p) (pane-row p)) width)))))))

;; 全量合成 → composition（含屏幕）。永远可用（首帧 / 布局变时）。
(define (panes->composition width height panes active-id)
  (composition width height panes active-id (panes->screen width height panes active-id)))
