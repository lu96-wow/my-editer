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
         filetree-set-opened
         filetree-set-show-hidden
         filetree-toggle-hidden
         filetree-set-hidden-filter
         filetree-set-sync
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
   projection  ; (list root expanded opened)：rows 对应的输入
   sync-key    ; (list view projection-key line col)：上一帧已写进 view 的完整输入
   opened      ; path -> #t：resource 打开路径集合的缓存
   opened-revision ; opened 对应的 resource-opened-revision
   show-hidden?    ; 是否显示以 . 开头的条目
   hidden-entry?)  ; path -> boolean | #f：额外的隐藏过滤规则（#f = 用默认规则）
  #:transparent)

;; 文件树就是一个普通 buffer：光标（point）归 core view 所有。
;; cursor 只是它的镜像：
;;   - 键盘移动 -> state 先改 cursor 并置 dirty?，sync 把它推给 view；
;;   - 鼠标点击 -> view 的 point 已经动了，sync 直接读回来（dirty? = #f）。

(define (empty-filetree)
  (filetree #f 0 #t (hash) '() #f #f (hash) 0 #f #f))

(define (make-filetree #:view [view #f]
                       #:line [line 0]
                       #:cursor-dirty? [cursor-dirty? #t]
                       #:expanded [expanded (hash)]
                       #:rows [rows '()]
                       #:projection [projection #f]
                       #:sync-key [sync-key #f]
                       #:opened [opened (hash)]
                       #:opened-revision [opened-revision 0]
                       #:show-hidden? [show-hidden? #f]
                       #:hidden-entry? [hidden-entry? #f])
  (filetree view line cursor-dirty? expanded rows projection sync-key
            opened opened-revision show-hidden? hidden-entry?))

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

;;; opened 集合缓存：resource 打开路径版本没变就复用。
(define (filetree-set-opened f opened opened-revision)
  (struct-copy filetree f
               [opened opened]
               [opened-revision opened-revision]))

;;; 显 / 隐 . 开头条目；状态变化会让 rows / sync-key 失效。
(define (filetree-set-show-hidden f show?)
  (struct-copy filetree f
               [show-hidden? (and show? #t)]
               [projection #f]
               [sync-key #f]))

(define (filetree-toggle-hidden f)
  (filetree-set-show-hidden f (not (filetree-show-hidden? f))))

;;; 额外的隐藏过滤规则。传 #f 恢复默认规则。
(define (filetree-set-hidden-filter f hidden-entry?)
  (struct-copy filetree f
               [hidden-entry? hidden-entry?]
               [projection #f]
               [sync-key #f]))

;;; sync 完成：记录“这一帧到底把什么写进了 view”。
;;; projection / rows 可能来自缓存；sync-key 用完成后的实际光标。
(define (filetree-set-sync f projection rows sync-key cursor)
  (struct-copy filetree f
               [projection projection]
               [rows rows]
               [sync-key sync-key]
               [cursor cursor]
               [cursor-dirty? #f]))

;; 丢弃投影缓存：下一次 sync 重新扫目录（C-r 手动刷新用）。
(define (filetree-invalidate f)
  (struct-copy filetree f [projection #f] [sync-key #f]))
