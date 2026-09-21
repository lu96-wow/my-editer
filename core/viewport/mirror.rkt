#lang racket

(require "../atom/point.rkt" "../atom/width.rkt"
         "../doc/buffer.rkt" "../doc/document.rkt"
         "window.rkt" "layout.rkt" rackunit)

;;; viewport/mirror.rkt —— 视口映射：把一个 window 的可见范围投到另一个 window
;;;
;;; 与 rebase 的区别：rebase 是「edit → window」（按 edit-desc 重定位，同一坐标空间）；
;;; 本层是「window → window」（两个 document 之间的视口同步），**不吃 edit-desc**。
;;;
;;; 两层，第一层与 mode 无关（统一文本逻辑坐标），第二层才分 clip/wrap：
;;;
;;;   ① mirror-point  —— 逻辑映射（line/col），不换 document、不看 mode：
;;;       行：**固定行号**，超出目标行数 → 夹到最近
;;;       列：按该行字符长**比例**
;;;   ② mirror-window —— 取源窗口左上角的逻辑点，按目标窗口的 mode 投影成视口：
;;;       clip：top-line = 行；left-col = 该列的显示列（吸附字符起点）
;;;       wrap：top-line = 行；top-seg = 该列所在的折行段
;;;       最后 window-clamp-view 夹回合法域（行不够→顶到最近）
;;;
;;; 参数一律「源在前、目标在后」：mirror-point 返回目标点，mirror-window 返回目标窗口
;;; （目标窗口的 document / 选区原样保留，只改视口）。
;;;
;;; 纯几何：只依赖 window/buffer/width，不改 document。

(provide mirror-point mirror-window)

;;; ---------- ① 逻辑映射（mode 无关） ----------

;; 把源 document 的点 p 投到目标 document（逻辑坐标）。
;; 行固定行号（不够夹到最近）；列按行字符长比例；空行/单行都夹到最近。
(define (mirror-point d-src p d-dst)
  (define n-src (document-line-count d-src))
  (define n-dst (document-line-count d-dst))
  (define l-src (max 0 (min (point-line p) (sub1 n-src))))
  (define l-dst (min l-src (sub1 n-dst)))                    ; 固定行号，越界夹最近
  (define len-src (document-line-length d-src l-src))
  (define len-dst (document-line-length d-dst l-dst))
  (define c (max 0 (min (point-col p) len-src)))
  (point l-dst (if (zero? len-src) 0 (round (* c (/ len-dst len-src))))))   ; 列按比例

;;; ---------- ② 逻辑 → 视口（mode 相关） ----------

