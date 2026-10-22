#lang racket

;;; 键位配置：所有表都从 config/keymap/default.rkt 来。
(require rackunit
         "../main.rkt"
         "../config/keymap/buffer.rkt"
         "../config/keymap/default.rkt")

(check-true (keymap? default-keymap))
(check-equal? (command-table-stack-tables (keymap-overlays default-keymap))
              (list app-command-table global-command-table))
;; buffer 创建时按 path/text 匹配键表
(check-equal? (buffer-key-table "a.rkt" "") racket-edit-command-table)
(check-equal? (buffer-key-table #f "#lang racket\n") racket-edit-command-table)
(check-equal? (buffer-key-table #f "hello") edit-command-table)

(check-equal? (keymap-input-stack default-keymap)
              input-command-stack)
(check-equal? (keymap-placement-table default-keymap)
              placement-table)

;; navigation / edit / filetree / input / placement 的关键绑定都在
(check-true (command-table-exact? navigation-command-table (list (key 'left))))
(check-true (command-table-exact? edit-command-table (list (key 'enter))))
(check-true (command-table-exact? racket-edit-command-table (list (key 'enter))))
(check-true (command-table-exact? racket-edit-command-table (list (key #\())))
(check-true (command-table-exact? filetree-command-table (list (key 'enter))))
(check-true (command-table-exact? input-command-table (list (key 'escape))))
(check-true (command-table-exact? placement-table (list (key 'escape))))

;; 全局基础表：光标 / 焦点 / 布局
(check-true (command-table-exact? global-command-table (list (key 'left))))
(check-true (command-table-exact? global-command-table
                                  (list (key 'x 'ctrl) (key 'left))))
(check-true (command-table-exact? global-command-table
                                  (list (key 'w 'ctrl) (key 'left))))

;; 应用命令单独一张表
(check-true (command-table-exact? app-command-table (list (key 'q 'ctrl))))
(check-false (command-table-exact? global-command-table (list (key 'q 'ctrl))))

(displayln "edit-tui-rebuild/test/keymap.rkt: ok")

;; 局部键表优先于全局键表：local C-q 覆盖 global C-q
(define local-table
  (keys [(key 'q 'ctrl)
         (λ (state) (values (app-state-with-flash state "local") '()))]))
(define-values (s0 _a0)
  (resource-open resource-store-empty #:name "local" #:text "" #:key-table local-table))
(define view-id (car (resource-view-ids s0 1)))
(define editor-panel
  (make-panel 'editor 'editor #:views (list view-id) #:active view-id))
(define layout
  (make-layout #:root (make-leaf 'editor)
               #:panels (hash 'editor editor-panel)
               #:focus 'editor))
(define st0 (make-app-state #:layout layout #:resources s0 #:keymap default-keymap))
(define-values (st1 _acts) (step st0 (key-event (key 'q 'ctrl))))
(check-equal? (app-state-flash st1) "local")
(check-false (app-state-quit? st1))
