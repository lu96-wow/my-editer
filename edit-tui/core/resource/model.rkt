#lang racket

;;; edit-tui-rebuild/resource/model.rkt —— 资源管理（纯状态 + action 数据）
;;;
;;; resource = buffer/document + views + path + command-stack + version。
;;;
;;; 唯一分支：
;;;   path 存在   -> 可以落文件
;;;   path = #f   -> 不能落文件，保存前必须先拿 path
;;;
;;; dirty:
;;;   version != saved-version
;;;
;;; 本模块不读文件、不写文件、不碰 engine。
;;; 它只产生 action 数据：
;;;   create-buffer / create-view / write-file / close-resource / quit
;;; IO / engine 由上层解释。
;;;
;;; 输入面板只通过：
;;;   resource-prompt
;;;   resource-submit
;;;   resource-cancel
;;; 与本模块交互。

(require racket/path
         "../command/table.rkt")

(provide (struct-out resource)
         (struct-out resource-store)
         (struct-out resource-action)
         (struct-out prompt)
         (struct-out pending)

         resource-store-empty
         resource-ref
         resource-list

         resource-open
         resource-save
         resource-save-as
         resource-save-done
         resource-mark-edited
         resource-sync-version
         resource-reset-version

         resource-request-close
         resource-request-quit
         resource-prompt
         resource-submit
         resource-submit-text
         resource-cancel

         resource-path
         resource-dirty?
         resource-writable?
         resource-view-ids
         resource-of-view
         resource-command-stack
         resource-set-command-stack
         resource-normalize-path
         resource-find-by-path
         resource-root
         resource-set-root
         resource-display-path
         resource-opened-revision)

;;; ════════════════ 数据 ════════════════

