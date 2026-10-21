#lang racket

;;; edit-tui-rebuild/app/buffer-mode.rkt —— buffer 创建时绑定的 mode 值（纯）
;;;
;;; mode 是创建 buffer 时一次性确定的运行环境：
;;;   id         : 'racket | 'text | ...
;;;   language   : 解析环境标识（当前是 symbol；以后可放 language service 值）
;;;   key-table  : 创建时绑定的命令表
;;;   features   : 该 buffer 支持的插件能力
;;;
;;; mode 由 config/mode.rkt 选择，存进 resource；插件只读 mode，
;;; 不再自己看扩展名 / #lang / 路径。

(provide (struct-out buffer-mode)
         buffer-mode-supports?
         buffer-mode-supports-any?)

(struct buffer-mode
  (id
   language
   key-table
   features)
  #:transparent)

(define (buffer-mode-supports? mode feature)
  (and mode
       (memq feature (buffer-mode-features mode))
       #t))

(define (buffer-mode-supports-any? mode features)
  (and mode
       (for/or ([feature (in-list features)])
         (buffer-mode-supports? mode feature))))