;; 窗口可视区左上角对应的逻辑点 (line, col)（col 是字符索引）。越界行先夹到合法域。
(define (window-top-left-point w)
  (define d (window-document w))
  (define line (max 0 (min (window-top-line w) (sub1 (document-line-count d)))))
  (define text (buffer-line-ref (document-buffer d) line))
  (define col
    (case (window-mode w)
      [(clip) (window-left-col w)]
      [(wrap) (define segs (wrap-segments text (window-width w)))
              (car (list-ref segs (max 0 (min (window-top-seg w) (sub1 (length segs))))))]
      [else (error 'window-top-left-point "未知 mode: ~a" (window-mode w))]))
  (point line (column->index text col)))

;; 某显示列落在第几个折行段（不在任何段内 → 末段）。
(define (seg-of-col text width col)
  (define segs (wrap-segments text width))
  (or (for/first ([s (in-list segs)] [i (in-naturals)]
                  #:when (and (<= (car s) col) (< col (cdr s)))) i)
      (sub1 (length segs))))

;; 按目标窗口的 mode 把它定位到逻辑点 (line, col)。
(define (set-viewport w line col)
  (define w1 (window-set-top-line w line))
  (define text (buffer-line-ref (window-buffer w1) line))
  (define dc (index->column text col))
  (case (window-mode w1)
    [(clip) (window-clamp-view (window-set-left-col w1 dc))]
    [(wrap) (window-clamp-view (window-set-top-seg w1 (seg-of-col text (window-width w1) dc)))]
    [else (error 'set-viewport "未知 mode: ~a" (window-mode w1))]))

;; 把源窗口的可视范围投到目标窗口：源左上角逻辑点 → 目标逻辑点 → 目标视口。
;; **不动目标窗口的 document**（跨文档各看各的文本），也**不动它的选区**。
(define (mirror-window w-src w-dst)
  (define p (mirror-point (window-document w-src)
                          (window-top-left-point w-src)
                          (window-document w-dst)))
  (set-viewport w-dst (point-line p) (point-col p)))

;;; ---------- 测试 ----------

(module+ test
  (define (P l c) (point l c))
  (define (win s [h 3] [w 20] [top 0] [left 0])
    (window-set-left-col (window-set-top-line (window-open (document-open s) h w) top) left))

  ;; ① 同 document → 恒等（行、列都还原）
  (define d0 (document-open "hello\nworld\nfoo"))
  (check-equal? (mirror-point d0 (P 1 3) d0) (P 1 3))
  (check-equal? (mirror-point d0 (P 2 0) d0) (P 2 0))

  ;; ① 行：固定行号，目标更短 → 夹最近
  (define dA (document-open "l0\nl1\nl2\nl3\nl4"))
  (define dB (document-open "m0\nm1"))
  (check-equal? (mirror-point dA (P 0 0) dB) (P 0 0))
  (check-equal? (mirror-point dA (P 1 0) dB) (P 1 0))
  (check-equal? (mirror-point dA (P 4 0) dB) (P 1 0))    ; 4 → 最近末行 1

  ;; ① 列：按行字符长比例
  (define sA (document-open "abcd\nab\nabcdefgh"))
  (define sB (document-open "ab\nabcdefgh"))
  (check-equal? (mirror-point sA (P 0 0) sB) (P 0 0))
  (check-equal? (mirror-point sA (P 0 4) sB) (P 0 2))     ; 4/4 * 2 = 2
  (check-equal? (mirror-point sA (P 0 2) sB) (P 0 1))     ; 2/4 * 2 = 1
  (check-equal? (mirror-point sA (P 2 8) sB) (P 1 8))     ; 8/8 * 8 = 8

  ;; ① 空行 / 单行
  (check-equal? (mirror-point (document-open "abc\n") (P 1 0) (document-open "xy\nzw")) (P 1 0))   ; 源空行→列 0
  (check-equal? (mirror-point (document-open "abc") (P 0 3) (document-open "xy")) (P 0 2))
  (check-equal? (mirror-point (document-open "abc") (P 0 3) (document-open "abcdef")) (P 0 6))

  ;; ① 越界输入 → 先夹
  (check-equal? (mirror-point sA (P 99 99) sB) (P 1 8))

  ;; ② 同 document：视口恒等（top-line / left-col 保留）
  (define w-same (mirror-window (win "hello\nworld\nfoo" 2 20 1 0) (win "hello\nworld\nfoo" 2 20 1 0)))
  (check-equal? (window-top-line w-same) 1)
  (check-equal? (window-left-col w-same) 0)

  ;; ② 跨 document：源顶行 4，目标 4 行、高 2 → 夹到末页（max-top = 2）
  (define wf (mirror-window (win "l0\nl1\nl2\nl3\nl4" 2 20 4 0) (win "m0\nm1\nm2\nm3" 2 20)))
  (check-equal? (window-top-line wf) 2)
  (check-equal? (buffer->string (window-buffer wf)) "m0\nm1\nm2\nm3")   ; 目标 document 未变

  ;; ② 列按比例：源第 0 行 4 宽、left-col=4 → 目标第 0 行 2 宽、left-col=2
  (define wf2 (mirror-window (win "abcd\nab\nabcdefgh" 2 20 0 4) (win "ab\nabcdefgh" 2 20 0 0)))
  (check-equal? (window-top-line wf2) 0)
  (check-equal? (window-left-col wf2) 2)

  ;; ② wrap 投影：clip 源 → wrap 目标（列 6 落在第 2 个折行段 4..8）
  (define wa (window-set-left-col (window-open (document-open "abcdefgh") 2 20) 6))
  (define wb (window-set-mode (window-open (document-open "abcdefgh") 2 4) 'wrap))
  (define mb (mirror-window wa wb))
  (check-equal? (window-top-line mb) 0)
  (check-equal? (window-top-seg mb) 1)

  ;; ② wrap 源 → clip 目标（段 1 起点列 4 → left-col 4）
  (define wl (window-set-top-seg (window-set-mode (window-open (document-open "abcdefgh") 2 4) 'wrap) 1))
  (define wc (mirror-window wl (window-open (document-open "abcdefgh") 2 20)))
  (check-equal? (window-top-line wc) 0)
  (check-equal? (window-left-col wc) 4)

  ;; ② wrap 源 → wrap 目标（同文档同宽 → 段号对齐）
  (define wr (mirror-window wl (window-set-mode (window-open (document-open "abcdefgh") 2 4) 'wrap)))
  (check-equal? (window-top-seg wr) 1)

  ;; ② 越界 top-line 的源也能投（先夹，不崩）
  (define wover (window-set-top-line (window-open (document-open "abcdefgh") 2 20) 99))
  (check-equal? (window-top-line (mirror-window wover (window-open (document-open "xy") 2 20))) 0)

  (displayln "mirror.rkt: all tests passed"))
