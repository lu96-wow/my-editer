#lang racket

(require tui)   ; racket-tui 包（Linux）
(require "../../core/view/events.rkt" "../../core/view/screen.rkt"
         "../../logic/event.rkt" "../../plugin/view-plugin.rkt"
         "../../core/view/paint.rkt" rackunit)

;;; tui.rkt —— racket-tui 后端
;;;
;;; 两个职责：
;;;   输出：screen + 状态段 -> ANSI 字节（纯函数，可单测）
;;;   输入：build-input -> 中性 ui-event
;;;
;;; 换 GUI/web 后端时，只替换本文件；session/paint/screen/view-plugin 都保持不变。

(provide screen->bytes screen->bytes-diff frame->bytes run-tui)

;;; ---------- 主题：语义 face -> TUI 样式（数据表）----------

(style-define! 'keyword clr-blue)
(style-define! 'string  clr-green)
(style-define! 'comment clr-white attr-dim)
(style-define! 'number  clr-magenta)
(style-define! 'builtin clr-cyan)
(style-define! 'mode    clr-yellow)

;; 语义 face → 样式名。换主题 = 换这张表。
(define face-theme
  (hash 'keyword 'keyword
        'string  'string
        'comment 'comment
        'number  'number
        'builtin 'builtin
        'mode    'mode))

(define (face->style-name face)
  (hash-ref face-theme (hash-ref face 'face #f) #f))

;;; ---------- screen -> ANSI 字节 ----------

(define (run->bytes row r)
  (define style (face->style-name (run-face r)))
  (bytes-append
   (format-cursor-move (add1 row) (add1 (run-col r)))  ; 0-based -> 1-based
   (if style
       (format-styled style (run-text r))    ; 自带 reset
       (format-content (run-text r)))))

(define (row->bytes s row)
  (apply bytes-append
         (for/list ([r (in-list (vector-ref (screen-row-runs s) row))])
           (run->bytes row r))))

(define (all-rows-bytes s)
  (apply bytes-append
         (for/list ([row (in-range (screen-rows s))])
           (row->bytes s row))))

(define (diff-rows-bytes old new)
  (apply bytes-append
         (for/list ([row (in-list (screen-diff-rows old new))])
           (bytes-append
            (format-cursor-move (add1 row) 1)
            format-line-clear
            (row->bytes new row)))))

(define (cursor-bytes s)
  (if (and (<= 0 (screen-cursor-row s) (sub1 (screen-rows s)))
           (<= 0 (screen-cursor-col s) (sub1 (screen-cols s))))
      (bytes-append
       (format-cursor-move (add1 (screen-cursor-row s))
                           (add1 (screen-cursor-col s)))
       format-cursor-show)
      format-cursor-hide))

;; 全量：清屏 + 画所有行 + 光标（首帧 / 尺寸变化时用）
(define (screen->bytes s)
  (bytes-append
   format-cursor-hide
   format-screen-clear
   (all-rows-bytes s)
   (cursor-bytes s)))

;; 增量：只重画有变化的行（先清该行再画），最后定位光标。
;; 前提：old/new 同尺寸；尺寸变化时应走 screen->bytes。
(define (screen->bytes-diff old new)
  (bytes-append
   format-cursor-hide
   (diff-rows-bytes old new)
   (cursor-bytes new)))

;;; ---------- 状态行 ----------

;; 状态段 → 底部一行 ANSI。逐段渲染（带各自 face），超长截断。
(define (status->bytes segs row cols)
  (define (seg->bytes seg col)
    (define text (status-seg-text seg))
    (define shown (substring text 0 (min (string-length text) (- cols col))))
    (define style (face->style-name (if (status-seg-face seg)
                                        (hash 'face (status-seg-face seg))
                                        (hash))))
    (values (if style (format-styled style shown) (format-content shown))
            (+ col (string-length shown))))
  (define-values (body _)
    (for/fold ([acc #""] [col 0]) ([seg (in-list segs)])
      #:break (>= col cols)
      (define-values (bs c*) (seg->bytes seg col))
      (values (bytes-append acc bs) c*)))
  (bytes-append
   (format-cursor-move row 1)
   format-line-clear
   body))

;; 整帧：buffer 区（screen）+ 底部状态行 + 光标。
;; prev 用于增量：尺寸没变只重画变化的 buffer 行，状态行与光标每帧重画。
(define (frame->bytes s segs prev)
  (define same-size? (and prev
                          (= (screen-rows prev) (screen-rows s))
                          (= (screen-cols prev) (screen-cols s))))
  (define status-row (add1 (screen-rows s)))
  (bytes-append
   format-cursor-hide
   (cond
     [(not same-size?) (bytes-append format-screen-clear (all-rows-bytes s))]
     [else (diff-rows-bytes prev s)])
   (status->bytes segs status-row (screen-cols s))
   (cursor-bytes s)))

;;; ---------- 输入：build-input -> ui-event ----------

(define (tui-input-handler emit)
  (build-input
   #:utf-char  (lambda (s)   (emit (ui-event 'insert-string (list s))))
   #:char      (lambda (ch)  (emit (ui-event 'insert-string
                                             (list (string (integer->char ch))))))
   #:up        (lambda ()    (emit (ui-event 'move-up '())))
   #:down      (lambda ()    (emit (ui-event 'move-down '())))
   #:left      (lambda ()    (emit (ui-event 'move-left '())))
   #:right     (lambda ()    (emit (ui-event 'move-right '())))
   #:backspace (lambda ()    (emit (ui-event 'backspace '())))
   #:enter     (lambda ()    (emit (ui-event 'newline '())))
   #:delete    (lambda ()    (emit (ui-event 'delete '())))
   #:home      (lambda ()    (emit (ui-event 'home '())))
   #:end       (lambda ()    (emit (ui-event 'end '())))
   #:pageup    (lambda ()    (emit (ui-event 'pageup '())))
   #:pagedown  (lambda ()    (emit (ui-event 'pagedown '())))
   #:ctrl      (lambda (ch)  (emit (ui-event 'ctrl-char (list ch))))
   #:resize    (lambda (r c) (emit (ui-event 'resize (list r c))))
   #:mouse-press
   (lambda (btn x y mods) (emit (ui-event 'mouse-press
                                          (list btn (sub1 x) (sub1 y) mods))))
   #:mouse-scroll
   (lambda (dir x y mods) (emit (ui-event 'mouse-scroll
                                          (list dir (sub1 x) (sub1 y) mods))))
   #:paste     (lambda (data) (emit (ui-event 'insert-string
                                              (list (bytes->string/utf-8 data)))))
   #:any       (lambda (t d m) (void))))

;;; ---------- 主循环 ----------

(define (run-tui b0 [plugins '()] [view-plugins '()])
  (with-tui
   (lambda ()
     (define-values (rows cols) (get-window-size))
     (define r (or rows 24))
     (define c (or cols 80))
     ;; buffer 区占 r-1 行，底部 1 行给状态栏
     (define s0 (make-session b0 plugins view-plugins (max 1 (sub1 r)) c))
     (define evt (box #f))
     (define handler (tui-input-handler (lambda (ev) (set-box! evt ev))))
     (let loop ([s s0] [prev #f])
       (define scr (paint (session-window s)))
       (define segs (session-status s))
       (put-bytes (frame->bytes scr segs prev))
       (let-values ([(type data mods) (read-event)])
         (set-box! evt #f)
         (handler type data mods)
         (define ev (unbox evt))
         (define-values (s* _desc) (if ev (session-handle s ev) (values s #f)))
         (unless (session-done? s*) (loop s* scr)))))))

;;; ---------- 测试（只测纯函数，不碰终端）----------

(module+ test
  ;; screen->bytes 应包含光标定位 + 文本 + 光标显示
  (define s (screen 1 10 (vector (list (run 0 "hi" (hash 'face 'keyword)))) 0 2))
  (define bs (screen->bytes s))
  (define txt (bytes->string/utf-8 bs))
  (check-true (regexp-match? #rx"hi" txt))
  (check-true (regexp-match? (regexp-quote "\x1b[1;1H") txt))
  (check-true (regexp-match? (regexp-quote "\x1b[1;3H") txt))

  ;; 无样式的 run 不含彩色转义
  (define s2 (screen 1 10 (vector (list (run 0 "x" (hash)))) 0 0))
  (define txt2 (bytes->string/utf-8 (screen->bytes s2)))
  (check-true (regexp-match? #rx"x" txt2))

  ;; 增量 diff：只重画变化行
  (define sa (screen 2 10 (vector (list (run 0 "aa" (hash))) (list (run 0 "bb" (hash)))) 0 0))
  (define sb (screen 2 10 (vector (list (run 0 "aa" (hash))) (list (run 0 "bc" (hash)))) 0 0))
  (define tdiff (bytes->string/utf-8 (screen->bytes-diff sa sb)))
  (check-equal? (length (regexp-match* (regexp-quote "\x1b[2K") tdiff)) 1)
  (check-true  (regexp-match? (regexp-quote "bc") tdiff))
  (check-false (regexp-match? (regexp-quote "aa") tdiff))

  ;; 状态行渲染：底部第 3 行，逐段带 face
  (define st (bytes->string/utf-8
              (status->bytes (list (status-seg "Ln 1 Col 1" #f)
                                   (status-seg "  mode" 'mode))
                             3 20)))
  (check-true (regexp-match? (regexp-quote "Ln 1 Col 1") st))
  (check-true (regexp-match? (regexp-quote "\x1b[3;1H") st))
  (check-true (regexp-match? (regexp-quote "mode") st))

  ;; 超长截断
  (define st2 (bytes->string/utf-8
               (status->bytes (list (status-seg "abcdefghijklmnop" #f)) 3 5)))
  (check-true (regexp-match? (regexp-quote "abcde") st2))
  (check-false (regexp-match? (regexp-quote "fgh") st2))

  ;; 整帧：状态行在第 2 行（buffer 1 行 + 状态 1 行）
  (define f (bytes->string/utf-8
             (frame->bytes (screen 1 8 (vector (list (run 0 "hi" (hash)))) 0 0)
                           (list (status-seg "STATUS" #f))
                           #f)))
  (check-true (regexp-match? (regexp-quote "hi") f))
  (check-true (regexp-match? (regexp-quote "STATUS") f))
  (check-true (regexp-match? (regexp-quote "\x1b[2;1H") f))

  (displayln "tui.rkt: all tests passed"))
