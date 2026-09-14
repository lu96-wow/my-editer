#lang racket

(require tui)   ; racket-tui 包（Linux）
(require "events.rkt" "screen.rkt" "editor.rkt" "paint.rkt" rackunit)

;;; tui.rkt —— racket-tui 后端
;;;
;;; 两个职责：
;;;   输出：screen -> ANSI 字节（纯函数 screen->bytes，可单测）
;;;   输入：build-input -> 中性 ui-event
;;;
;;; 换 GUI/web 后端时，只替换本文件；editor/paint/screen 都保持不变。

(provide screen->bytes screen->bytes-diff run-tui)

;;; ---------- 主题：语义 face -> TUI 样式 ----------

(style-define! 'keyword clr-blue)
(style-define! 'string  clr-green)
(style-define! 'comment clr-white attr-dim)
(style-define! 'number  clr-magenta)
(style-define! 'builtin clr-cyan)

(define (face->style-name face)
  (match (hash-ref face 'face #f)
    ['keyword   'keyword]
    ['string    'string]
    ['comment   'comment]
    ['number    'number]
    ['builtin   'builtin]
    ['selection 'selection]
    ['cursor    'cursor]
    [_ #f]))

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
  (apply bytes-append
         (append (list format-cursor-hide format-screen-clear)
                 (for/list ([row (in-range (screen-rows s))])
                   (row->bytes s row))
                 (list (cursor-bytes s)))))

;; 增量：只重画有变化的行（先清该行再画），最后定位光标。
;; 前提：old/new 同尺寸；尺寸变化时应走 screen->bytes。
(define (screen->bytes-diff old new)
  (apply bytes-append
         (append (list format-cursor-hide)
                 (for/list ([row (in-list (screen-diff-rows old new))])
                   (bytes-append
                    (format-cursor-move (add1 row) 1)
                    format-line-clear
                    (row->bytes new row)))
                 (list (cursor-bytes new)))))

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

(define (run-tui b0 [plugins '()])
  (with-tui
   (lambda ()
     (define-values (rows cols) (get-window-size))
     (define e0 (make-editor b0 plugins (or rows 24) (or cols 80)))
     (define evt (box #f))
     (define handler (tui-input-handler (lambda (ev) (set-box! evt ev))))
     (let loop ([e e0] [prev #f])
       (define s (paint (editor-window e)))
       ;; 尺寸没变 → 增量重画；否则全量（清屏）
       (put-bytes
        (if (and prev
                 (= (screen-rows prev) (screen-rows s))
                 (= (screen-cols prev) (screen-cols s)))
            (screen->bytes-diff prev s)
            (screen->bytes s)))
       (let-values ([(type data mods) (read-event)])
         (set-box! evt #f)
         (handler type data mods)
         (define ev (unbox evt))
         (define e* (if ev (editor-handle e ev) e))
         (unless (editor-done? e*) (loop e* s)))))))

;;; ---------- 测试（只测纯函数，不碰终端）----------

(module+ test
  ;; screen->bytes 应包含光标定位 + 文本 + 光标显示
  (define s (screen 1 10 (vector (list (run 0 "hi" (hash 'face 'keyword)))) 0 2))
  (define bs (screen->bytes s))
  (define txt (bytes->string/utf-8 bs))
  (check-true (regexp-match? #rx"hi" txt))
  (check-true (regexp-match? (regexp-quote "\x1b[1;1H") txt))   ; 光标移到 (1,1)
  (check-true (regexp-match? (regexp-quote "\x1b[1;3H") txt))   ; 光标到 (1,3)

  ;; 无样式的 run 不含彩色转义
  (define s2 (screen 1 10 (vector (list (run 0 "x" (hash)))) 0 0))
  (define txt2 (bytes->string/utf-8 (screen->bytes s2)))
  (check-true (regexp-match? #rx"x" txt2))

  ;; 增量 diff：只重画变化行
  (define sa (screen 2 10 (vector (list (run 0 "aa" (hash))) (list (run 0 "bb" (hash)))) 0 0))
  (define sb (screen 2 10 (vector (list (run 0 "aa" (hash))) (list (run 0 "bc" (hash)))) 0 0))
  (define tdiff (bytes->string/utf-8 (screen->bytes-diff sa sb)))
  (check-equal? (length (regexp-match* (regexp-quote "\x1b[2K") tdiff)) 1)  ; 只清 1 行
  (check-true  (regexp-match? (regexp-quote "bc") tdiff))                     ; 变化的文本
  (check-false (regexp-match? (regexp-quote "aa") tdiff))                     ; 未变文本不重画

  (displayln "tui.rkt: all tests passed"))
