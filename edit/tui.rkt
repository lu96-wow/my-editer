#lang racket

;;; edit/tui.rkt —— racket-tui 输入 / 输出后端
;;;
;;; 输入：read-event -> resolve（panel 键表 ⊕ 文档键表 ⊕ 全局）-> step（纯）-> session
;;; 输出：session-refresh（刷新状态窗口）-> core 合成 -> pieces -> format-* 字节
;;;
;;; 只有本模块碰终端 / FFI；session / layout / focus 保持纯。

(require tui
         "command/command.rkt"
         "session.rkt"
         "command/binding.rkt"
         "core/keymap.rkt"
         "theme/theme.rkt"
         "theme/style.rkt")

(provide resolve piece-style draw! run-tui)

;;; ---------- 输入：event -> cmd ----------

(define (spec->cmd spec ev)
  (cond [(prefix? spec) (cmd-prefix spec)]
        [(eq? spec text-spec) (cmd-insert (or (event-text ev) ""))]
        [(eq? spec resize-spec) (cmd-resize (resize-event-cols ev) (resize-event-rows ev))]
        [(eq? spec mouse-press-spec) (cmd-mouse-press (mouse-col ev) (mouse-row ev))]
        [(eq? spec mouse-scroll-up-spec) (cmd-mouse-scroll (mouse-col ev) (mouse-row ev) -1)]
        [(eq? spec mouse-scroll-down-spec) (cmd-mouse-scroll (mouse-col ev) (mouse-row ev) 1)]
        [(procedure? spec) (spec ev)]
        [else spec]))

(define (resolve s ev)
  (define b (event->binding ev))
  (define pfx (session-prefix s))
  (cond
    ;; 前缀激活：只在当前前缀键表里查；未命中则取消
    [pfx
     (define spec (and b (keymap-lookup (prefix-keymap pfx) b)))
     (cond [spec (spec->cmd spec ev)]
           [else (cmd-prefix-cancel)])]
    [else
     ;; 输入层优先（fallthrough）：层表命中就用，落空再走 panel / document / global。
     (define layer-spec
       (and b (for/or ([l (in-list (session-layers s))])
                (keymap-lookup (layer-keys l) b))))
     (cond
       [layer-spec (spec->cmd layer-spec ev)]
       [else
        (define vid (session-focus-vid s))
        (define did (session-focused-did s))
        (define kms (append (filter values
                                    (list (and vid (session-vid-keys s vid))
                                          (and did (session-doc-keys s did))))
                            (session-keys s)))
        (and b
             (for/or ([km (in-list kms)])
               (define spec (keymap-lookup km b))
               (and spec (spec->cmd spec ev))))])]))

;;; ---------- 输出：session -> pieces ----------

;; piece 的外观：face 来自 document 的 face 字段（经 core 带到 piece.attr）。
;; attr 形态：普通文本 → face（symbol | palette-color | face-stack | #f）；
;; overlay → (overlay . face)（pair）。
;; 这里只把 theme 里的 style 翻成 racket-tui 转义序列（真彩色 + 按需属性）。
(define (rgb-fg c) (if c (format-rgb-fg-base (rgb-r c) (rgb-g c) (rgb-b c)) #""))
(define (rgb-bg c) (if c (format-rgb-bg-base (rgb-r c) (rgb-g c) (rgb-b c)) #""))

(define (attr-bytes a)
  (case a
    [(bold)      format-bold]
    [(dim)       format-dim]
    [(italic)    format-italic]
    [(underline) format-underline]
    [(blink)     format-blink]
    [(reverse)   format-reverse]
    [else #""]))

(define (style-bytes st)
  (bytes-append
   (rgb-fg (style-fg st))
   (rgb-bg (style-bg st))
   (for/fold ([b #""]) ([a (in-list (style-attrs st))])
     (bytes-append b (attr-bytes a)))))

;; overlay 逐分量盖到 face 上（overlay 的 #f 分量不覆盖 face）。
(define (piece-style attr)
  (define t (current-theme))
  (style-bytes
   (cond
     [(pair? attr) (style-over (theme-style t (cdr attr)) (theme-overlay-style t (car attr)))]
     [else (theme-style t attr)])))

;;; ---------- 画一帧（增量） ----------

(define prev (box #f))
;; 上一帧的逻辑尺寸（= session width/height）；帧对象只作不透明句柄回传给 session-patch。
(define prev-size (box #f))

(define (draw! s)
  (define old (unbox prev))
  (define size (cons (session-width s) (session-height s)))
  (define fresh? (or (not old) (not (equal? size (unbox prev-size)))))
  (set-box! prev-size size)
  (define-values (s1 new rends sels) (session-render s old))
  (set-box! prev new)
  (put-bytes format-cursor-hide)
  (when fresh? (put-bytes format-screen-clear))
  (for ([p (in-list (append rends sels))])
    (put-bytes (bytes-append
                (format-cursor-move (add1 (piece-row p)) (add1 (piece-column p)))
                (piece-style (piece-attr p))
                (format-content (piece-text p))
                format-reset)))
  (flush!)
  s1)

;;; ---------- 主循环 ----------

(define (handle-event s ev)
  (define c (resolve s ev))
  (define s* (if c (step s c) s))
  (and (not (session-quit? s*)) s*))

(define (run-tui s0 #:theme [theme default-theme])
  (parameterize ([current-theme theme])
    (with-tui
     (lambda ()
       (define-values (rows cols) (get-window-size))
       (define s (struct-copy session s0
                              [width (or cols (session-width s0))]
                              [height (or rows (session-height s0))]))
       (set-box! prev #f)
       (set-box! prev-size #f)
       (let loop ([s s])
         (define s1 (draw! s))
         (cond
           ;; 有未决异步：小幅轮询重绘，结果到齐即装（read-event-noblock 不阻塞）。
           [(session-awaiting-any? s1)
            (sleep 0.02)
            (define ev (read-event-noblock))
            (cond
              [(event-null? ev) (loop s1)]
              [else (define s* (handle-event s1 ev)) (when s* (loop s*))])]
           [else
            (define s* (handle-event s1 (read-event)))
            (when s* (loop s*))]))))))
