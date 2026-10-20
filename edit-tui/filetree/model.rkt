#lang racket

;;; edit-tui-rebuild/filetree/model.rkt —— 文件树面板状态（纯）

(provide (struct-out filetree-line)
         (struct-out filetree)
         empty-filetree
         make-filetree
         filetree-expanded?
         filetree-toggle-expand
         filetree-set-view
         filetree-set-cursor
         filetree-set-projection
         filetree-sync-cursor
         filetree-invalidate)

(struct filetree-line (path kind depth text face) #:transparent)
;; path : string（规范化绝对路径）
;; kind : 'root | 'dir | 'file
;; depth : natural
;; text : string
;; face : symbol | #f

(struct filetree
  (view        ; view-id | #f
   cursor      ; 选中行（= core view 的 point line 的镜像）
   cursor-dirty? ; cursor 是否要由 state 推给 view（键盘移动）；#f 时以 view 为准
   expanded    ; path -> #t
   rows        ; (listof filetree-line)
   projection) ; (list root expanded opened)：rows 对应的输入
  #:transparent)

;; 文件树就是一个普通 buffer：光标（point）归 core view 所有。
;; cursor 只是它的镜像：
;;   - 键盘移动 -> state 先改 cursor 并置 dirty?，sync 把它推给 view；
;;   - 鼠标点击 -> view 的 point 已经动了，sync 直接读回来（dirty? = #f）。

(define (empty-filetree)
  (filetree #f 0 #t (hash) '() #f))

(define (make-filetree #:view [view #f]
                       #:line [line 0]
                       #:cursor-dirty? [cursor-dirty? #t]
                       #:expanded [expanded (hash)]
                       #:rows [rows '()]
                       #:projection [projection #f])
  (filetree view line cursor-dirty? expanded rows projection))

(define (filetree-expanded? f path)
  (hash-has-key? (filetree-expanded f) path))

(define (filetree-toggle-expand f path)
  (define h (filetree-expanded f))
  (struct-copy filetree f
               [expanded (if (hash-has-key? h path)
                             (hash-remove h path)
                             (hash-set h path #t))]))

(define (filetree-set-view f vid)
  (struct-copy filetree f [view vid]))

;; 键盘移动：改 cursor，并要求下一次 sync 把它推给 view。
(define (filetree-set-cursor f line)
  (struct-copy filetree f [cursor line] [cursor-dirty? #t]))

;; sync 读回（view 是真相）：只更新镜像，不要求下推。
(define (filetree-sync-cursor f line)
  (struct-copy filetree f [cursor line] [cursor-dirty? #f]))

;;; 行投影 + 它的输入一起更新（用于跨帧复用）。
(define (filetree-set-projection f projection rows)
  (struct-copy filetree f [projection projection] [rows rows]))

;; 丢弃投影缓存：下一次 sync 重新扫目录（C-r 手动刷新用）。
(define (filetree-invalidate f)
  (struct-copy filetree f [projection #f]))
