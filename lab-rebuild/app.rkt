#lang racket

(require racket/string
         racket/file
         racket/path
         "../core/editor.rkt"
         "input.rkt"
         "command.rkt"
         "dispatch.rkt"
         "input-doc.rkt"
         "mode.rkt"
         "tree.rkt"
         "buffers.rkt"
         "layout/main.rkt")

;;; lab-rebuild/app.rkt —— 应用状态 + 逻辑（第一版，能跑）
;;;
;;; 左：文件树；右：当前文件；底：state / input 共享槽位。
;;; 命令走 command-set：global = 焦点 + 编辑 + app；各 did 挂树 / 输入 / 确认的表。
;;; 输入转移状态见 mode.rkt（续延回传值）。

(provide (struct-out app)
         app-init app-prepare! app-render app-state-refresh! app-handle-input app-editor app-focus
         app-layout-result app-quit?)

;;; ================= 状态 =================

(struct app
  (ed                    ; core editor 值
   tree                  ; file-tree 模型
   tree-vid tree-did
   bufs-vid bufs-did bufs-model   ; 文档/视图管理面板
   edit-vid
   sidebar-width
   left                  ; 左侧显示哪个面板：'tree | 'bufs
   focus                 ; 当前焦点 vid
   mode                  ; #f | prompt
   slot                  ; 底部槽位（state/input vid）
   cs                    ; command-set
   paths by-path         ; did <-> 规范化路径
   width height
   prev                  ; 上一帧 screen
   quit?)
  #:mutable #:transparent)

(struct ctx (editor panes width height state) #:transparent)

(define (app-editor a) (app-ed a))
(define (main-w a) (max 1 (- (app-width a) (app-sidebar-width a))))
(define (main-h a) (max 1 (- (app-height a) 1)))
(define (bottom-vid a) (mode-bottom-vid (app-mode a) (app-slot a)))
(define (app-left-vid a) (if (eq? (app-left a) 'tree) (app-tree-vid a) (app-bufs-vid a)))

;; buffers 列表要排除的内部文档（树 / 自己 / 底部槽位）。
(define (app-bufs-exclude a)
  (define ed (app-ed a))
  (list (app-tree-did a) (app-bufs-did a)
        (editor-view-document-id ed (slot-state-vid (app-slot a)))
        (editor-view-document-id ed (slot-input-vid (app-slot a)))))

(define (app-path-of a did) (hash-ref (app-paths a) did #f))

(define (focused-did a)
  (define vid (app-focus a))
  (and vid (editor-view-document-id (app-ed a) vid)))

(define (app-layout-result a)
  (define ev (app-edit-vid a))
  (compute-layout (and ev (leaf ev)) (app-width a) (app-height a)
                  #:sidebar? #t
                  #:sidebar-width (app-sidebar-width a)
                  #:statusbar-height 1
                  #:left-vid (app-left-vid a)
                  #:bottom-vid (bottom-vid a)))

;; 焦点移动只看主区 + 左栏；底部槽位不参与方向移动。
(define (app-focus-panes a)
  (define b (bottom-vid a))
  (for/list ([r (in-list (layout-result-panes (app-layout-result a)))]
             #:unless (eqv? (rectangle-view-id r) b))
    r))

(define (app-ctx a)
  (ctx (app-ed a) (app-focus-panes a) (app-width a) (app-height a) a))

;;; ================= 编辑助手 =================

(define (focused ctx) (app-focus (ctx-state ctx)))
(define (ed* ctx) (app-ed (ctx-state ctx)))

(define (ev-text e)
  (cond [(key-event? e) (string (key-event-key e))]
        [(paste-event? e) (paste-event-text e)]
        [else ""]))

(define (do-insert e ctx)
  (editor-view-insert! (ed* ctx) (focused ctx) (ev-text e)))
(define (do-nav ctx f [extend? #f])
  (f (ed* ctx) (focused ctx) extend?))

(define edit-keys
  (command-table
   text-binding        (lambda (e ctx) (do-insert e ctx))
   (key 'enter)        (lambda (e ctx) (editor-view-insert! (ed* ctx) (focused ctx) "\n"))
   (key 'tab)          (lambda (e ctx) (editor-view-insert! (ed* ctx) (focused ctx) "\t"))
   (key 'backspace)    (lambda (e ctx) (editor-view-backspace! (ed* ctx) (focused ctx)))
   (key 'delete)       (lambda (e ctx) (editor-view-delete! (ed* ctx) (focused ctx)))
   (key 'left)         (lambda (e ctx) (do-nav ctx editor-view-left!))
   (key 'right)        (lambda (e ctx) (do-nav ctx editor-view-right!))
   (key 'up)           (lambda (e ctx) (do-nav ctx editor-view-up!))
   (key 'down)         (lambda (e ctx) (do-nav ctx editor-view-down!))
   (key 'home)         (lambda (e ctx) (do-nav ctx editor-view-home!))
   (key 'end)          (lambda (e ctx) (do-nav ctx editor-view-end!))
   (key 'left 'shift)  (lambda (e ctx) (do-nav ctx editor-view-left! #t))
   (key 'right 'shift) (lambda (e ctx) (do-nav ctx editor-view-right! #t))
   (key 'up 'shift)    (lambda (e ctx) (do-nav ctx editor-view-up! #t))
   (key 'down 'shift)  (lambda (e ctx) (do-nav ctx editor-view-down! #t))
   (key 'home 'shift)  (lambda (e ctx) (do-nav ctx editor-view-home! #t))
   (key 'end 'shift)   (lambda (e ctx) (do-nav ctx editor-view-end! #t))
   (key 'a 'ctrl)      (lambda (e ctx) (editor-view-select-all! (ed* ctx) (focused ctx)))
   (key 'c 'ctrl)      (lambda (e ctx) (editor-view-copy! (ed* ctx) (focused ctx)))
   (key 'x 'ctrl)      (lambda (e ctx) (editor-view-cut! (ed* ctx) (focused ctx)))
   (key 'v 'ctrl)      (lambda (e ctx) (editor-view-paste! (ed* ctx) (focused ctx)))
   (key 'z 'ctrl)      (lambda (e ctx) (editor-view-undo! (ed* ctx) (focused ctx)))
   (key 'y 'ctrl)      (lambda (e ctx) (editor-view-redo! (ed* ctx) (focused ctx)))))

(define (move-focus dir)
  (lambda (e ctx)
    (define a (ctx-state ctx))
    (define vid (pane-dir (ctx-panes ctx) (app-focus a) dir))
    (when vid (set-app-focus! a vid))))

(define focus-keys
  (command-table
   (key 'left 'ctrl)  (move-focus 'left)
   (key 'right 'ctrl) (move-focus 'right)
   (key 'up 'ctrl)    (move-focus 'up)
   (key 'down 'ctrl)  (move-focus 'down)))

(define app-keys
  (command-table
   (key 'q 'ctrl) (lambda (e ctx) (set-app-quit?! (ctx-state ctx) #t))
   (key 'o 'ctrl) (lambda (e ctx) (app-toggle-focus! (ctx-state ctx)))
   (key 's 'ctrl) (lambda (e ctx) (app-save! (ctx-state ctx)))))

;;; ================= 只读面板 =================

(define readonly-keys
  (command-table
   text-binding          (lambda (e ctx) (void))
   (key 'enter)          (lambda (e ctx) (void))
   (key 'tab)            (lambda (e ctx) (void))
   (key 'backspace)      (lambda (e ctx) (void))
   (key 'delete)         (lambda (e ctx) (void))
   (key 'v 'ctrl)        (lambda (e ctx) (void))
   (key 'x 'ctrl)        (lambda (e ctx) (void))
   (key 'z 'ctrl)        (lambda (e ctx) (void))
   (key 'y 'ctrl)        (lambda (e ctx) (void))))

;;; ================= 文件树命令 =================

(define tree-keys
  (command-merge
   (list readonly-keys
         (command-table
          (key 'tab)       (lambda (e ctx) (app-toggle-left! (ctx-state ctx)))
          (key 'enter)     (lambda (e ctx) (app-tree-activate! (ctx-state ctx)))
          (key 'n 'ctrl)   (lambda (e ctx) (app-tree-new-file! (ctx-state ctx)))
          (key 'm 'ctrl)   (lambda (e ctx) (app-tree-new-dir! (ctx-state ctx)))
          (key 'backspace) (lambda (e ctx) (app-tree-delete! (ctx-state ctx)))))))

;;; ================= 文档 / 视图管理命令 =================

(define bufs-keys
  (command-merge
   (list readonly-keys
         (command-table
          (key 'tab)   (lambda (e ctx) (app-toggle-left! (ctx-state ctx)))
          (key 'enter) (lambda (e ctx) (app-bufs-activate! (ctx-state ctx)))))))

;;; ================= 输入 / 确认槽位命令 =================
;;
;; 输入型：enter 提交、escape 取消；字符 / 退格落全局 edit-keys（写输入文档）。
;; 确认型：整行只读（readonly-keys），y / n 走 text-binding（无修饰字符）。

(define input-edit-keys
  (command-table
   (key 'enter)  (lambda (e ctx) (app-commit! (ctx-state ctx)))
   (key 'escape) (lambda (e ctx) (app-cancel! (ctx-state ctx)))
   (key 'tab)    (lambda (e ctx) (void))))

(define (confirm-text e ctx)
  (define k (and (key-event? e) (key-event-key e)))
  (cond [(eqv? k #\y) (app-answer! (ctx-state ctx) #t)]
        [(eqv? k #\n) (app-answer! (ctx-state ctx) #f)]
        [else (void)]))

(define confirm-keys
  (command-merge
   (list readonly-keys
         (command-table
          text-binding  confirm-text
          (key 'escape) (lambda (e ctx) (app-cancel! (ctx-state ctx)))))))

;;; ================= 初始化 =================

(define (app-init root width height #:sidebar-width [sw default-sidebar-width])
  (define tree (file-tree root))
  (define mw (max 1 (- width sw)))
  (define ed0 (make-blank-editor))                               ; 不预开 *scratch*，开文件才有内容
  (define-values (ed1 tdid tvid)
    (editor-add-document-view ed0 (tree->document tree) sw height "*tree*"))
  (define bmodel (buffers))
  (define-values (ed2 bdid bvid)
    (editor-add-document-view ed1 (buffers->document ed1 bmodel #f #:exclude (list tdid))
                              sw height "*buffers*"))
  (define-values (ed3 stdid stvid)
    (editor-add-document-view ed2 (state->document "") mw 1 "*state*"))
  (define-values (ed4 indid invid)
    (editor-add-document-view ed3 (input->document (input "" #t)) mw 1 "*input*"))
  (define bslot (slot stvid invid))
  (define cs (command-set-add-doc
              (command-set-add-doc
               (command-set-add-doc
                (command-set-add-doc
                 (command-set (list focus-keys edit-keys app-keys))
                 tdid tree-keys)
                bdid bufs-keys)
               indid input-edit-keys)
              stdid readonly-keys))
  (define a (app ed4 tree tvid tdid bvid bdid bmodel #f sw 'tree tvid #f bslot cs
                 (make-hash) (make-hash) width height #f #f))
  (app-bufs-refresh! a)
  a)

;;; ================= 渲染 =================

(define (pad-right s n)
  (define len (string-length s))
  (if (>= len n) (substring s 0 n) (string-append s (make-string (- n len) #\space))))

;; 焦点所在的 pane。
(define (focus-label a vid)
  (cond [(eqv? vid (app-tree-vid a)) "tree"]
        [(eqv? vid (app-bufs-vid a)) "buffers"]
        [else "edit"]))

;; 状态栏：焦点 + 行:列 + 该 view 对应 document 的文件名。
(define (state-line a)
  (define vid (app-focus a))
  (define ed (app-ed a))
  (cond
    [(not vid) ""]
    [else
     (define did (editor-view-document-id ed vid))
     (format "~a  ~a:~a  ~a"
             (focus-label a vid)
             (add1 (editor-view-point-line ed vid))
             (add1 (editor-view-point-column ed vid))
             (editor-document-name ed did))]))

(define (app-state-refresh! a)
  (unless (app-mode a)
    (define ed (app-ed a))
    (define vid (slot-state-vid (app-slot a)))
    (define s (pad-right (state-line a) (main-w a)))
    (unless (equal? s (editor-view-string ed vid))
      (editor-view-assign! ed vid (state->document s)))))

(define (app-render a)
  (editor-render-layout*! (app-ed a)
                          (app-prepare! a)
                          (app-focus a) (app-width a) (app-height a)))

;; 每帧渲染前统一入口：刷新底部 state 槽位 → 返回本帧窗格。
;; tui.rkt 的增量渲染也必须走这里（否则 state 文档永远是空的）。
(define (app-prepare! a)
  (app-state-refresh! a)
  (layout-result-panes (app-layout-result a)))

;;; ================= 焦点 =================

(define (app-toggle-focus! a)
  (define ev (app-edit-vid a))
  (when ev
    (set-app-focus! a (if (memv (app-focus a) (list (app-tree-vid a) (app-bufs-vid a)))
                          ev
                          (app-left-vid a)))))

;; 左侧面板：文件树 ↔ 文档列表。
(define (app-toggle-left! a)
  (set-app-left! a (if (eq? (app-left a) 'tree) 'bufs 'tree))
  (app-bufs-refresh! a)
  (set-app-focus! a (app-left-vid a)))

;;; ================= 文件树 =================

(define (basename p)
  (path->string (file-name-from-path (simplify-path p))))

(define (app-tree-refresh! a)
  (tree-refresh! (app-ed a) (app-tree-vid a) (app-tree a)
                 #:open? (lambda (p) (and (hash-ref (app-by-path a) (simplify-path p) #f) #t))))

(define (app-tree-entry-at-focus a)
  (tree-line->entry (app-tree a)
                    (editor-view-point-line (app-ed a) (app-tree-vid a))))

(define (app-tree-activate! a)
  (define e (app-tree-entry-at-focus a))
  (cond [(not e) (void)]
        [(entry-dir? e) (file-tree-toggle! (app-tree a) (entry-path e)) (app-tree-refresh! a)]
        [else (app-open-path! a (entry-path e))]))

(define (app-tree-expand! a)
  (define e (app-tree-entry-at-focus a))
  (when (and e (entry-dir? e)) (file-tree-expand! (app-tree a) (entry-path e)) (app-tree-refresh! a)))

(define (app-tree-collapse! a)
  (define e (app-tree-entry-at-focus a))
  (when (and e (entry-dir? e)) (file-tree-collapse! (app-tree a) (entry-path e)) (app-tree-refresh! a)))

(define (app-open-path! a path)
  (define np (simplify-path (path->complete-path path)))
  (define did
    (or (hash-ref (app-by-path a) np #f)
        (let-values ([(ed2 d2) (editor-add-document (app-ed a)
                                                    (if (file-exists? np) (file->string np) "")
                                                    (basename np))])
          (set-app-ed! a ed2)
          (hash-set! (app-paths a) d2 np)
          (hash-set! (app-by-path a) np d2)
          d2)))
  (app-tree-refresh! a)
  (app-show-document! a did #f))

;;; ---------- 文档列表 ----------

;; 模型 → 左栏文档列表视图。
(define (app-bufs-refresh! a)
  (buffers-refresh! (app-ed a) (app-bufs-vid a) (app-bufs-model a) (app-edit-vid a)
                    #:exclude (app-bufs-exclude a)
                    #:path-of (lambda (did) (app-path-of a did))))

;; 把某个 view 显示到编辑格（view 是持久对象，旧 view 不关）。
;; focus? = #f 时只换编辑格内容，不动焦点（文件树打开文件的默认行为）。
(define (app-show-view! a vid [focus? #t])
  (set-app-edit-vid! a vid)
  (when focus? (set-app-focus! a vid))
  (app-bufs-refresh! a))

;; 把某个 did 显示到编辑格（复用它的第一个视图，没有再建）。
(define (app-show-document! a did [focus? #t])
  (define vids (editor-document-view-list (app-ed a) did))
  (define vid (if (pair? vids) (car vids)
                  (let-values ([(ed2 v2) (editor-add-view (app-ed a) did (main-w a) (main-h a)
                                                          #:line-numbers? #t)])
                    (set-app-ed! a ed2) v2)))
  (app-show-view! a vid focus?))

;;; ---------- 删除磁盘路径时同步关文档 ----------

;; base 是 p 的祖先（或相等）；用于删目录时连带子文件。
(define (path-under? base p)
  (define b (explode-path (simplify-path base)))
  (define q (explode-path (simplify-path p)))
  (and (>= (length q) (length b))
       (equal? b (take q (length b)))))

;; 已打开文档里挑一个 view 给编辑格（不新建 view）。
(define (app-pick-edit-vid a)
  (for/or ([did (in-list (editor-document-id-list (app-ed a)))]
           #:unless (memv did (app-bufs-exclude a)))
    (define vids (editor-document-view-list (app-ed a) did))
    (and (pair? vids) (car vids))))

;; 路径被删 → 同步关掉它（及子路径）对应的文档 / 视图。
;; 如果编辑格正显示被关的文档，改显下一个还开着的 view（没有就空）。
(define (app-close-path! a path)
  (define np (simplify-path (path->complete-path path)))
  (define ed (app-ed a))
  (define closed
    (for/list ([(did p) (in-hash (app-paths a))] #:when (path-under? np p)) did))
  (when (pair? closed)
    (define old-edit (app-edit-vid a))
    (define edit-did (and old-edit (editor-view-document-id ed old-edit)))
    (for ([did (in-list closed)])
      (set-app-ed! a (editor-close-document (app-ed a) did))
      (hash-remove! (app-by-path a) (hash-ref (app-paths a) did))
      (hash-remove! (app-paths a) did))
    (when (and edit-did (memv edit-did closed))
      (set-app-edit-vid! a (app-pick-edit-vid a))
      (when (eqv? (app-focus a) old-edit)
        (set-app-focus! a (app-left-vid a))))
    (app-bufs-refresh! a)))

(define (app-bufs-activate! a)
  (define line (editor-view-point-line (app-ed a) (app-bufs-vid a)))
  (define row (buffers-line->row (app-ed a) (app-bufs-model a) line
                                 #:exclude (app-bufs-exclude a)
                                 #:path-of (lambda (did) (app-path-of a did))))
  (case (and row (buffer-row-kind row))
    [(doc)  (buffers-toggle! (app-bufs-model a) (buffer-row-did row)) (app-bufs-refresh! a)]
    [(view) (app-show-view! a (buffer-row-vid row))]
    [else (void)]))

(define (app-save! a)
  (define did (focused-did a))
  (define p (and did (hash-ref (app-paths a) did #f)))
  (when p
    (call-with-output-file p #:exists 'replace
      (lambda (out) (display (editor-document-string (app-ed a) did) out)))))

;;; ================= 输入转移（续延回传） =================

;; 输入文档的 did（state / input 共用底部，命令表随 prompt 类型换）。
(define (app-input-did a)
  (editor-view-document-id (app-ed a) (slot-input-vid (app-slot a))))

(define (app-set-input-keys! a editable?)
  (set-app-cs! a (command-set-set-doc (app-cs a) (app-input-did a)
                                      (if editable? (list input-edit-keys) (list confirm-keys)))))

(define (app-begin! a label editable? on-commit [on-cancel #f])
  (define p (input-begin label editable? (app-focus a) on-commit on-cancel))
  (app-set-input-keys! a editable?)
  (set-app-mode! a p)
  (define vid (mode-focus-vid p (app-slot a)))
  (editor-view-assign! (app-ed a) vid (prompt-document p ""))
  (editor-view-set-point! (app-ed a) vid (point 0 (string-length label)))
  (set-app-focus! a vid))

(define (app-commit! a)
  (define p (app-mode a))
  (when (and p (prompt-editable? p))
    (define vid (mode-focus-vid p (app-slot a)))
    (define s (editor-view-string (app-ed a) vid))
    (set-app-mode! a #f)
    (app-set-input-keys! a #t)
    (set-app-focus! a (prompt-prev-focus p))
    (input-commit p s)))

(define (app-answer! a yes?)
  (define p (app-mode a))
  (when p
    (set-app-mode! a #f)
    (app-set-input-keys! a #t)
    (set-app-focus! a (prompt-prev-focus p))
    (input-answer p yes?)))

(define (app-cancel! a)
  (define p (app-mode a))
  (when p
    (set-app-mode! a #f)
    (app-set-input-keys! a #t)
    (set-app-focus! a (prompt-prev-focus p))
    (input-cancel p)))

(define (app-target-dir a)
  (define e (app-tree-entry-at-focus a))
  (cond [(not e) (file-tree-root (app-tree a))]
        [(entry-dir? e) (entry-path e)]
        [else (let-values ([(base _name _dir?) (split-path (entry-path e))]) base)]))

(define (app-tree-new-file! a)
  (define target (app-target-dir a))
  (app-begin! a "new file: " #t
              (lambda (name)
                (when (and (positive? (string-length name)) (tree-create-file! target name))
                  (file-tree-expand! (app-tree a) target)
                  (app-tree-refresh! a)))))

(define (app-tree-new-dir! a)
  (define target (app-target-dir a))
  (app-begin! a "new folder: " #t
              (lambda (name)
                (when (and (positive? (string-length name)) (tree-create-dir! target name))
                  (file-tree-expand! (app-tree a) target)
                  (app-tree-refresh! a)))))

(define (app-tree-delete! a)
  (define e (app-tree-entry-at-focus a))
  (when e
    (define p (entry-path e))
    (app-begin! a (format "delete ~a? (y/n)" (entry-name e)) #f
                (lambda (yes?)
                  (when yes?
                    (tree-delete-path! p)
                    (app-close-path! a p)
                    (app-tree-refresh! a))))))

;;; ================= 鼠标 =================

;; 鼠标落点 → 视图内坐标 → 落光标。
(define (app-move-point-to-mouse a rect ev)
  (define vid (rectangle-view-id rect))
  (define-values (line col)
    (editor-view-screen-position->point (app-ed a) vid
                                        (- (mouse-row ev) (rectangle-y rect))
                                        (- (mouse-col ev) (rectangle-x rect))))
  (when line (editor-view-set-point! (app-ed a) vid (point line col))))

(define (app-handle-mouse a ev)
  (define p (pane-at (layout-result-panes (app-layout-result a))
                     (mouse-col ev) (mouse-row ev)))
  (cond
    ;; 输入激活：点输入行 → 定位光标；其它任何**按下** → 取消输入。
    [(app-mode a)
     (define input-vid (mode-focus-vid (app-mode a) (app-slot a)))
     (cond
       [(and p (eqv? (rectangle-view-id p) input-vid))
        (when (eq? (mouse-event-action ev) 'press) (app-move-point-to-mouse a p ev))]
       [(eq? (mouse-event-action ev) 'press) (app-cancel! a)]
       [else (void)])]
    ;; 正常模式：按下 / 滚轮 → 聚焦并作用；空闲状态栏不是交互区。
    [else
     (when p
       (define vid (rectangle-view-id p))
       (unless (eqv? vid (slot-state-vid (app-slot a)))
         (set-app-focus! a vid)
         (case (mouse-event-action ev)
           [(scroll) (editor-view-scroll! (app-ed a) vid
                                          (if (eq? (mouse-event-button ev) 'up) -1 1))]
           [(press)  (app-move-point-to-mouse a p ev)]
           [else (void)])))]))

;;; ================= 输入 =================

(define (app-handle-input a ev)
  (cond
    [(or (null-event? ev) (other-event? ev)) (void)]
    [(resize-event? ev)
     (set-app-width! a (max 20 (resize-event-cols ev)))
     (set-app-height! a (max 5 (resize-event-rows ev)))
     (set-app-prev! a #f)]
    [(mouse-event? ev) (app-handle-mouse a ev)]
    [else
     (dispatch-run (app-cs a) (focused-did a) ev (app-ctx a))])
  ;; 模态：焦点一旦离开输入 / 确认视图 → 取消。
  (when (and (app-mode a)
             (not (eqv? (app-focus a) (mode-focus-vid (app-mode a) (app-slot a)))))
    (app-cancel! a)))
