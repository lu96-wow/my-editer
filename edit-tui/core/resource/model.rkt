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
         resource-focus

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
         resource-display-path)

;;; ════════════════ 数据 ════════════════

(struct resource
  (id name doc-id views file-path binding-stack version saved-version)
  #:transparent)
;; views : (listof view-id)
;; path  : string | #f
;; version / saved-version : any/c（通常是 engine 的 opaque version token）

(struct resource-store
  (root resources order focus pending prompt
   next-resource-id next-view-id next-prompt-id)
  #:transparent)
;; root      : string（启动根路径；规范化绝对路径，"" = 未设置）
;; resources : id -> resource
;; order     : (listof resource-id)
;; focus     : resource-id | #f
;; pending   : pending | #f
;; prompt    : prompt | #f

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
  (resource-store "" (hash) '() #f #f #f 1 1 1))

;;; ════════════════ 内部 store 操作 ════════════════

(define (store-get r id) (hash-ref (resource-store-resources r) id #f))

(define (store-put r res)
  (struct-copy resource-store r
               [resources (hash-set (resource-store-resources r)
                                    (resource-id res) res)]
               [order (if (memv (resource-id res) (resource-store-order r))
                          (resource-store-order r)
                          (append (resource-store-order r) (list (resource-id res))))]))

(define (store-remove r id)
  (struct-copy resource-store r
               [resources (hash-remove (resource-store-resources r) id)]
               [order (for/list ([x (in-list (resource-store-order r))]
                                 #:unless (equal? x id))
                        x)]
               [focus (and (resource-store-focus r)
                           (not (equal? (resource-store-focus r) id))
                           (resource-store-focus r))]))

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

(define (resource-focus store) (resource-store-focus store))

(define (resource-path store id)
  (define r (resource-ref store id))
  (and r (resource-file-path r)))

(define (resource-dirty? store id)
  (define r (resource-ref store id))
  (and r (not (equal? (resource-version r) (resource-saved-version r)))))

(define (resource-writable? store id)
  (and (resource-path store id) #t))

(define (resource-view-ids store id)
  (define r (resource-ref store id))
  (if r (resource-views r) '()))

(define (resource-of-view store vid)
  (for/first ([id (in-list (resource-store-order store))]
              #:when (memv vid (resource-view-ids store id)))
    id))

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
                       #:doc-id [doc-id #f]
                       #:focus? [focus? #t])
  (define rid (resource-store-next-resource-id store))
  (define vid (resource-store-next-view-id store))
  (define did (or doc-id rid))
  ;; path 统一存 string（path? -> path->string），供 status / 提示直接显示
  (define path* (and path (if (path? path) (path->string path) path)))
  (define name* (or name path* "*scratch*"))
  (define stack (command-table-stack-from-tables (list key-table)))
  (define r (resource rid name* did (list vid) path* stack version version))
  (define s1 (store-put store r))
  (define s2 (struct-copy resource-store s1
                          [focus (if focus? rid (resource-store-focus s1))]
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
    [(equal? (resource-version r) version) store]
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

;; → (values store' (listof resource-action))
(define (resource-save store id)
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

(define (resource-save-as store id path)
  (define r (resource-ref store id))
  (cond
    [(not r) (values store '())]
    [else
     (define s1 (store-put store (struct-copy resource r [file-path path])))
     (resource-save s1 id)]))

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
        (define r (resource-ref store id))
        (values s1
                (list (action 'close-resource
                              (list id
                                    (and r (resource-doc-id r))
                                    (if r (resource-views r) '())))))]
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
    [else
     (define r (resource-ref store id))
     (cond
       [(not r) (advance-pending store)]
       [(resource-file-path r)
        (values (store-clear-prompt store)
                (list (action 'write-file (list id (resource-file-path r)))))]
       [else
        (define pr (prompt (next-prompt-id store) 'save-path id
                           "Save as: " "" '()))
        (values (bump-prompt-id (store-set-prompt store pr)) '())])]))

;; 关闭 resource（不是关闭 panel）：resource store / engine view / document
;; 都由后续 close-resource action 删除。面板关闭见 app/close-panel-command。
(define (resource-request-close store id)
  (define r (resource-ref store id))
  (cond
    [(not r) (values store '())]
    [(resource-dirty? store id)
     (define p (pending 'close (list id) 0 'ask))
     (values (confirm-prompt (store-set-pending store p) id) '())]
    [else
     (define s1 (store-remove store id))
     (values s1
             (list (action 'close-resource
                           (list id (resource-doc-id r) (resource-views r)))))] ))

(define (resource-request-quit store)
  (define ids (dirty-ids store))
  (cond
    [(null? ids)
     (values store
             (list (action 'quit '())))]
    [else
     (define p (pending 'quit ids 0 'ask))
     (values (confirm-prompt (store-set-pending store p) (car ids)) '())]))

;;; ════════════════ 输入面板交互 ════════════════
;;;
;;; 输入栏只负责「文本 + 光标」；文本 -> prompt 语义的转换 / 校验在
;;; resource-submit-text 里（按 prompt kind 分派），chrome 不再判断 kind。

(define (resource-prompt store)
  (resource-store-prompt store))

(define (resource-cancel store pid)
  (define p (resource-store-prompt store))
  (cond
    [(or (not p) (not (equal? (prompt-id p) pid))) store]
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
  (define p (resource-store-prompt store))
  (cond
    [(or (not p) (not (equal? (prompt-id p) pid)))
     (values store '() #f)]
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
  (define p (resource-store-prompt store))
  (cond
    [(or (not p) (not (equal? (prompt-id p) pid)))
     (values store '())]
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
