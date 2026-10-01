#lang racket/gui

;;; ============================================================================
;;; gui.rkt —— racket/gui 后端（**唯一 require racket/gui 的文件**）
;;; ============================================================================
;;;
;;;   racket lab/gui.rkt
;;;
;;; 与 tui.rkt 完全对称，只有两个职责：
;;;
;;;   入：gui 事件 ──event->input──▶ input.rkt 的中间层输入 ──▶ handle
;;;   出：init/render 的 core screen ──paint──▶ 画布
;;;
;;; 它不认识命令、不碰文档、不做焦点、不存业务状态（只存上一帧无关的字体度量）。
;;; 两个后端唯一的差别就是「自家事件怎么译成中间层输入」和「screen 怎么画」：
;;; state / tree / buffer / status / command / core 一行不改。
;;;
;;; gui 特有的东西全在这里：
;;;   · 像素坐标 → 屏幕格坐标（按字体度量换算）
;;;   · gui 的 on-char 一次只给一个字符，所以普通字符也归成 key（物理键），
;;;     这样 gui / tui 对同一个键 v 都给 key #\v，组件命令分发不依赖后端；
;;;     text 留给能一次性给出已解码文本的后端（如 tui 的 paste）
;;;   · gui 的 wheel 是一个 key-event（key-code = 'wheel-up/down），用最近鼠标位置定位
;;;   · motion 带按键 → 'drag，不带 → 'move（于是无按键移动不会误扩选）

(require "../core/view/base/screen.rkt"
         "../core/text/base/width.rkt"
         "theme.rkt"
         "input.rkt"
         "state.rkt"
         "init.rkt")

;;; ---------- 后端状态（只跟画有关，不含业务） ----------

