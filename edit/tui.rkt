#lang racket

;;; edit/tui.rkt —— racket-tui 输入 / 输出后端
;;;
;;; 输入：read-event -> resolve（panel 键表 ⊕ 文档键表 ⊕ 全局）-> step（纯）-> session
;;; 输出：session-refresh（刷新状态窗口）-> core 合成 -> pieces -> format-* 字节
;;;
;;; 只有本模块碰终端 / FFI；session / layout / focus 保持纯。

(require tui
         "command/command.rkt"
         "command/session.rkt"
         "command/binding.rkt"
         "core/keymap.rkt"
         "theme/theme.rkt"
         "theme/style.rkt"
         "../core/view/base/screen.rkt"
         "../core/view/patch.rkt")

(provide resolve render-pieces piece-style draw! run-tui)

;;; ---------- 输入：event -> cmd ----------

(define (spec->cmd spec ev)
  (cond [(prefix? spec) (cmd-prefix spec)]
        [(eq? spec text-spec) (cmd-insert (or (event-text ev) ""))]
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
     (define vid (session-focus-vid s))
     (define did (session-focused-did s))
     (define kms (append (filter values
                                 (list (and vid (session-vid-keys s vid))
                                       (and did (session-doc-keys s did))))
                         (session-keys s)))
     (and b
          (for/or ([km (in-list kms)])
            (define spec (keymap-lookup km b))
            (and spec (spec->cmd spec ev))))]))

;;; ---------- 输出：session -> pieces ----------

;; 一帧的全部 piece（render + selection）。old = #f 表示全量。
(define (render-pieces s [old #f])
  (session-refresh s)
  (define-values (_new rends sels) (session-patch s old))
  (append rends sels))

;; piece 的外观：face 来自 document 的 face 字段（经 core 带到 piece.attr）。
;; attr 形态：普通文本 → face（symbol | #f）；overlay → (overlay . face)。
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

;; overlay 逐分量盖到 face 上（overlay 的 #f 分量不覆盖 face），属性叠加。
(define (merge-style f o)
  (cond
    [(not o) f]
    [else (style (or (style-fg o) (style-fg f))
                 (or (style-bg o) (style-bg f))
                 (append (style-attrs f) (style-attrs o)))]))

(define (piece-style attr)
  (define t (current-theme))
  (cond
    [(symbol? attr) (style-bytes (theme-style t attr))]
    [(not (pair? attr)) (style-bytes (theme-style t #f))]
    [else (style-bytes (merge-style (theme-style t (cdr attr))
                                    (theme-overlay-style t (car attr))))]))

;;; ---------- 画一帧（增量） ----------

(define prev (box #f))

(define (draw! s)
  (session-refresh s)
  (define old (unbox prev))
  (define-values (new rends sels) (session-patch s old))
  (define fresh? (or (not old)
                     (not (= (screen-width old) (screen-width new)))
                     (not (= (screen-height old) (screen-height new)))))
  (set-box! prev new)
  (put-bytes format-cursor-hide)
  (when fresh? (put-bytes format-screen-clear))
  (for ([p (in-list (append rends sels))])
    (put-bytes (bytes-append
                (format-cursor-move (add1 (piece-row p)) (add1 (piece-column p)))
                (piece-style (piece-attr p))
                (format-content (piece-text p))
                format-reset)))
  (flush!))

;;; ---------- 主循环 ----------

(define (run-tui s0 #:theme [theme default-theme])
  (parameterize ([current-theme theme])
    (with-tui
     (lambda ()
       (define-values (rows cols) (get-window-size))
       (define s (struct-copy session s0
                              [width (or cols (session-width s0))]
                              [height (or rows (session-height s0))]))
       (set-box! prev #f)
       (let loop ([s s])
         (draw! s)
         (define ev (read-event))
         (define c (resolve s ev))
         (define s* (if c (step s c) s))
         (unless (session-quit? s*) (loop s*)))))))