(struct resource
  (id name doc-id views file-path binding-stack version saved-version)
  #:transparent)
;; views : (listof view-id)
;; path  : string | #f
;; version / saved-version : any/c（通常是 engine 的 opaque version token）

(struct resource-store
  (root resources order pending prompt view-index opened-revision
   next-resource-id next-view-id next-prompt-id)
  #:transparent)
;; root            : string（启动根路径；规范化绝对路径，"" = 未设置）
;; resources       : id -> resource
;; order           : (listof resource-id)
;; pending         : pending | #f
;; prompt          : prompt | #f
;; view-index      : view-id -> resource-id（resource-of-view 的 O(1) 索引）
;; opened-revision : 打开路径集合的版本；成员 / path 变化才 +1

(struct resource-action (kind data) #:transparent)
;; kind : 'create-buffer | 'create-view | 'write-file
;;      | 'close-resource | 'quit

(struct prompt (id kind resource-id label value choices) #:transparent)
;; kind : 'save-path | 'confirm
;; choices : (listof symbol)

(struct pending (kind ids index mode) #:transparent)
;; kind : 'quit | 'close
;; ids  : (listof resource-id)
;; mode : 'ask | 'save-all

(define resource-store-empty
  (resource-store "" (hash) '() #f #f (hash) 0 1 1 1))

;;; ════════════════ 内部 store 操作 ════════════════

(define (store-get r id) (hash-ref (resource-store-resources r) id #f))

;;; view-index 的增量维护。
;;; 一个 view 只属于一个 resource；更新 resource 时先摘掉它旧的 view，
;;; 再写入新的 view。这样 resource-of-view 不需要扫描 resources。
(define (index-remove-views idx id vids)
  (for/fold ([idx idx]) ([vid (in-list vids)])
    (if (equal? (hash-ref idx vid #f) id)
        (hash-remove idx vid)
        idx)))

(define (index-add-views idx id vids)
  (for/fold ([idx idx]) ([vid (in-list vids)])
    (hash-set idx vid id)))

(define (store-put r res)
  (define id (resource-id res))
  (define old (store-get r id))
  (define idx
    (index-add-views
     (if old
         (index-remove-views (resource-store-view-index r) id (resource-views old))
         (resource-store-view-index r))
     id
     (resource-views res)))
  ;; 只有“打开路径集合”可能变化时才推进版本；版本更新 / 命令表更新不推进。
  (define path-changed?
    (not (equal? (and old (resource-file-path old))
                 (resource-file-path res))))
  (struct-copy resource-store r
               [resources (hash-set (resource-store-resources r) id res)]
               [order (if (memv id (resource-store-order r))
                          (resource-store-order r)
                          (append (resource-store-order r) (list id)))]
               [view-index idx]
               [opened-revision (if path-changed?
                                    (add1 (resource-store-opened-revision r))
                                    (resource-store-opened-revision r))]))

(define (store-remove r id)
  (define old (store-get r id))
  (struct-copy resource-store r
               [resources (hash-remove (resource-store-resources r) id)]
               [order (for/list ([x (in-list (resource-store-order r))]
                                 #:unless (equal? x id))
                        x)]
               [view-index (if old
                               (index-remove-views (resource-store-view-index r)
                                                   id (resource-views old))
                               (resource-store-view-index r))]
               [opened-revision (if (and old (resource-file-path old))
                                    (add1 (resource-store-opened-revision r))
                                    (resource-store-opened-revision r))]))

(define (store-set-prompt r p)
  (struct-copy resource-store r [prompt p]))

(define (store-clear-prompt r)
  (struct-copy resource-store r [prompt #f]))

(define (store-set-pending r p)
  (struct-copy resource-store r [pending p]))

(define (store-clear-pending r)
  (struct-copy resource-store r [pending #f]))

(define (next-prompt-id r)
  (resource-store-next-prompt-id r))

(define (bump-prompt-id r)
  (struct-copy resource-store r
               [next-prompt-id (add1 (resource-store-next-prompt-id r))]))

(define (action kind data) (resource-action kind data))

;;; ════════════════ 读 ════════════════

(define (resource-ref store id) (store-get store id))

(define (resource-list store)
  (for/list ([id (in-list (resource-store-order store))])
    (store-get store id)))

(define (resource-path store id)
  (define r (resource-ref store id))
  (and r (resource-file-path r)))

(define (resource-dirty? store id)
  (define r (resource-ref store id))
  (and r (not (eq? (resource-version r) (resource-saved-version r)))))

(define (resource-writable? store id)
  (and (resource-path store id) #t))

(define (resource-view-ids store id)
  (define r (resource-ref store id))
  (if r (resource-views r) '()))

;;; view -> resource 的唯一查询边界：O(1) 索引 + 存在性检查。
(define (resource-of-view store vid)
  (define id (hash-ref (resource-store-view-index store) vid #f))
  (and id (hash-has-key? (resource-store-resources store) id) id))

(define (resource-command-stack store id)
  (define r (resource-ref store id))
  (and r (resource-binding-stack r)))

(define (resource-set-command-stack store id stack)
  (define r (resource-ref store id))
  (cond
    [(not r) store]
    [else
     (store-put store (struct-copy resource r [binding-stack stack]))]))

;;; ════════════════ 打开 ════════════════

;; → (values store' (listof resource-action))
(define (resource-open store
                       #:name [name #f]
                       #:path [path #f]
                       #:text [text ""]
                       #:key-table key-table
                       #:version [version 0]
                       #:doc-id [doc-id #f])
  (define rid (resource-store-next-resource-id store))
  (define vid (resource-store-next-view-id store))
  (define did (or doc-id rid))
  ;; path 统一存规范化绝对路径，供 status / 提示 / 写文件直接使用
  (define path* (and path (resource-normalize-path path)))
  (define name* (or name path* "*scratch*"))
  (define stack (command-table-stack-from-tables (list key-table)))
  (define r (resource rid name* did (list vid) path* stack version version))
  (define s1 (store-put store r))
  (define s2 (struct-copy resource-store s1
                          [next-resource-id (add1 rid)]
                          [next-view-id (add1 vid)]))
  (values s2
          (list (action 'create-buffer (list did name* text))
                (action 'create-view (list vid did)))))

;;; ════════════════ 版本 ════════════════

(define (resource-mark-edited store id version)
  (define r (resource-ref store id))
  (cond
    [(not r) store]
    [else (store-put store (struct-copy resource r [version version]))]))

;; engine 里的文档版本变了才记一次 edited（导航 / 滚动等不产生 dirty）。
;; runtime 每解释完一个 view-action 调它。
(define (resource-sync-version store id version)
  (define r (resource-ref store id))
  (cond
    [(not r) store]
    [(eq? (resource-version r) version) store]
    [else (resource-mark-edited store id version)]))

;; 打开完成后把 resource version / saved-version 对齐 engine 当前 token。
(define (resource-reset-version store id version)
  (define r (resource-ref store id))
  (cond
    [(not r) store]
    [else (store-put store
                     (struct-copy resource r
                                  [version version]
                                  [saved-version version]))]))

;;; ════════════════ 保存 ════════════════

;;; 保存的唯一入口：有 path 直接 write-file；没有 path 开 save-path prompt。
;;; resource-save / save-current-for-pending / resource-save-as 都走这里。
(define (start-save store id)
  (define r (resource-ref store id))
  (cond
    [(not r) (values store '())]
    [(resource-file-path r)
     (values (store-clear-prompt store)
             (list (action 'write-file (list id (resource-file-path r)))))]
    [else
     (define p (prompt (next-prompt-id store) 'save-path id
                       "Save as: " "" '()))
     (values (bump-prompt-id (store-set-prompt store p)) '())]))

;; → (values store' (listof resource-action))
(define (resource-save store id)
  (start-save store id))

(define (resource-save-as store id path)
  (define r (resource-ref store id))
  (cond
    [(not r) (values store '())]
    [else
     (define path* (resource-normalize-path path))
     (define s1 (store-put store (struct-copy resource r [file-path path*])))
     (start-save s1 id)]))

;; 保存成功后：更新 saved-version；若在 pending 流程里，继续下一项。
(define (resource-save-done store id version)
  (define r (resource-ref store id))
  (cond
    [(not r) (values store '())]
    [else
     (define s1 (store-put store
                           (struct-copy resource r [saved-version version])))
     (define p (resource-store-pending s1))
     (cond
       [(and p (equal? (pending-current-id p) id))
        (advance-pending s1)]
       [else (values s1 '())])]))

;;; ════════════════ 关闭 / 退出 ════════════════

(define (dirty-ids store)
  (for/list ([id (in-list (resource-store-order store))]
             #:when (resource-dirty? store id))
    id))

(define (pending-current-id p)
  (and p
       (let ([ids (pending-ids p)] [i (pending-index p)])
         (and (< i (length ids)) (list-ref ids i)))))

;; 确认保存的提示：有 path 就显示 path（用户要知道写哪个文件），否则显示 name。
;; choices 用规范 symbol；输入栏显示成 y/n/all/nall（见 chrome/input.rkt）。
(define (confirm-prompt store id)
  (define r (resource-ref store id))
  (define path (and r (resource-file-path r)))
  (define target (cond
                   [path (resource-display-path store path)]
                   [r (resource-name r)]
                   [else "*scratch*"]))
  (define p (prompt (next-prompt-id store) 'confirm id
                    (format "Save ~a?" target)
                    #f '(save skip save-all skip-all)))
  (bump-prompt-id (store-set-prompt store p)))

;; close-resource action 的唯一构造点。
(define (close-resource-action id r)
  (action 'close-resource
          (list id
                (and r (resource-doc-id r))
                (if r (resource-views r) '()))))

(define (finish-pending store)
  (define p (resource-store-pending store))
  (cond
    [(not p) (values (store-clear-prompt store) '())]
    [else
     (define s1 (store-clear-pending (store-clear-prompt store)))
     (case (pending-kind p)
       [(quit) (values s1
                       (list (action 'quit '())))]
       [(close)
        (define id (car (pending-ids p)))
        (values s1 (list (close-resource-action id (resource-ref store id))))]
       [else (values s1 '())])]))

(define (advance-pending store)
  (define p (resource-store-pending store))
  (cond
    [(not p) (values store '())]
    [else
     (define next (add1 (pending-index p)))
     (cond
       [(>= next (length (pending-ids p))) (finish-pending store)]
       [else
        (define p* (struct-copy pending p [index next]))
        (define s1 (store-set-pending store p*))
        (define id (pending-current-id p*))
        (cond
          [(eq? (pending-mode p*) 'save-all)
           (save-current-for-pending s1)]
          [else
           (values (confirm-prompt s1 id) '())])])]))

(define (save-current-for-pending store)
  (define p (resource-store-pending store))
  (define id (and p (pending-current-id p)))
  (cond
    [(not id) (values store '())]
    [(not (resource-ref store id)) (advance-pending store)]
    [else (start-save store id)]))

;;; 关闭 / 退出确认的唯一入口：设置 pending，再开第一项 confirm。
(define (begin-pending store kind ids)
  (define p (pending kind ids 0 'ask))
  (values (confirm-prompt (store-set-pending store p) (car ids)) '()))

;; 关闭 resource（不是关闭 panel）：resource store / engine view / document
;; 都由后续 close-resource action 删除。面板关闭见 app/close-panel-command。
(define (resource-request-close store id)
  (define r (resource-ref store id))
  (cond
    [(not r) (values store '())]
    [(resource-dirty? store id)
     (begin-pending store 'close (list id))]
    [else
     (define s1 (store-remove store id))
     (values s1 (list (close-resource-action id r)))]))

(define (resource-request-quit store)
  (define ids (dirty-ids store))
  (cond
    [(null? ids)
     (values store
             (list (action 'quit '())))]
    [else (begin-pending store 'quit ids)]))

;;; ════════════════ 输入面板交互 ════════════════
;;;
;;; 输入栏只负责「文本 + 光标」；文本 -> prompt 语义的转换 / 校验在
;;; resource-submit-text 里（按 prompt kind 分派），chrome 不再判断 kind。

(define (resource-prompt store)
  (resource-store-prompt store))

;;; prompt-id 匹配的唯一入口：所有 submit / cancel 都先过这里。
(define (active-prompt? store pid)
  (define p (resource-store-prompt store))
  (and p (equal? (prompt-id p) pid) p))

(define (resource-cancel store pid)
  (cond
    [(not (active-prompt? store pid)) store]
    [else
     (store-clear-pending (store-clear-prompt store))]))

;; 输入栏按 Enter：文本 -> 对应 prompt 的值 + 校验。
;; → (values store' actions ok?)
;;   ok? = #f 表示输入不合法，store 不变、prompt 保持打开。

;; confirm 接受 y/n/all/nall（大小写不敏感），也接受原来的
;; save / skip / save-all / skip-all / cancel 写法。
(define (confirm-answer text)
  (case (string-downcase text)
    [("y" "yes" "save") 'save]
    [("n" "no" "skip") 'skip]
    [("all" "save-all") 'save-all]
    [("nall" "skip-all") 'skip-all]
    [("cancel") 'cancel]
    [else #f]))

(define (resource-submit-text store pid text)
  (define p (active-prompt? store pid))
  (cond
    [(not p) (values store '() #f)]
    [else
     (define trimmed (string-trim text))
     (case (prompt-kind p)
       [(confirm)
        (define v (confirm-answer trimmed))
        (cond
          [(and v (or (eq? v 'cancel) (memq v (prompt-choices p))))
           (let-values ([(s a) (resource-submit store pid v)])
             (values s a #t))]
          [else (values store '() #f)])]
       [(save-path)
        (cond
          [(zero? (string-length trimmed)) (values store '() #f)]
          [else
           (let-values ([(s a) (resource-submit store pid trimmed)])
             (values s a #t))])]
       [else
        (let-values ([(s a) (resource-submit store pid text)])
          (values s a #t))])]))

(define (resource-submit store pid value)
  (define p (active-prompt? store pid))
  (cond
    [(not p) (values store '())]
    [else
     (case (prompt-kind p)
       [(save-path)
        (define id (prompt-resource-id p))
        (resource-save-as store id value)]
       [(confirm)
        (define id (prompt-resource-id p))
        (case value
          [(cancel) (values (resource-cancel store pid) '())]
          [(skip) (advance-pending (store-clear-prompt store))]
          [(skip-all) (finish-pending store)]
          [(save) (save-current-for-pending store)]
          [(save-all)
           (define pend (resource-store-pending store))
           (define s1 (if pend
                          (store-set-pending store (struct-copy pending pend [mode 'save-all]))
                          store))
           (save-current-for-pending s1)]
          [else (values store '())])]
       [else (values store '())])]))

;;; ════════════════ 路径 ════════════════

;; 路径规范化只做一次（filetree 的 expanded / opened 集合也用它当 key）。
(define (resource-normalize-path p)
  (path->string (simplify-path (path->complete-path p))))

(define (resource-root store)
  (resource-store-root store))

;; 打开路径集合（有 path 的 resource）的版本。filetree 用它决定是否重算 opened 集合。
(define (resource-opened-revision store)
  (resource-store-opened-revision store))

(define (resource-set-root store root)
  (struct-copy resource-store store
               [root (if (or (not root) (equal? root ""))
                         ""
                         (resource-normalize-path root))]))

;; 只用于显示：根内 -> 相对路径；根外 -> 绝对路径。
;; 路径数据本身仍然用绝对路径。
(define (resource-display-path store p)
  (define path* (resource-normalize-path p))
  (define root (resource-root store))
  (cond
    [(or (not root) (string=? root "")) path*]
    [else
     (define root* (resource-normalize-path root))
     (cond
       [(equal? root* path*) "."]
       [else
        (define rel (find-relative-path (string->path root*)
                                        (string->path path*)))
        (define rel-str (path->string rel))
        ;; find-relative-path 对根外路径也返回 ../...；这里按显示规则回退到绝对路径。
        (if (or (absolute-path? rel)
                (regexp-match? #rx"^\\.\\.[/\\\\]" rel-str))
            path*
            rel-str)])]))

;; 按路径找已打开的 resource（规范化后比较）。
(define (resource-find-by-path store path)
  (define pn (resource-normalize-path path))
  (for/first ([r (in-list (resource-list store))]
              #:when
              (let ([p (resource-path store (resource-id r))])
                (and p (equal? pn (resource-normalize-path p)))))
    r))
