#lang racket

;;; model/workspace.rkt —— 文档 / 视图 / 区域 / 布局 / 焦点（纯数据）
;;;
;;; 这里只放 id 和元数据，不放 core 的 buffer / view 句柄：
;;;
;;;   docs    : doc-id  -> doc-meta
;;;   views   : view-id -> view-meta
;;;   regions : region-id -> region
;;;   layout  : tree<region-id>（几何在 model/layout.rkt）
;;;   overlays: (listof overlay)（浮窗层；先留字段，后续块实现）
;;;   focus   : view-id | #f
;;;   stack   : (listof view-id)   焦点历史（返回时用）
;;;
;;; doc-meta 是**文档级**元数据：path / mode / dirty / 保存版本 / per-doc 键表层。
;;; view-meta 是**显示级**元数据：它显示哪个 doc、自己的选项。一个 doc 可有多个 view。
;;;
;;; region 是“一块位置里可切换的成员”：
;;;   · editor 区域：members = 若干 view-member；
;;;   · 状态栏/输入栏：members = chrome-member 'status / 'input；
;;;   · active 决定当前显示哪个成员。
;;; 几何（size / visible?）在 layout 的 leaf 上，不在 region 上，避免两处真相。

(require "layout.rkt")

(provide (struct-out doc-meta)
         (struct-out view-meta)
         (struct-out member)
         (struct-out region)
         (struct-out workspace)
         make-doc-meta
         view-member chrome-member
         view-member? chrome-member? member-key
         make-workspace
         workspace-empty
         workspace-doc workspace-view workspace-region
         workspace-add-doc workspace-add-view workspace-add-region
         workspace-remove-doc
         workspace-remove-view
         workspace-remove-region
         workspace-detach-view
         workspace-attach-view
         workspace-view-attached?
         workspace-detached-views
         workspace-doc-of-view
         workspace-view-region
         workspace-region-members
         workspace-region-active
         workspace-region-views
         workspace-set-focus workspace-set-focus* workspace-pop-focus
         workspace-focus-view)

;;; ---------- 元数据 ----------

