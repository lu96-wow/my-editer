#lang racket

;;; ui/tui.rkt —— racket-tui 前端：把 core 的 screen 接到终端
;;;
;;; 这是「终端前端」的通用层，只依赖 core/api.rkt + racket-tui，**不认识**
;;; editor / default-editor / 具体应用。一个会话只要给出三个纯函数即可跑起来：
;;;
;;;   project : session → screen                      （已 compose 好的整屏）
;;;   handle  : session core-event → (values session quit?)
;;;   resize  : session rows cols → session           （可选）
;;;
;;; 本模块负责的全部重复劳动：
;;;   · screen → ANSI 字节（文本 runs + 选区/光标 overlay；face 由 style 映射）
;;;   · 增量重绘（screen-damage：#f=整屏，否则只重画受损行 + 清行尾）
;;;   · 事件循环（with-tui + build-input + loop-input/stop）
;;;   · tui 事件 → core 事件翻译（两套 key-event/mods 不同名，统一在这里翻）
;;;   · 默认 face → tui 样式映射（应用可用 #:style 覆盖/扩展）
;;;
;;; 约定：
;;;   · paste 翻成 core 的 text-event（core 没有 paste 类型；粘贴就是「插入一段文本」）
;;;   · 可打印、无 Ctrl/Alt 的键翻成 text-event；其余键翻成 key-event
;;;   · 鼠标坐标 tui 是 1-based（SGR），core 要 0-based → 在翻译时减 1
;;;   · 鼠标 release/move 无 core 对应 → 丢弃（要就自己在应用里处理 tui 事件）
;;;
;;; 运行测试：racket ui/tui.rkt

(require "../core/api.rkt"
         ;; tui 的 key-event / resize-event / cursor-col … 与 core 同名不同义：
         ;; 先剥掉这批，让 core 的胜出；需要匹配/构造 tui 事件时用下面 prefix-in 的 tui: 版本。
         (except-in tui
                    key-event key-event? key-event-key struct:key-event
                    resize-event resize-event? resize-event-rows resize-event-cols struct:resize-event
                    cursor-col)
         (prefix-in tui: tui)
         racket/match racket/list racket/bytes rackunit)

(provide
 ;; 入口
 run-tui
 ;; 绘制（纯：screen → 字节；可直接测试 / 复用到别的后端）
 screen->bytes frame->bytes
 ;; 绘制（命令式：写入终端）
 draw-screen!
 ;; 输入翻译
 tui-event->core-events
 ;; 默认样式
 default-face->style)

;;; ===========================================================================
;;; 绘制：screen → ANSI 字节
;;; ===========================================================================

