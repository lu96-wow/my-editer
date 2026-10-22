#lang racket

;;; edit-tui-rebuild/config/mode.rkt —— 具体 buffer mode 表
;;;
;;; 这是“创建 buffer 时选哪个环境”的唯一配置点：
;;;   · 扩展名 / 无 path 的 #lang -> mode；
;;;   · mode 同时给出 key table 和 feature 集。
;;;
;;; 判定只在 buffer 创建 / save-as rebind 时发生一次；插件读 resource.mode。

(require "../app/buffer-mode.rkt"
         "../lang/racket/base/racket.rkt"
         "keymap/default.rkt")

(provide racket-mode
         text-mode
         buffer-mode-for-creation
         buffer-key-table
         racket-buffer-key-table
         text-buffer-key-table)

(define racket-buffer-key-table racket-edit-command-table)
(define text-buffer-key-table edit-command-table)

(define racket-mode
  (buffer-mode 'racket
               'racket
               racket-buffer-key-table
               '(syntax word-color brackets completion docs auto-pair indent)))

(define text-mode
  (buffer-mode 'text
               #f
               text-buffer-key-table
               '()))

;; 路径优先：
;;   · 有 path：只看扩展名；.txt 即使内容像 Racket 也不是 Racket mode；
;;   · 没有 path：用 #lang 判断 scratch buffer。
(define (buffer-mode-for-creation path text)
  (cond
    [(racket-file? path) racket-mode]
    [(and (not path) (racket-text? text)) racket-mode]
    [else text-mode]))

;; 兼容旧调用：key table 现在由同一个 mode 决定。
(define (buffer-key-table path text)
  (buffer-mode-key-table (buffer-mode-for-creation path text)))
