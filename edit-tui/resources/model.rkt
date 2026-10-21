#lang racket

;;; edit-tui/resources/model.rkt —— 资源管理面板状态（纯）

(provide (struct-out resource-line)
         (struct-out resource-panel)
         empty-resource-panel
         make-resource-panel
         resource-panel-set-view
         resource-panel-set-cursor
         resource-panel-set-sync
         resource-panel-invalidate)

(struct resource-line (kind resource-id view-id text face) #:transparent)
;; kind        : 'buffer | 'view
;; resource-id : buffer 所属 resource
;; view-id     : kind = 'view 时的 view-id；buffer 行为 #f
;; text        : 显示文本（buffer 带缩进，view 在 buffer 下）
;; face        : 资源类型对应的 face

(struct resource-panel
  (view          ; view-id | #f
   cursor        ; 光标行镜像
   cursor-dirty? ; #t：state 推给 view；#f：view 是真相
   rows          ; (listof resource-line)
   revision      ; rows 对应的 resource-revision
   sync-key)     ; (list view revision line col)
  #:transparent)

(define (empty-resource-panel)
  (resource-panel #f 0 #t '() #f #f))

(define (make-resource-panel #:view [view #f]
                             #:cursor [cursor 0]
                             #:cursor-dirty? [cursor-dirty? #t]
                             #:rows [rows '()]
                             #:revision [revision #f]
                             #:sync-key [sync-key #f])
  (resource-panel view cursor cursor-dirty? rows revision sync-key))

(define (resource-panel-set-view rp vid)
  (struct-copy resource-panel rp [view vid]))

(define (resource-panel-set-cursor rp line)
  (struct-copy resource-panel rp [cursor line] [cursor-dirty? #t]))

(define (resource-panel-set-sync rp revision rows sync-key cursor)
  (struct-copy resource-panel rp
               [revision revision]
               [rows rows]
               [sync-key sync-key]
               [cursor cursor]
               [cursor-dirty? #f]))

(define (resource-panel-invalidate rp)
  (struct-copy resource-panel rp [revision #f] [sync-key #f]))