(struct doc-meta (name path mode saved-version keymap-layers) #:transparent)
;; name          : string（展示 / 状态栏）
;; path          : string | #f（内存文档无路径）
;; mode          : symbol（原 doc-kind；决定默认命令表）
;; saved-version : any/c（引擎版本标记；#f = 未保存过 / 新文档）
;; keymap-layers : (listof keymap)（per-doc 覆盖层，优先于 mode 默认表）

(define (make-doc-meta name
                       #:path [path #f]
                       #:mode [mode 'text]
                       #:saved-version [saved-version #f]
                       #:keymap-layers [keymap-layers '()])
  (doc-meta name path mode saved-version keymap-layers))

(struct view-meta (doc options) #:transparent)
;; doc     : doc-id
;; options : hash（行号 / 只读 / 未来 per-view 配置）

;;; ---------- 成员 / 区域 ----------

(struct member (kind key) #:transparent)
;; kind : 'view | 'chrome
;; key  : view-id | symbol

(define (view-member v)   (member 'view v))
(define (chrome-member k) (member 'chrome k))
(define (view-member? m)  (and (member? m) (eq? (member-kind m) 'view)))
(define (chrome-member? m)(and (member? m) (eq? (member-kind m) 'chrome)))
(struct region (key members active role) #:transparent)
;; key          : region-id
;; members      : (listof member)
;; active       : member key（当前显示）
;; role         : symbol（role 注册表的键；行为由 env/role 查表，不存这里）
;;                如 'editor / 'panel / 'slot；focusable? 由 role 行为决定。

;;; ---------- workspace ----------

(struct workspace (docs views regions layout overlays focus stack) #:transparent)
;; docs    : (hash/c doc-id doc-meta)
;; views   : (hash/c view-id view-meta)
;; regions : (hash/c region-id region)
;; layout  : node（model/layout.rkt；可以没有叶子）
;; overlays: (listof overlay)（暂定）
;; focus   : view-id | #f
;; stack   : (listof view-id)

(define (workspace-empty)
  (workspace (hash) (hash) (hash) (empty-tree) '() #f '()))

;; 允许调用方只覆盖部分字段；其余保持空。
(define (make-workspace #:docs [docs (hash)]
                        #:views [views (hash)]
                        #:regions [regions (hash)]
                        #:layout [layout (empty-tree)]
                        #:overlays [overlays '()]
                        #:focus [focus #f]
                        #:stack [stack '()])
  (workspace docs views regions layout overlays focus stack))

;;; ---------- 查 ----------

(define (workspace-doc w id)    (hash-ref (workspace-docs w) id #f))
(define (workspace-view w id)   (hash-ref (workspace-views w) id #f))
(define (workspace-region w id) (hash-ref (workspace-regions w) id #f))

(define (workspace-doc-of-view w vid)
  (define v (workspace-view w vid))
  (and v (view-meta-doc v)))

(define (workspace-view-region w vid)
  (for/first ([r (in-hash-values (workspace-regions w))]
              #:when (for/or ([m (in-list (region-members r))])
                       (and (view-member? m) (equal? (member-key m) vid))))
    r))

(define (workspace-region-members w rid)
  (define r (workspace-region w rid))
  (and r (region-members r)))

(define (workspace-region-active w rid)
  (define r (workspace-region w rid))
  (and r (region-active r)))

(define (workspace-region-views w rid)
  (for/list ([m (in-list (or (workspace-region-members w rid) '()))]
             #:when (view-member? m))
    (member-key m)))

;;; ---------- 增 / 删 ----------

(define (workspace-add-doc w did meta)
  (struct-copy workspace w [docs (hash-set (workspace-docs w) did meta)]))

(define (workspace-add-view w vid meta)
  (struct-copy workspace w [views (hash-set (workspace-views w) vid meta)]))

(define (workspace-add-region w rid r)
  (struct-copy workspace w [regions (hash-set (workspace-regions w) rid r)]))

;;; ---------- view ↔ region 成员关系 ----------

;; 把 vid 从所有 region 的 members 移除；active 落在剩余第一个成员。
(define (remove-view-from-regions w vid)
  (for/fold ([w w])
            ([(rid r) (in-hash (workspace-regions w))])
    (define members* (filter (λ (m) (not (and (view-member? m)
                                                (equal? (member-key m) vid))))
                             (region-members r)))
    (define active*
      (if (equal? (region-active r) vid)
          (and (pair? members*) (member-key (car members*)))
          (region-active r)))
    (workspace-add-region w rid
                          (struct-copy region r
                                       [members members*]
                                       [active active*]))))

;; 仅摘掉成员关系：view / view-meta / engine view 都保留。
(define (workspace-detach-view w vid)
  (remove-view-from-regions w vid))

;; 挂到指定 region：先确保单成员关系，再把它设为 active。
(define (workspace-attach-view w rid vid)
  (define reg (workspace-region w rid))
  (cond
    [(or (not reg) (not (workspace-view w vid))) w]
    [else
     (define w1 (remove-view-from-regions w vid))
     (define reg1 (workspace-region w1 rid))
     (define members (region-members reg1))
     (define members*
       (if (for/or ([m (in-list members)])
             (and (view-member? m) (equal? (member-key m) vid)))
           members
           (append members (list (view-member vid)))))
     (workspace-add-region w1 rid
                           (struct-copy region reg1
                                        [members members*]
                                        [active vid]))]))

(define (workspace-view-attached? w vid)
  (and (workspace-view-region w vid) #t))

(define (workspace-detached-views w)
  (sort (for/list ([(vid vm) (in-hash (workspace-views w))]
                   #:unless (workspace-view-attached? w vid))
          vid)
        string<? #:key (λ (v) (~v v))))

;; 移除一个 view：清 views 表、所有 region 的成员 / active、焦点 / 栈。
;;; 空 region 暂留（后续 region ops 可剪枝）；layout 只引用 region，不直接引用 view。
(define (workspace-remove-view w vid)
  (define (drop-member m)
    (not (and (view-member? m) (equal? (member-key m) vid))))
  (define regions*
    (for/hash ([(rid r) (in-hash (workspace-regions w))])
      (define members* (filter drop-member (region-members r)))
      (define active* (if (equal? (region-active r) vid)
                          (and (pair? members*) (member-key (car members*)))
                          (region-active r)))
      (values rid (struct-copy region r [members members*] [active active*]))))
  (struct-copy workspace w
               [views (hash-remove (workspace-views w) vid)]
               [regions regions*]
               [focus (and (workspace-focus w)
                           (not (equal? (workspace-focus w) vid))
                           (workspace-focus w))]
               [stack (for/list ([x (in-list (workspace-stack w))]
                                 #:unless (equal? x vid))
                        x)]))

;; 移除一个 region：清 regions 表 + 把它从 layout 里摘掉。
;; view / 其它 region 的处理由调用方决定（close-region 命令会先清 view）。
(define (workspace-remove-region w rid)
  (struct-copy workspace w
               [regions (hash-remove (workspace-regions w) rid)]
               [layout (tree-close (workspace-layout w) rid)]))

;; 关闭文档：移除 doc + 它所有 view（含 region 成员 / 焦点）。
(define (workspace-remove-doc w did)
  (define doomed
    (for/list ([(vid vm) (in-hash (workspace-views w))]
               #:when (equal? (view-meta-doc vm) did))
      vid))
  (define w1 (struct-copy workspace w [docs (hash-remove (workspace-docs w) did)]))
  (for/fold ([w w1]) ([vid (in-list doomed)])
    (workspace-remove-view w vid)))

;;; ---------- 焦点 ----------

(define (workspace-focus-view w) (workspace-focus w))

;; 普通切焦点：旧焦点进栈。
(define (workspace-set-focus w vid)
  (define old (workspace-focus w))
  (struct-copy workspace w
               [focus vid]
               [stack (if (and old (not (equal? old vid)))
                          (cons old (workspace-stack w))
                          (workspace-stack w))]))

;; 指定是否压栈（恢复焦点时不希望再污染历史）。
(define (workspace-set-focus* w vid #:push? [push? #t])
  (if push?
      (workspace-set-focus w vid)
      (struct-copy workspace w [focus vid])))

;; 回退到上一个焦点；栈空 -> #f。
(define (workspace-pop-focus w)
  (define st (workspace-stack w))
  (if (null? st)
      (struct-copy workspace w [focus #f])
      (struct-copy workspace w
                   [focus (car st)]
                   [stack (cdr st)])))
