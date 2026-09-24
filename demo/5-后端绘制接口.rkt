#lang racket

;;; ============================================================================
;;; demo/5-后端绘制接口.rkt —— 只认「绘制项 + 脏矩形」的后端原型
;;; ============================================================================
;;;
;;;   racket demo/5-后端绘制接口.rkt
;;;
;;; 这个「后端」只 require：
;;;   core/api.rkt      —— 帧的生产（window->screen / screen-compose / pane）
;;;   core/target.rkt   —— 绘制项 draw-item、脏矩形 rect、frame->draw-list / frame->patch
;;;
;;; 它**不知道** run / cursor / region / screen / pane 的内部结构，也不做 width 换算，
;;; 只做一件事：在 (x,y) 画一段带属性的文本。证明后端接口可以缩到
;;; 「x y 宽 高 文本 属性」+「脏矩形」。

(require "../core/api.rkt"
         "../core/target.rkt"
         racket/string)

(printf "\n================ 0. 构造帧（这部分是 window 管理，不是后端） ================\n")

(define d0 (document-open "hello\nworld\n中文字"))
(define d1 (document-open "alpha\nbeta\ngamma"))

;; 两个窗口，各带光标 / 选区 / 行号
(define w0 (window-set-line-numbers
            (window-set-point
             (window-set-selections (window-open d0 3 12)
                                    (list (selection (point 0 1) (point 0 4))))
             (point 0 4))
            #t))
(define w1 (window-set-point (window-open d1 3 10) (point 1 2)))

;; 单窗帧 + 合成帧（compose 仍属窗口管理；后端不碰）
(define frame0 (window->screen w0))
(define frame1 (window->screen w1))
(define composed (screen-compose 3 24 (list (pane 'left 0 0 frame0)
                                            (pane 'right 14 0 frame1))
                                 'left))

;;; ============================================================================
;;; 后端：只认绘制项
;;; ============================================================================

;; 属性 → 样式（后端唯一要理解 attr 的地方；core 不给颜色）
(define (attr->style attr)
  (and (hash? attr)
       (case (hash-ref attr 'face #f)
         [(cursor)    'reverse]
         [(selection) 'underline]
         [(line-number) 'dim]
         [(keyword)   'bold]
         [else #f])))

;; 帧 → 文本行：逐绘制项写进网格。只用 frame-width/height + draw-item-*。
;; （网格渲染器需要知道宽字符占几列；真实终端后端不需要——它只 move+输出文本。）
(define (frame->lines scr)
  (define h (frame-height scr))
  (define w (frame-width scr))
  ;; 空格为底；宽字符占两格，第二格标 #\nul（输出时跳过，否则会多一个字符）。
  (define grid (for/vector ([_ (in-range h)]) (make-vector w #\space)))
  (for ([it (in-list (frame->draw-list scr))])
    (define row (draw-item-y it))
    (when (and (>= row 0) (< row h))
      (define t (draw-item-text it))
      (let loop ([i 0] [c (draw-item-x it)])
        (when (< i (string-length t))
          (define ch (string-ref t i))
          (define cw (char-display-width ch))
          (when (and (>= c 0) (< c w))
            (vector-set! (vector-ref grid row) c ch)
            (when (and (> cw 1) (< (add1 c) w))
              (vector-set! (vector-ref grid row) (add1 c) #\nul)))
          (loop (add1 i) (+ c cw))))))
  (for/list ([row (in-vector grid)])
    (list->string (for/list ([ch (in-vector row)] #:unless (char=? ch #\nul)) ch))))

;; 帧 → ANSI 字节：后端真正的工作方式——移动到 (x,y)、按属性设样式、输出文本。
;; 不需要 screen/run，也不需要自己做任何切片。
(define (frame->bytes scr)
  (define parts '())
  (define (emit! b) (set! parts (cons b parts)))
  (emit! (string->bytes/utf-8 "\e[?25l\e[2J"))
  (for ([it (in-list (frame->draw-list scr))])
    (emit! (string->bytes/utf-8
            (format "\e[~a;~aH" (add1 (draw-item-y it)) (add1 (draw-item-x it)))))
    (define st (attr->style (draw-item-attr it)))
    (emit! (string->bytes/utf-8
            (if st (format "\e[~am~a\e[0m"
                           (case st [(reverse) 7] [(underline) 4] [(bold) 1] [(dim) 2] [else 0])
                           (draw-item-text it))
                (draw-item-text it)))))
  (emit! (string->bytes/utf-8 "\e[?25h"))
  (apply bytes-append (reverse parts)))

(printf "--- 单窗帧（frame0）绘制项 ---\n")
(for ([it (in-list (frame->draw-list frame0))])
  (printf "  layer=~a  (x=~a y=~a w=~a)  ~s  attr=~s\n"
          (draw-item-layer it) (draw-item-x it) (draw-item-y it)
          (draw-item-width it) (draw-item-text it) (draw-item-attr it)))

(printf "--- 合成帧（左右两块 + 行号栏）文本视图 ---\n")
(for ([ln (in-list (frame->lines composed))]) (printf "  |~a|\n" ln))

(printf "--- 合成帧 ANSI 字节数（真实后端就输出它）: ~a bytes ---\n"
        (bytes-length (frame->bytes composed)))

;;; ============================================================================
;;; 增量：frame->patch 给出列级脏矩形 + 修补绘制项
;;; ============================================================================

(printf "\n================ 1. 增量重绘（列级脏矩形） ================\n")

;; 只把光标从第 0 行第 0 列移到第 0 行第 3 列
(define wA (window-set-point (window-open d0 3 12) (point 0 0)))
(define wB (window-set-point (window-open d0 3 12) (point 0 3)))
(define-values (rects patch) (frame->patch (window->screen wA) (window->screen wB)))
(printf "光标 (0,0)→(0,3)：脏矩形 = ~s\n" rects)
(printf "修补绘制项 = ~s\n" patch)
(printf "→ 只重画 ~a 列，而不是整行 12 列\n"
        (for/sum ([r (in-list rects)]) (rect-width r)))

;; 改一个字符（同形文档，只有第 2 列不同）：列级 1 格
(define wC (window-set-point (window-open (document-open "heXlo\nworld\n中文字") 3 12) (point 0 0)))
(define-values (rects2 _patch2) (frame->patch (window->screen wA) (window->screen wC)))
(printf "文本 hello→heXlo（同形）：脏矩形 = ~s（只第 2 列）\n" rects2)

;; 尺寸变：整屏
(define-values (rects3 _p3)
  (frame->patch (window->screen wA) (window->screen (window-open d0 4 12))))
(printf "帧尺寸变：脏矩形 = ~s（#f = 整屏）\n" rects3)

(printf "\n================ 2. 彻底增量：只重投影脏行 ================\n")

;; 应用侧持有 projection（帧 + 布局）；改动来自 change-report 的行区间。
(define dA (document-open "aaaa\nbbbb\ncccc\ndddd"))
(define dB (document-open "aaaa\nbXbb\ncccc\ndddd"))
(define pA (window->projection (window-open dA 4 12)))
(define-values (pB dirty) (window->projection/incremental pA (window-open dB 4 12) '(1)))
(printf "只改第 1 行 → 脏屏幕行 = ~s（不是 (0 1 2 3)）\n" dirty)
(define-values (rects4 items4) (frame-damage (projection-screen pA) (projection-screen pB) dirty))
(printf "frame-damage → 脏矩形 = ~s，patch 绘制项 = ~a 个（只来自脏行）\n" rects4 (length items4))

;; 对照：layout 变（行数变）→ 退回全量
(define-values (_pC dirty2) (window->projection/incremental pA (window-open (document-open "aaaa") 4 12) '(0)))
(printf "行数变 → 脏屏幕行 = ~s（全量）\n" dirty2)


(printf "\n================ 3. 多窗格：增量合成 ================\n")

;; 两个窗格各自投影（左 L / 右 R），全量合成一次。
(define pL (window->projection (window-open (document-open "aaaa\nbbbb\ncccc") 3 8)))
(define pR (window->projection (window-open (document-open "1111\n2222\n3333") 3 8)))
(define comp0 (compose-panes 3 20 (list (pane 'L 0 0 (projection-screen pL))
                                        (pane 'R 10 0 (projection-screen pR))) 'L))

;; 只改左窗格第 1 行：先增量投影，再增量合成。
(define-values (pL2 left-dirty)
  (window->projection/incremental pL (window-open (document-open "aaaa\nbXbb\ncccc") 3 8) '(1)))
(define-values (comp1 comp-dirty)
  (composition-refresh comp0 3 20
                       (list (pane 'L 0 0 (projection-screen pL2))
                             (pane 'R 10 0 (projection-screen pR)))
                       'L
                       (hash 'L left-dirty)))
(printf "左窗格第 1 行改 → 合成脏行 = ~s（不是 (0 1 2)）\n" comp-dirty)
(define-values (crects citems)
  (frame-damage (composition-screen comp0) (composition-screen comp1) comp-dirty))
(printf "frame-damage → 脏矩形 = ~s，patch 绘制项 = ~a 个\n" crects (length citems))

;; 全量渲染 API 一直保留：需要整屏时直接 frame->draw-list / screen-compose。
(printf "全量路径：frame->draw-list 项数 = ~a\n"
        (length (frame->draw-list (composition-screen comp1))))


(printf "\n5-后端绘制接口.rkt 运行结束。\n")