;; 默认 face → tui 样式名（core 的 face 是不透明语义值，这里给一套约定；
;; 应用可传 #:style 覆盖/扩展，例如 (lambda (f) (or (my-style f) (default-face->style f))))。
(define (default-face->style face)
  (and (hash? face)
       (case (hash-ref face 'face #f)
         [(keyword) 'info]
         [(comment) 'green]
         [(string) 'yellow]
         [(error read-only) 'error]
         [(cursor) 'cursor]
         [(selection) 'selection]
         [(line-number) 'status-bar]
         [(status status-name status-pos status-sel status-mode) 'status-bar]
         [(status-message) 'warning]
         [(tree-dir) 'info]
         [(tree-file) #f]
         [(tree-current) 'selection]
         [else #f])))

;; 从一行的 runs 里取显示列 [a,b) 的文本（宽字符按显示列切）。
(define (runs-substring runs a b)
  (define out (open-output-string))
  (for ([r (in-list runs)])
    (define rcol (run-col r))
    (define rtext (run-text r))
    (define rw (string-display-width rtext))
    (define lo (max a rcol))
    (define hi (min b (+ rcol rw)))
    (when (< lo hi)
      (display (substring rtext
                          (column->index rtext (- lo rcol))
                          (column->index rtext (- hi rcol)))
               out)))
  (get-output-string out))

;; 一个显示单元格上的字符（EOL / 空位 → 空格），用来把一个光标画成一格。
(define (cell-text runs col)
  (or (for/first ([r (in-list runs)]
                  #:when (let ([rc (run-col r)])
                           (and (<= rc col)
                                (< col (+ rc (string-display-width (run-text r)))))))
        (string (string-ref (run-text r)
                            (column->index (run-text r) (- col (run-col r))))))
      " "))

;; 画一行：文本 runs → 该行选区 → 该行光标（顺序 = 叠加次序）。
;; 只 emit! 字节，不直接写终端 —— 于是同一段逻辑既能出 bytes（测试），也能 put-bytes（跑）。
(define (emit-row! emit! scr row style)
  (define runs (screen-row scr row))
  (for ([r (in-list runs)])
    (emit! (format-cursor-move (add1 row) (add1 (run-col r))))
    (define st (style (run-face r)))
    (emit! (if st (format-styled st (run-text r)) (format-content (run-text r)))))
  (for ([g (in-list (screen-selections scr))] #:when (= row (region-row g)))
    (define txt (runs-substring runs (region-start-col g) (region-end-col g)))
    (unless (string=? txt "")
      (emit! (format-cursor-move (add1 row) (add1 (region-start-col g))))
      (emit! (format-styled 'selection txt))))
  (for ([c (in-list (screen-cursors scr))] #:when (= row (cursor-row c)))
    (emit! (format-cursor-move (add1 row) (add1 (cursor-col c))))
    (emit! (format-styled 'cursor (cell-text runs (cursor-col c))))))

;; frame->bytes : (or/c screen #f) screen [#:style] → bytes
;;   old = #f → 整屏；否则按 screen-damage：#f（尺寸变）= 整屏，否则只重画受损行（先清行尾）。
(define (frame->bytes old new #:style [style default-face->style])
  (define damage (if old (screen-damage old new) #f))
  (define parts '())
  (define (emit! b) (set! parts (cons b parts)))
  (emit! format-cursor-hide)
  (cond
    [(not damage)                                   ; 首帧 / 尺寸变
     (emit! format-screen-clear)
     (for ([row (in-range (screen-height new))])
       (emit-row! emit! new row style))]
    [else
     (for ([row (in-list damage)])
       (emit! (format-cursor-move (add1 row) 1))
       (emit! format-line-clear-right)              ; 清本行，防旧内容/旧 overlay 残留
       (emit-row! emit! new row style))])
  (emit! format-cursor-hide)
  (apply bytes-append (reverse parts)))

;; 整屏字节（测试 / 一次性绘制用）；等价于 (frame->bytes #f scr)。
(define (screen->bytes scr #:style [style default-face->style])
  (frame->bytes #f scr #:style style))

;; 命令式：算增量字节并写终端，返回新帧（调用方保存作下次的 old）。
(define (draw-screen! old new #:style [style default-face->style])
  (put-bytes (frame->bytes old new #:style style))
  new)

;;; ===========================================================================
;;; 输入翻译：tui 事件 → core 事件
;;; ===========================================================================

(define (core-modifiers m)
  (modifiers (tui:mods-ctrl? m) (tui:mods-alt? m) (tui:mods-shift? m) #f))

(define (no-core-mods) (modifiers #f #f #f #f))

;; tui 鼠标坐标是 **1-based**（SGR 协议，index.scrbl 有写）；core 要 0-based → 在边界转。
(define (tui->core-xy x y) (values (max 0 (sub1 x)) (max 0 (sub1 y))))

;; tui-event->core-events : tui-event → (listof core-event)
;;   一个 tui 事件可能翻成 0 / 1 个 core 事件（release/move/null 翻成 '()）。
(define (tui-event->core-events ev)
  (match ev
    [(tui:key-event key tmods)
     (define m (core-modifiers tmods))
     (cond
       [(symbol? key) (list (key-event key m))]
       [(and (char? key) (not (tui:mods-ctrl? tmods)) (not (tui:mods-alt? tmods)))
        (list (text-event (string key) m))]
       [else (list (key-event key m))])]
    ;; paste：core 无 paste 类型，粘的就是一段文本。
    [(tui:paste-event _bytes text) (list (text-event text (no-core-mods)))]
    [(tui:mouse-event 'press btn x y tmods)
     (define-values (cx cy) (tui->core-xy x y))
     (list (mouse-press-event btn cx cy (core-modifiers tmods)))]
    [(tui:mouse-event 'scroll 'up x y tmods)
     (define-values (cx cy) (tui->core-xy x y))
     (list (mouse-wheel-event 'up cx cy (core-modifiers tmods)))]
    [(tui:mouse-event 'scroll 'down x y tmods)
     (define-values (cx cy) (tui->core-xy x y))
     (list (mouse-wheel-event 'down cx cy (core-modifiers tmods)))]
    [(tui:mouse-event _ _ _ _ _) '()]              ; release / move：core 无对应
    [(tui:resize-event rows cols) (list (resize-event rows cols))]
    [_ '()]))                                       ; null / other

;;; ===========================================================================
;;; 事件循环
;;; ===========================================================================

;; run-tui : session #:project #:handle [#:resize] [#:style] [#:rows] [#:cols] [#:alternate-screen?]
;;   → session（最终状态；便于测试/后续处理）
;; 内部只在最外层用 set!（box 持有不可变 session，与 io/example.rkt 同套路）。
(define (run-tui session
                 #:project [project #f]
                 #:handle  [handle #f]
                 #:resize  [resize (lambda (s _rows _cols) s)]
                 #:style   [style default-face->style]
                 #:rows    [rows #f]
                 #:cols    [cols #f]
                 #:alternate-screen? [alternate? #t])
  (unless project (error 'run-tui "需要 #:project : session → screen"))
  (unless handle  (error 'run-tui "需要 #:handle : session core-event → (values session quit?)"))
  (define enter (if alternate? with-tui with-tui-nobuffer))
  (enter
   (lambda ()
     (define-values (r0 c0) (if (and rows cols) (values rows cols) (get-window-size)))
     ;; 初值先用终端尺寸调一次，应用自己按 rows/cols 摆布局 / 定 view 尺寸。
     (define state (box (resize session (max 1 r0) (max 1 c0))))
     (define last (box #f))
     (define running? (box #t))
     (define (redraw!)
       (define scr (project (unbox state)))
       (set-box! last (draw-screen! (unbox last) scr #:style style)))
     (define (step ev)
       (for ([cev (in-list (tui-event->core-events ev))])
         (when (unbox running?)                    ; 前面的 core 事件可能已要求退出
           (cond
             ;; 尺寸变化交给 #:resize（与启动时同一个回调），不进 handle
             [(resize-event? cev)
              (set-box! state (resize (unbox state) (resize-event-rows cev) (resize-event-cols cev)))]
             [else
              (define-values (s q) (handle (unbox state) cev))
              (set-box! state s)
              (when q (set-box! running? #f))])))
       (redraw!))
     (define handler (build-input #:any step))
     (redraw!)
     (loop-input/stop (not (unbox running?)) handler)
     (unbox state))))

;;; ===========================================================================
;;; 测试（纯部分：不碰终端）
;;; ===========================================================================

(module+ test
  (define (no-m) (modifiers #f #f #f #f))
  (define t-no-m (tui:mods #f #f #f))

  ;; 翻译：可打印 → text-event；命名键 → key-event；带 ctrl 的字符 → key-event
  (check-equal? (tui-event->core-events (tui:key-event #\a t-no-m)) (list (text-event "a" (no-m))))
  (check-equal? (tui-event->core-events (tui:key-event 'up t-no-m)) (list (key-event 'up (no-m))))
  (check-equal? (tui-event->core-events (tui:key-event #\b (tui:mods #t #f #f)))
                (list (key-event #\b (modifiers #t #f #f #f))))
  (check-equal? (tui-event->core-events (tui:key-event #\A (tui:mods #f #f #t)))
                (list (text-event "A" (modifiers #f #f #t #f))))
  ;; paste → text-event；resize / mouse；release / null → '()
  (check-equal? (tui-event->core-events (tui:paste-event #"hi" "hi")) (list (text-event "hi" (no-m))))
  (check-equal? (tui-event->core-events (tui:resize-event 24 80)) (list (resize-event 24 80)))
  (check-equal? (tui-event->core-events (tui:mouse-event 'press 'left 3 4 t-no-m))
                (list (mouse-press-event 'left 2 3 (no-m))))          ; tui 1-based → core 0-based
  (check-equal? (tui-event->core-events (tui:mouse-event 'scroll 'up 3 4 t-no-m))
                (list (mouse-wheel-event 'up 2 3 (no-m))))
  (check-equal? (tui-event->core-events (tui:mouse-event 'release 'left 3 4 t-no-m)) '())
  (check-equal? (tui-event->core-events (tui:null-event)) '())

  ;; 绘制：window->screen 出字节；含文本；两次同帧 damage = '()
  (define scr (window->screen (window-open (document-open "hi\n中文") 2 8)))
  (define b (screen->bytes scr))
  (check-true (bytes? b))
  (check-true (> (bytes-length b) 0))
  (check-true (regexp-match? #rx"hi" (bytes->string/utf-8 b)))
  (check-equal? (screen-damage scr scr) '())
  (check-equal? (screen-damage scr (window->screen (window-open (document-open "hi\nX") 2 8))) '(1))
  ;; 自定义 style：cursor face 映射成 'reverse
  (check-equal? ((lambda (f) (and (hash? f) (case (hash-ref f 'face #f) [(cursor) 'reverse] [else #f])))
                 (hash 'face 'cursor))
                'reverse)

  (displayln "ui/tui.rkt: all tests passed"))
