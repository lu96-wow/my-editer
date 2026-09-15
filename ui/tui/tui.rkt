#lang racket

(require tui)   ; racket-tui 包（Linux）
(require "../../core/view/events.rkt" "../../core/view/screen.rkt"
         "../../logic/event.rkt" "../../plugin/view-plugin.rkt"
         "../../core/view/paint.rkt" rackunit)

;;; ui/tui/tui.rkt —— racket-tui 后端
;;;
;;; 输出：screen + 状态段 -> ANSI 字节（纯函数，可单测）
;;; 输入：build-input -> 中性 ui-event
;;;
;;; 主题 = (hashof 语义face (list r g b [attr ...]))，由外部定义并传入 run-tui。
;;; 例：(hash 'keyword '(97 175 239) 'comment '(128 128 128 dim))
;;; attr ∈ 'bold/'dim/'italic/'underline/'reverse/'blink。
;;; 本模块隐藏 racket-tui 细节：内部把 RGB+属性翻译成真彩色转义；
;;; 不预定义任何颜色/face，查不到就纯文本。

(provide screen->bytes screen->bytes-diff frame->bytes run-tui)

;;; ---------- 样式应用（隐藏 racket-tui 细节）----------

(define (attr->thunk a)
  (case a
    [(bold) attr-bold]
    [(dim) attr-dim]
    [(italic) attr-italic]
    [(underline) attr-underline]
    [(reverse) attr-reverse]
    [(blink) attr-blink]
    [else (error 'attr->thunk "unknown attribute ~a" a)]))

(define (spec->bytes spec text)
  (match spec
    [(list r g b attrs ...)
     (define style-bytes
       (call-with-output-bytes
        (λ (out)
          (parameterize ([current-output-port out])
            ((color-rgb-fg r g b))
            (for ([a (in-list attrs)]) ((attr->thunk a)))))))
     (bytes-append style-bytes (format-content text) format-reset)]
    [else (error 'spec->bytes "bad style spec ~a" spec)]))

;;; ---------- screen -> ANSI 字节 ----------

(define (run->bytes theme row r)
  (define face (hash-ref (run-face r) 'face #f))
  (define spec (and face (hash-ref theme face #f)))   ; 查不到 → #f → 纯文本
  (bytes-append
   (format-cursor-move (add1 row) (add1 (run-col r)))  ; 0-based -> 1-based
   (if spec
       (spec->bytes spec (run-text r))
       (format-content (run-text r)))))

(define (row->bytes theme s row)
  (apply bytes-append
         (for/list ([r (in-list (vector-ref (screen-row-runs s) row))])
           (run->bytes theme row r))))

(define (all-rows-bytes theme s)
  (apply bytes-append
         (for/list ([row (in-range (screen-rows s))])
           (row->bytes theme s row))))

(define (diff-rows-bytes theme old new)
  (apply bytes-append
         (for/list ([row (in-list (screen-diff-rows old new))])
           (bytes-append
            (format-cursor-move (add1 row) 1)
            format-line-clear
            (row->bytes theme new row)))))

(define (cursor-bytes s)
  (if (and (<= 0 (screen-cursor-row s) (sub1 (screen-rows s)))
           (<= 0 (screen-cursor-col s) (sub1 (screen-cols s))))
      (bytes-append
       (format-cursor-move (add1 (screen-cursor-row s))
                           (add1 (screen-cursor-col s)))
       format-cursor-show)
      format-cursor-hide))

;; 全量：清屏 + 画所有行 + 光标
(define (screen->bytes theme s)
  (bytes-append
   format-cursor-hide
   format-screen-clear
   (all-rows-bytes theme s)
   (cursor-bytes s)))

;; 增量：只重画有变化的行
(define (screen->bytes-diff theme old new)
  (bytes-append
   format-cursor-hide
   (diff-rows-bytes theme old new)
   (cursor-bytes new)))

;;; ---------- 状态行 ----------

(define (status->bytes theme segs row cols)
  (define (seg->bytes seg col)
    (define text (status-seg-text seg))
    (define shown (substring text 0 (min (string-length text) (- cols col))))
    (define spec (and (status-seg-face seg) (hash-ref theme (status-seg-face seg) #f)))
    (values (if spec (spec->bytes spec shown) (format-content shown))
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

;; 整帧：buffer 区 + 底部状态行 + 光标
(define (frame->bytes theme s segs prev)
  (define same-size? (and prev
                          (= (screen-rows prev) (screen-rows s))
                          (= (screen-cols prev) (screen-cols s))))
  (define status-row (add1 (screen-rows s)))
  (bytes-append
   format-cursor-hide
   (cond
     [(not same-size?) (bytes-append format-screen-clear (all-rows-bytes theme s))]
     [else (diff-rows-bytes theme prev s)])
   (status->bytes theme segs status-row (screen-cols s))
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

(define (run-tui b0 theme [plugins '()] [view-plugins '()])
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
       (put-bytes (frame->bytes theme scr segs prev))
       (let-values ([(type data mods) (read-event)])
         (set-box! evt #f)
         (handler type data mods)
         (define ev (unbox evt))
         (define-values (s* _desc) (if ev (session-handle s ev) (values s #f)))
         (unless (session-done? s*) (loop s* scr)))))))

;;; ---------- 测试（只测纯函数，不碰终端）----------

(module+ test
  (define test-theme (hash 'keyword '(97 175 239)   ; 蓝
                           'mode    '(229 192 123))) ; 黄

  ;; screen->bytes：已注册 face 带颜色、光标定位正确
  (define s (screen 1 10 (vector (list (run 0 "hi" (hash 'face 'keyword)))) 0 2))
  (define bs (screen->bytes test-theme s))
  (define txt (bytes->string/utf-8 bs))
  (check-true (regexp-match? #rx"hi" txt))
  (check-true (regexp-match? (regexp-quote "\x1b[1;1H") txt))
  (check-true (regexp-match? (regexp-quote "\x1b[1;3H") txt))

  ;; 未注册 face → 纯文本（不产生样式字节）
  (define s2 (screen 1 10 (vector (list (run 0 "x" (hash 'face 'unknown)))) 0 0))
  (define txt2 (bytes->string/utf-8 (screen->bytes test-theme s2)))
  (check-true (regexp-match? #rx"x" txt2))

  ;; 增量 diff：只重画变化行
  (define sa (screen 2 10 (vector (list (run 0 "aa" (hash))) (list (run 0 "bb" (hash)))) 0 0))
  (define sb (screen 2 10 (vector (list (run 0 "aa" (hash))) (list (run 0 "bc" (hash)))) 0 0))
  (define tdiff (bytes->string/utf-8 (screen->bytes-diff test-theme sa sb)))
  (check-equal? (length (regexp-match* (regexp-quote "\x1b[2K") tdiff)) 1)
  (check-true  (regexp-match? (regexp-quote "bc") tdiff))
  (check-false (regexp-match? (regexp-quote "aa") tdiff))

  ;; 状态行：逐段带 face，超长截断
  (define st (bytes->string/utf-8
              (status->bytes test-theme
                             (list (status-seg "Ln 1 Col 1" #f)
                                   (status-seg "  mode" 'mode))
                             3 20)))
  (check-true (regexp-match? (regexp-quote "Ln 1 Col 1") st))
  (check-true (regexp-match? (regexp-quote "\x1b[3;1H") st))
  (check-true (regexp-match? (regexp-quote "mode") st))

  (define st2 (bytes->string/utf-8
               (status->bytes test-theme (list (status-seg "abcdefghijklmnop" #f)) 3 5)))
  (check-true (regexp-match? (regexp-quote "abcde") st2))
  (check-false (regexp-match? (regexp-quote "fgh") st2))

  ;; 整帧：状态行在第 2 行
  (define f (bytes->string/utf-8
             (frame->bytes test-theme
                           (screen 1 8 (vector (list (run 0 "hi" (hash)))) 0 0)
                           (list (status-seg "STATUS" #f))
                           #f)))
  (check-true (regexp-match? (regexp-quote "hi") f))
  (check-true (regexp-match? (regexp-quote "STATUS") f))
  (check-true (regexp-match? (regexp-quote "\x1b[2;1H") f))

  (displayln "tui.rkt: all tests passed"))
