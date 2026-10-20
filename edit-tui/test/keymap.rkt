#lang racket

;;; 键位配置：所有表都从 config/keymap/default.rkt 来。
(require rackunit
         "../main.rkt"
         "../config/keymap/buffer.rkt"
         "../config/keymap/default.rkt")

(check-true (keymap? default-keymap))
(check-equal? (command-table-stack-tables (keymap-overlays default-keymap))
              (list global-command-table))
;; buffer 创建时按 path/text 匹配键表
(check-equal? (buffer-key-table "a.rkt" "") edit-command-table)
(check-equal? (buffer-key-table #f "#lang racket\n") edit-command-table)
(check-equal? (buffer-key-table #f "hello") edit-command-table)

(check-equal? (keymap-input-stack default-keymap)
              input-command-stack)
(check-equal? (keymap-placement-table default-keymap)
              placement-table)

;; navigation / edit / filetree / input / placement 的关键绑定都在
(check-true (command-table-exact? navigation-command-table (list (key 'left))))
(check-true (command-table-exact? edit-command-table (list (key 'enter))))
(check-true (command-table-exact? filetree-command-table (list (key 'enter))))
(check-true (command-table-exact? input-command-table (list (key 'escape))))
(check-true (command-table-exact? placement-table (list (key 'escape))))

;; 全局键在 keymap 的 overlays 里，而不是散落在 demo
(check-true (command-table-exact? global-command-table
                                  (list (key 'q 'ctrl))))

(displayln "edit-tui-rebuild/test/keymap.rkt: ok")
