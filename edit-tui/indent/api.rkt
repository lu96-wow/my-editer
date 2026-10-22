#lang racket

;;; edit-tui-rebuild/indent/api.rkt —— 换行缩进插件 API
;;;
;;; 命令只发 newline-indent-action；boot 读 engine 文本后调用
;;; newline-indent-insert-text，再生成普通 insert view-action。
;;; 语言算法在 lang/racket/base/indent.rkt，保持纯函数。

(require "../app/state.rkt"
         "../app/action.rkt"
         "../app/buffer-mode.rkt"
         "../edit/api.rkt"
         "../lang/racket/api.rkt")

(provide newline-indent-command
         newline-indent-insert-text)

(define (newline-indent-command state)
  (define vid (focus-editor-view state))
  (cond
    [(not vid) (values (app-state-with-flash state "indent: 焦点不是 editor") '())]
    [else (values state (list (newline-indent-action vid)))]))

;; mode 决定语言；目前只有 Racket 有缩进算法。
(define (newline-indent-insert-text mode text line col)
  (define indent
    (case (and mode (buffer-mode-language mode))
      [(racket) (racket-indent-for-newline text line col)]
      [else ""]))
  (string-append "\n" indent))
