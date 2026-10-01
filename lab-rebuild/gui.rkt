#lang racket/gui

;;; ============================================================================
;;; gui.rkt —— racket/gui 后端
;;; ============================================================================
;;;
;;;   racket lab-rebuild/gui.rkt
;;;
;;; 与 tui.rkt 对称：只做「gui 事件 → 中间层输入」和「core screen → 画布」。
;;; gui 特有：像素→格；on-char 一次一个字符（普通字符也算物理键 key）；
;;; gui 的 Backspace/Return/Tab/Delete 是**字符**（#\backspace 等），要归成命名键；
;;; wheel 是 key-event（'wheel-up/down），用最近鼠标位置定位；
;;; motion 带按键 → 'drag，不带 → 'move。

(require "../core/view/base/screen.rkt"
         "../core/text/base/width.rkt"
         "theme.rkt"
         "io.rkt"
         "host.rkt"
         "init.rkt")

;;; ---------- 后端状态（只跟画有关） ----------

(define app-box (box #f))
(define frame-box (box #f))
(define canvas-box (box #f))
(define font-box (box #f))
(define cell-w (box 8))
(define cell-h (box 16))
(define mouse-pos (box (cons 0 0)))

(define (the-font)
  (or (unbox font-box)
      (let ([f (make-font #:size 12 #:family 'modern)]) (set-box! font-box f) f)))

;;; ---------- 配色 ----------

(define default-bg (make-color 25 26 30))
(define default-fg (make-color 205 205 205))
(define selection-bg (make-color 58 74 128))
(define cursor-bg (make-color 225 225 235))
(define cursor-fg (make-color 25 26 30))

(define (rgb->color rgb fallback) (if rgb (apply make-color rgb) fallback))
(define (no-pen dc) (send dc set-pen "black" 0 'transparent))

;;; ---------- 坐标 ----------

(define (pixel->cell x y) (values (quotient y (unbox cell-h)) (quotient x (unbox cell-w))))

;;; ---------- gui key-code → 命名键 ----------

(define (key-code->name code)
  (case code
    [(#\backspace) 'backspace]
    [(#\rubout) 'delete]
    [(#\return #\newline) 'enter]
    [(#\tab) 'tab]
    [(up) 'up] [(down) 'down] [(left) 'left] [(right) 'right]
    [(home) 'home] [(end) 'end]
    [(prior) 'pageup] [(next) 'pagedown]
    [(backspace) 'backspace] [(delete) 'delete]
    [(return) 'enter] [(kp-enter) 'enter] [(tab) 'tab] [(escape) 'escape]
    [else code]))

(define (gui-mods e)
  (modifiers (send e get-control-down) (send e get-alt-down)
             (send e get-shift-down) (send e get-meta-down)))

;;; ---------- 输入 ----------

(define (send-input in)
  (define h (unbox app-box))
  (when h
    (set-box! app-box (handle h in))
    (define c (unbox canvas-box))
    (when c (send c refresh))))

(define (on-key e)
  (define code (send e get-key-code))
  (define m (gui-mods e))
  (cond
    [(eq? code 'release) (void)]
    [(memq code '(wheel-up wheel-down wheel-left wheel-right))
     (when (memq code '(wheel-up wheel-down))
       (send-input (wheel (if (eq? code 'wheel-up) 'up 'down)
                          (car (unbox mouse-pos)) (cdr (unbox mouse-pos)) m)))]
    [else
     (define ctrl? (send e get-control-down))
     (define name (key-code->name code))
     (send-input (key (if (and ctrl? (char? name)) (char-downcase name) name) m))]))

(define (on-mouse e)
  (define-values (row col) (pixel->cell (send e get-x) (send e get-y)))
  (set-box! mouse-pos (cons row col))
  (define m (gui-mods e))
  (case (send e get-event-type)
    [(left-down)   (send-input (mouse 'press 'left row col m))]
    [(middle-down) (send-input (mouse 'press 'middle row col m))]
    [(right-down)  (send-input (mouse 'press 'right row col m))]
    [(left-up)     (send-input (mouse 'release 'left row col m))]
    [(middle-up)   (send-input (mouse 'release 'middle row col m))]
    [(right-up)    (send-input (mouse 'release 'right row col m))]
    [(motion)
     (define btn (cond [(send e get-left-down) 'left]
                       [(send e get-middle-down) 'middle]
                       [(send e get-right-down) 'right]
                       [else #f]))
     (send-input (mouse (if btn 'drag 'move) btn row col m))]
    [else (void)]))

;;; ---------- 画 ----------

(define (char-at s row col)
  (for/first ([rn (in-list (screen-row s row))]
              #:when (and (>= col (run-col rn))
                          (< col (+ (run-col rn) (string-display-width (run-text rn))))))
    (string-ref (run-text rn) (- col (run-col rn)))))

(define (draw-screen dc s)
  (define cw (unbox cell-w))
  (define ch (unbox cell-h))
  (send dc set-font (the-font))
  (send dc set-brush default-bg 'solid) (no-pen dc)
  (send dc draw-rectangle 0 0 (* (screen-width s) cw) (* (screen-height s) ch))
  (send dc set-brush selection-bg 'solid)
  (for ([g (in-list (screen-regions s))])
    (send dc draw-rectangle (* (region-start-col g) cw) (* (region-row g) ch)
          (* (- (region-end-col g) (region-start-col g)) cw) ch))
  (for ([row (in-range (screen-height s))])
    (for ([rn (in-list (screen-row s row))])
      (define-values (fg bg) (face-colors (run-face rn)))
      (define bg* (rgb->color bg #f))
      (when bg*
        (send dc set-brush bg* 'solid) (no-pen dc)
        (send dc draw-rectangle (* (run-col rn) cw) (* row ch)
              (* (string-display-width (run-text rn)) cw) ch))
      (send dc set-text-foreground (rgb->color fg default-fg))
      (send dc draw-text (run-text rn) (* (run-col rn) cw) (* row ch))))
  (for ([cu (in-list (screen-cursors s))])
    (define x (* (cursor-col cu) cw)) (define y (* (cursor-row cu) ch))
    (send dc set-brush cursor-bg 'solid) (no-pen dc)
    (send dc draw-rectangle x y cw ch)
    (define c (char-at s (cursor-row cu) (cursor-col cu)))
    (when c
      (send dc set-text-foreground cursor-fg)
      (send dc draw-text (string c) x y))))

(define (on-paint dc)
  (send dc set-font (the-font))
  ;; 宽度用单个字形量（"Mg" 是两个字符宽）；高度用带升降部的 "Mg"。
  (define-values (fw _fh _fd _fs) (send dc get-text-extent "M"))
  (define-values (_mw fh _md _ms) (send dc get-text-extent "Mg"))
  (set-box! cell-w (max 1 (exact-ceiling fw)))
  (set-box! cell-h (max 1 (exact-ceiling fh)))
  (define-values (pw ph) (send dc get-size))
  (define cols (max 1 (exact-floor (/ pw (unbox cell-w)))))
  (define rows (max 1 (exact-floor (/ ph (unbox cell-h)))))
  (unless (unbox app-box)
    (set-box! app-box (setup (current-directory) rows cols)))
  (define h (unbox app-box))
  (when (or (not (= (host-rows h) rows)) (not (= (host-cols h) cols)))
    (set-box! app-box (handle h (resize rows cols))))
  (define-values (h1 screen) (render (unbox app-box)))
  (set-box! app-box h1)
  (draw-screen dc screen))

;;; ---------- 窗口 ----------

(define lab-canvas%
  (class canvas%
    (super-new)
    (define/override (on-char e) (on-key e))
    (define/override (on-event e)
      (cond [(is-a? e key-event%) (on-key e)]
            [(is-a? e mouse-event%) (on-mouse e)]
            [else (void)]))))

(define (run)
  (define frame (new frame% [label "lab-rebuild"] [width 800] [height 480]))
  (define canvas (new lab-canvas% [parent frame]
                      [paint-callback (lambda (_c dc) (on-paint dc))]))
  (set-box! frame-box frame)
  (set-box! canvas-box canvas)
  (send frame show #t)
  (send canvas focus))

(module+ main (run))

;;; ---------- 测试 ----------

(module+ test
  (require rackunit "../core/editor.rkt")

  (check-equal? (key-code->name 'return) 'enter)
  (check-equal? (key-code->name #\backspace) 'backspace)
  (check-equal? (key-code->name #\rubout) 'delete)
  (check-equal? (key-code->name #\return) 'enter)
  (check-equal? (key-code->name #\tab) 'tab)
  (check-equal? (key-code->name #\a) #\a)
  (let-values ([(r c) (pixel->cell 17 33)]) (check-equal? (list r c) '(2 2)))

  ;; 冒烟：往 bitmap 上渲染一帧
  (define bm (make-bitmap 320 200))
  (on-paint (new bitmap-dc% [bitmap bm]))
  (check-true (host? (unbox app-box)))
  (define dc2 (new bitmap-dc% [bitmap bm]))
  (send dc2 set-font (the-font))
  (define one-glyph (let-values ([(w _h _d _s) (send dc2 get-text-extent "M")])
                      (max 1 (exact-ceiling w))))
  (check-equal? (unbox cell-w) one-glyph)

  ;; 真事件：树焦点 0，n → 打字 → Backspace → Esc
  (define (tree-str)
    (editor-view-string (host-editor (unbox app-box)) (host-pane-vid (unbox app-box) 0)))
  (check-equal? (host-focus (unbox app-box)) 0)
  (on-key (new key-event% [key-code #\n]))
  (check-true (regexp-match? #rx"新建文件" (tree-str)))
  (on-key (new key-event% [key-code #\a]))
  (check-true (regexp-match? #rx"新建文件: a" (tree-str)))
  (on-key (new key-event% [key-code #\backspace]))
  (check-false (regexp-match? #rx"新建文件: a" (tree-str)))
  (on-key (new key-event% [key-code 'escape]))
  (check-false (regexp-match? #rx"新建文件" (tree-str)))

  (displayln "lab-rebuild/gui.rkt: all tests passed"))
