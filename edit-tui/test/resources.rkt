#lang racket

;;; 资源管理面板：buffer / view 行、类型颜色、tab 切换、Enter 聚焦。

(require rackunit
         "../config/keymap/buffer.rkt"
         "../config/keymap/default.rkt"
         "../main.rkt")

(define area (rect 0 0 60 12))
(define engine (make-engine))

;; 两个 resource，各有一个 view
(define-values (s0 a0)
  (resource-open resource-store-empty #:name "a" #:text "A"
                 #:key-table (buffer-key-table #f "A")))
(define-values (store a1)
  (resource-open s0 #:name "b" #:text "B"
                 #:key-table (buffer-key-table #f "B")))

;; resource 面板自己的 view
(void (engine-create-buffer! engine 30 "*resources*" ""))
(void (engine-create-view! engine 30 30))

(define st0 (make-app-state #:resources store #:area area))
(define st1 (run-actions st0 engine (append a0 a1)))

(define editor-panel
  (make-panel 'editor 'editor #:views '(1) #:active 1
              #:borders '(up down left right)))
(define sidebar-panel
  (make-panel 'sidebar 'sidebar #:views '(10 30) #:active 10
              #:borders '(right)))
(define l0
  (make-layout #:root (make-leaf 'editor)
               #:panels (hash 'editor editor-panel)
               #:focus 'editor))
(define-values (l1 ok?) (layout-panel-attach l0 'editor 'left sidebar-panel))
(check-true ok?)

(define st2
  (resource-panel-install-state
   (struct-copy app-state st1 [layout l1])
   30 #:panel-stack resource-panel-stack))
;; 文件树也在这个 panel 里；手动补它的 view stack（测试不启动 filetree 插件）。
(define st3
  (struct-copy app-state st2
               [panel-stacks
                (hash-set (app-state-panel-stacks st2)
                          10 filetree-panel-stack)]))
(define st4 (app-state-set-focus-panel st3 'sidebar))

(define st5 (sync-resource-panel! st4 engine))
(define rp (hash-ref (app-state-store st5) 'resource-panel))
(define rows (resource-panel-rows rp))

(check-equal? (map resource-line-kind rows) '(buffer view buffer view))
(check-equal? (map resource-line-view-id rows) '(#f 1 #f 2))
(check-equal? (map resource-line-face rows)
              '(resource-document resource-view
                resource-document resource-view))
(check-equal? (resource-line-text (car rows)) "a")
(check-equal? (resource-line-text (cadr rows)) "  view 1")

;; 输入不变：sync 直接返回原 state
(check-eq? st5 (sync-resource-panel! st5 engine))

;; resource 版本变化：dirty buffer 换 face / 加 *
(define st5d
  (struct-copy app-state st5
               [resources (resource-mark-edited (app-state-resources st5) 1 'v2)]))
(define st5d* (sync-resource-panel! st5d engine))
(define rows-dirty (resource-panel-rows
                    (hash-ref (app-state-store st5d*) 'resource-panel)))
(check-equal? (resource-line-face (car rows-dirty)) 'resource-pending)
(check-equal? (resource-line-text (car rows-dirty)) "a *")

;; C-x b 切换 sidebar tab：filetree(10) -> resources(30)
(define-values (st6 _a6) (cycle-sidebar-view-command st5))
(check-equal? (layout-panel-active-view (app-state-layout st6) 'sidebar) 30)

;; 当前 active view 是 resource panel；Enter 应走 resource 命令表
(define-values (st7 a7) (step st6 (key-event (key 'enter))))
(check-equal? a7 '())
(check-equal? (layout-focus (app-state-layout st7)) 'editor)
(check-equal? (layout-panel-active-view (app-state-layout st7) 'editor) 1)

;; 键位表存在
(check-true (command-table-exact? resource-panel-command-table (list (key 'enter))))
(let-values ([(status _v)
              (command-table-lookup global-command-table
                                    (list (key 'x 'ctrl) (key 'b)))])
  (check-equal? status 'command))

(displayln "edit-tui-rebuild/test/resources.rkt: ok")