(define app-box (box #f))          ; 当前 app
(define frame-box (box #f))
(define canvas-box (box #f))
(define font-box (box #f))
(define cell-w (box 8))            ; 一个字符格宽 / 高（像素），首帧按字体量出
(define cell-h (box 16))
(define mouse-pos (box (cons 0 0))) ; 最近鼠标所在屏幕格（wheel 用）

(define (the-font)
  (or (unbox font-box)
      (let ([f (make-font #:size 12 #:family 'modern)]) (set-box! font-box f) f)))

;;; ---------- 配色：face / overlay → draw 颜色 ----------

(define default-bg (make-color 25 26 30))
(define default-fg (make-color 205 205 205))
(define selection-bg (make-color 58 74 128))
(define cursor-bg (make-color 225 225 235))
(define cursor-fg (make-color 25 26 30))

(define (rgb->color rgb fallback) (if rgb (apply make-color rgb) fallback))
(define (no-pen dc) (send dc set-pen "black" 0 'transparent))

;;; ---------- 坐标 ----------

;; 像素 → 屏幕格（0-based）。
(define (pixel->cell x y)
  (values (quotient y (unbox cell-h)) (quotient x (unbox cell-w))))

;;; ---------- gui key-code → 中间层命名键 ----------

(define (key-code->name code)
  (case code
    ;; 这几个特殊键 gui 给的是**字符**（见 key-event% 文档），必须归成命名键。
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

;;; ---------- 输入：gui 事件 → 中间层输入 → handle ----------

(define (send-input in)
  (define a (unbox app-box))
  (when a
    (set-box! app-box (handle a in))
    (define c (unbox canvas-box))
    (when c (send c refresh))
    (when (app-quit? (unbox app-box))
      (define f (unbox frame-box))
      (when f (send f show #f)))))

;; gui 键盘（on-char）：普通字符 → text（已解码，含 Shift/IME）；带修饰/命名键 → key。
(define (on-key e)
  (define code (send e get-key-code))
  (define m (gui-mods e))
  (cond
    [(eq? code 'release) (void)]
    ;; 滚轮在 gui 里也是 key-event（key-code = 'wheel-*）；用最近鼠标位置定位。
    [(memq code '(wheel-up wheel-down wheel-left wheel-right))
     (when (memq code '(wheel-up wheel-down))
       (define row (car (unbox mouse-pos)))
       (define col (cdr (unbox mouse-pos)))
       (send-input (wheel (if (eq? code 'wheel-up) 'up 'down) row col m)))]
    [else
     (define ctrl? (send e get-control-down))
     (define alt? (send e get-alt-down))
     (define meta? (send e get-meta-down))
     ;; 普通字符也是**物理键**（中间层：key = 物理键，text = 已解码文本/粘贴）。
     ;; 于是 gui / tui 对同一个键 v 都给 key #\v，树的命令分发不依赖后端。
     (define name (key-code->name code))
     (send-input (key (if (and ctrl? (char? name)) (char-downcase name) name) m))]))

;; gui 鼠标（on-event）：down/up → press/release；motion 带键 → drag，不带 → move。
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

;;; ---------- 画：core screen → 画布 ----------

;; 光标格上的字符（反色时重画用）。
(define (char-at s row col)
  (for/first ([rn (in-list (screen-row s row))]
              #:when (and (>= col (run-col rn))
                          (< col (+ (run-col rn) (string-display-width (run-text rn))))))
    (string-ref (run-text rn) (- col (run-col rn)))))

(define (draw-screen dc s)
  (define cw (unbox cell-w))
  (define ch (unbox cell-h))
  (send dc set-font (the-font))
  ;; 背景
  (send dc set-brush default-bg 'solid) (no-pen dc)
  (send dc draw-rectangle 0 0 (* (screen-width s) cw) (* (screen-height s) ch))
  ;; 选区底
  (send dc set-brush selection-bg 'solid)
  (for ([g (in-list (screen-regions s))])
    (send dc draw-rectangle (* (region-start-col g) cw) (* (region-row g) ch)
          (* (- (region-end-col g) (region-start-col g)) cw) ch))
  ;; 文本（face 前景 / 背景）
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
  ;; 光标（反色块 + 重画字符）
  (for ([cu (in-list (screen-cursors s))])
    (define x (* (cursor-col cu) cw)) (define y (* (cursor-row cu) ch))
    (send dc set-brush cursor-bg 'solid) (no-pen dc)
    (send dc draw-rectangle x y cw ch)
    (define c (char-at s (cursor-row cu) (cursor-col cu)))
    (when c
      (send dc set-text-foreground cursor-fg)
      (send dc draw-text (string c) x y))))

;; 一帧：按画布像素尺寸定 app 的行列 → render → 画。
(define (on-paint dc)
  (send dc set-font (the-font))
  ;; 宽度必须用**单个**字形量（"Mg" 是两个字符宽）；高度用带升降部的 "Mg"。
  (define-values (fw _fh _fd _fs) (send dc get-text-extent "M"))
  (define-values (_mw fh _md _ms) (send dc get-text-extent "Mg"))
  (set-box! cell-w (max 1 (exact-ceiling fw)))
  (set-box! cell-h (max 1 (exact-ceiling fh)))
  (define-values (pw ph) (send dc get-size))
  (define cols (max 1 (exact-floor (/ pw (unbox cell-w)))))
  (define rows (max 1 (exact-floor (/ ph (unbox cell-h)))))
  (unless (unbox app-box)
    (set-box! app-box (setup (current-directory) rows cols)))
  (define a (unbox app-box))
  (when (or (not (= (app-rows a) rows)) (not (= (app-cols a) cols)))
    (set-box! app-box (handle a (resize rows cols))))
  (define-values (a1 screen) (render (unbox app-box)))
  (set-box! app-box a1)
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
  (define frame (new frame% [label "lab"] [width 800] [height 480]))
  (define canvas (new lab-canvas% [parent frame]
                      [paint-callback (lambda (_c dc) (on-paint dc))]))
  (set-box! frame-box frame)
  (set-box! canvas-box canvas)
  (send frame show #t)
  (send canvas focus))

(module+ main (run))

;;; ---------- 测试（纯函数） ----------

(module+ test
  (require rackunit
           "../core/editor.rkt")

  (check-equal? (key-code->name 'return) 'enter)
  (check-equal? (key-code->name 'prior) 'pageup)
  (check-equal? (key-code->name 'next) 'pagedown)
  (check-equal? (key-code->name 'backspace) 'backspace)
  (check-equal? (key-code->name #\a) #\a)
  ;; gui 的这几个特殊键是**字符**，必须归成命名键（否则会被当成文本插入控制符）
  (check-equal? (key-code->name #\backspace) 'backspace)
  (check-equal? (key-code->name #\rubout) 'delete)
  (check-equal? (key-code->name #\return) 'enter)
  (check-equal? (key-code->name #\tab) 'tab)
  (check-equal? (key-code->name #\space) #\space)

  ;; 像素 → 格（默认度量 8×16）
  (let-values ([(r c) (pixel->cell 17 33)])
    (check-equal? (list r c) '(2 2)))

  ;; 冒烟：往一张 bitmap 上渲染一帧（不需要开窗）
  (define bm (make-bitmap 320 200))
  (on-paint (new bitmap-dc% [bitmap bm]))
  (check-true (app? (unbox app-box)))
  (check-equal? (app-cols (unbox app-box)) (max 1 (quotient 320 (unbox cell-w))))
  (check-equal? (app-rows (unbox app-box)) (max 1 (quotient 200 (unbox cell-h))))
  ;; 格宽 = **单个**字形宽（不是 "Mg" 的宽度）
  (define dc2 (new bitmap-dc% [bitmap bm]))
  (send dc2 set-font (the-font))
  (define one-glyph (let-values ([(w _h _d _s) (send dc2 get-text-extent "M")])
                      (max 1 (exact-ceiling w))))
  (check-equal? (unbox cell-w) one-glyph)

  ;; 真事件走一遍适配器：打 'a' 再按 Backspace（gui 给的是 #\backspace 字符）
  (define (buf-str)
    (editor-view-string (app-editor (unbox app-box))
                        (app-pane-vid (unbox app-box) 1)))
  (on-key (new key-event% [key-code #\a]))
  (check-equal? (buf-str) "a")
  (on-key (new key-event% [key-code #\backspace]))
  (check-equal? (buf-str) "")                         ; 删除，而不是插入不可见控制符
  (on-key (new key-event% [key-code #\tab]))
  (check-equal? (buf-str) "    ")                     ; Tab = 4 空格，不是字面 \t

  ;; 树的普通字母命令（v/n/m/d）：gui 必须给成 key，否则会被当成“已解码文本”丢掉
  (set-box! app-box (focus-set (unbox app-box) 0))    ; 焦点切到树
  (on-key (new key-event% [key-code #\n]))            ; 新建文件
  (check-true (regexp-match? #rx"新建文件"
                (editor-view-string (app-editor (unbox app-box))
                                    (app-pane-vid (unbox app-box) 0))))
  (on-key (new key-event% [key-code 'escape]))         ; 取消
  (check-false (regexp-match? #rx"新建文件"
                 (editor-view-string (app-editor (unbox app-box))
                                     (app-pane-vid (unbox app-box) 0))))

  (displayln "lab/gui.rkt: all tests passed"))
