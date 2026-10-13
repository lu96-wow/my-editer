#lang racket

;;; edit4/plugins/sync/plugin.rkt —— 双文档映射同步插件包
;;;
;;; C-o 前缀：C-o o 打开/新建焦点文档的翻译文档；C-o i 把焦点窗与下一个编辑器窗配对；C-o p 解除配对。
;;; 编辑任一侧 → 钩子即时 transform → 写另一侧（内存文档、不进 undo）。
;;; decor：光标所在映射词高亮（配合光标同步 =「对应词高亮」）。

(provide sync-plugin)

(require "../../plugin.rkt"
         "../../core/command.rkt" "../../core/hook.rkt"
         "sync.rkt" "mark.rkt")

(define sync-plugin
  (make-plugin
   #:name 'sync
   #:commands sync-commands
   #:keymap (list (list '(key o ctrl) 'always (cmd 'prefix 'sync))
                  (list '(text "o") '(prefix sync) (cmd 'sync-open))
                  (list '(text "i") '(prefix sync) (cmd 'sync-link 'focus 'next))
                  (list '(text "p") '(prefix sync) (cmd 'sync-unlink))
                  (list '(key escape) '(prefix sync) (cmd 'cancel)))
   #:decor (list sync-mark-decor)
   #:hooks sync-hooks))
