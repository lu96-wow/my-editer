#lang racket

;;; layer  : bootstrap/commands
;;; effect : 只有 close-view 会销毁 engine view（close-view-effect）；
;;;          新建 document / 打开文件发 open-doc-effect
;;;
;;; region / view 生命周期命令（不涉及 document 生命周期）：
;;;   split-*          **拆出一个空 region**（不带 document / view），按 role 的
;;;                    splittable? 判定；焦点移到新 region，之后 C-n / 打开文件就装进去
;;;   close-view       role 的 close-policy；'ignore 拒绝
;;;   new-document     open-doc-effect + 装进当前/空 editor region
;;;   detach-view      从 region 摘出（保留 view / engine view / document）
;;;   attach-detached  把第一个 detached view 挂回当前 region
;;;   switch-member    同一 region 内切换 active / focus（Tab / C-x C-o）
;;;                    role.switchable? = #f 时拒绝（chrome 槽：status/input 由框架控制）
;;;
;;; 焦点回退一律用 “真实文档 view”（util/real-view?），不会落到 internal 文档上。

(provide split-region-command
         close-view-command
         new-document-command
         detach-view-command
         attach-detached-command
         switch-member-command
         target-region-for-new-view
         target-region-for-new-view*
         mount-view-in-region)

(require "../../base/id.rkt"
         "../../base/transition.rkt"
         "../../base/effect.rkt"
         "../../model/state.rkt"
         "../../model/workspace.rkt"
         "../../model/layout.rkt"
         "../../env/command.rkt"
         "../../env/environment.rkt"
         "../../env/role.rkt"
         "../../effects/engine.rkt"
         "../../dispatch/context.rkt"
         "util.rkt")

;;; ════════════════ 切分 / 关闭 ════════════════

(define (split-region-command dir)
  (cmd (λ (ctx) (split-region ctx dir))))

;; 拆出一个**空** region：不复制 document，也不再给同一 document 加 view。
;;
;;   原 region 不动（成员 / active / 焦点内容都保留）；
;;   新 region 的 members = '()，焦点移到这个空 region（focus = region-id）。
;;
;; 新 region 的 role 跟随源 region；边框跟随源叶子；尺寸由 layout 的 split 决定。
;; 之后在新 region 里 C-n / 打开文件 / 文件树 Enter 就会把文档装进去。
(define (split-region ctx dir)
  (define s (ctx-state ctx))
  (define ws (state-workspace s))
  (define reg (region-subject ctx))
  (define role (and reg (region-role reg)))
  (cond
    [(input-busy? ctx) (message ctx "split: input active")]
    [(not reg) (message ctx "split: no region")]
    [(not (role-splittable? (environment-role (ctx-env ctx) role)))
     (message ctx "split: region not splittable")]
    [else
     (define rid (region-key reg))
     (define leaf (tree-find (workspace-layout ws) rid))
     (define borders (if leaf (leaf-borders leaf) leaf-borders-all))
     (mount-split ctx s rid borders dir)]))
(define (axis/side dir)
  (case dir
    [(left)  (values 'lr 'before)]
    [(right) (values 'lr 'after)]
    [(up)    (values 'tb 'before)]
    [(down)  (values 'tb 'after)]
    [else (error 'split-view "未知方向：~a" dir)]))

(define (mount-split ctx s source-rid borders dir)
  (define-values (axis side) (axis/side dir))
  (define-values (nrid s1) (state-next-id s 'region))
  (define ws (state-workspace s1))
  ;; tree-split 的第二个值就是“target 在不在树里”：不在就**不能**继续
  ;; （以前会静默返回原树，于是 region 已登记但布局里没有 → 不可见的死状态）。
  (define-values (layout* ok?)
    (tree-split (workspace-layout ws) source-rid axis nrid
                #:side side #:borders borders))
  (cond
    [(not ok?) (message ctx "split: source region has no layout leaf")]
    [else
     (define source-reg (workspace-region ws source-rid))
     (define new-reg (region nrid
                             '()                  ; 空窗口：没有成员
                             #f
                             (if source-reg (region-role source-reg) 'editor)))
     (define ws* (workspace-add-region ws nrid new-reg))
     (define s2 (state-set-workspace s1 (struct-copy workspace ws* [layout layout*])))
     ;; 焦点移到空 region：下一次 C-n / 打开文件就落在它里面。
     (transition-pure (state-set-focus s2 nrid))]))

(define (close-view-command)
  (cmd (λ (ctx) (close-view ctx))))

(define (close-view ctx)
  (define s (ctx-state ctx))
  (define vid (view-subject ctx))
  (define ws (state-workspace s))
  (define reg (and vid (workspace-view-region ws vid)))
  (define role (and reg (region-role reg)))
  (define policy (if role (role-close-policy (environment-role (ctx-env ctx) role)) 'ignore))
  (cond
    [(not vid) (message ctx "close: no view")]
    [(eq? policy 'ignore) (message ctx "close: region ignores close")]
    [else
     (define source-rid (and reg (region-key reg)))
     (define ws* (workspace-remove-view ws vid))
     ;; 优先同 region 里的其它真实 document view，其次任意 attached 真实 view。
     (define fallback
       (or (and source-rid
                (for/first ([v (in-list (workspace-region-views ws* source-rid))]
                            #:when (let ([vm (workspace-view ws* v)])
                                     (and vm (real-view? ws* vm))))
                  v))
           (fallback-attached-view ws*)))
     (define ws** (workspace-set-focus* ws* fallback #:push? #f))
     (transition (state-set-workspace s ws**)
                 (list (close-view-effect vid)))]))

;;; ════════════════ 新建 view / document ════════════════

(define (region-has-view? reg)
  (for/or ([m (in-list (region-members reg))]) (view-region-member? m)))

;; 目标 region：subject 指向的 region（view 所在 / region-id 本身）；
;; 都没有时找第一个空的 editor region（例如刚拆出来的窗口）。
(define (target-region-for-new-view* s subj)
  (define ws (state-workspace s))
  (cond
    [(view-id? subj) (workspace-view-region ws subj)]
    [(region-id? subj) (workspace-region ws subj)]
    [else
     (for/first ([r (in-hash-values (workspace-regions ws))]
                 #:when (and (eq? (region-role r) 'editor)
                             (not (region-has-view? r))))
       r)]))

(define (target-region-for-new-view ctx)
  (target-region-for-new-view* (ctx-state ctx) (ctx-subject ctx)))

(define (mount-view-in-region s rid vid)
  (define ws (state-workspace s))
  (cond
    [(not (workspace-region ws rid)) (transition-pure s)]
    [else
     (define ws* (workspace-attach-view ws rid vid))
     (transition-pure (state-set-focus (state-set-workspace s ws*) vid))]))

(define (new-document-command)
  (cmd (λ (ctx)
         (define s (ctx-state ctx))
         (define target (target-region-for-new-view ctx))
         (cond
           [(input-busy? ctx) (message ctx "new: input active")]
           [(not target) (message ctx "new: no editor region")]
           [else
            (transition
             s
             (list (open-doc-effect
                    (make-open-doc-spec "*scratch*" "")
                    (λ (s* _did vid)
                      (mount-view-in-region s* (region-key target) vid)))))]))))

;;; ════════════════ detach / attach view（资源层，不关 view） ════════════════

;; 把当前 view 从 panel 里拿出来，但保留 view + engine view + document。
(define (detach-view-command)
  (cmd (λ (ctx)
         (cond
           [(input-busy? ctx) (message ctx "detach: input active")]
           [else
            (define s (ctx-state ctx))
            (define vid (view-subject ctx))
            (cond
              [(not vid) (message ctx "detach: no view")]
              [else
               (define ws (state-workspace s))
               (define ws* (workspace-detach-view ws vid))
               (define focus* (fallback-attached-view ws* vid))
               (define ws** (workspace-set-focus* ws* focus* #:push? #f))
               (transition-pure (state-set-workspace s ws**))])]))))

;; 把第一个 detached view 挂到当前 region（演示 / 临时入口）。
(define (attach-detached-command)
  (cmd (λ (ctx)
         (cond
           [(input-busy? ctx) (message ctx "attach: input active")]
           [else
            (define s (ctx-state ctx))
            (define ws (state-workspace s))
            (define detached (workspace-detached-views ws))
            (define fallback-region
              (or (and (state-focus s)
                       (workspace-view-region ws (state-focus s)))
                  (for/first ([r (in-hash-values (workspace-regions ws))]
                              #:when (eq? (region-role r) 'editor))
                    r)))
            (cond
              [(null? detached) (message ctx "attach: no detached view")]
              [(not fallback-region) (message ctx "attach: no region")]
              [else
               (define vid (car detached))
               (define ws* (workspace-attach-view ws (region-key fallback-region) vid))
               (transition-pure (state-set-focus (state-set-workspace s ws*) vid))])]))))

;; 在同一 region 的多个成员之间循环 active / focus。
;;
;; 这是“文件树 / 资源列表共用一个面板位置”的切换动作：两个面板是同一 region 的
;; 两个 view，Tab 把 active 挪到下一个成员并聚焦它。
;;
;; 拒绝条件：
;;   · 输入栏占用时（输入是模态的）；
;;   · role.switchable? = #f（'slot：status / input 的切换由框架驱动，
;;     不能靠用户按 Tab 把状态栏换成输入栏）；
;;   · region 只有一个成员。
(define (switch-member-command)
  (cmd
   (λ (ctx)
     (define s (ctx-state ctx))
     (define ws (state-workspace s))
     (define reg (region-subject ctx))
     (cond
       [(input-busy? ctx)
        (message ctx "switch: input active")]
       [(not reg)
        (message ctx "switch: no region")]
       [(not (role-switchable? (environment-role (ctx-env ctx) (region-role reg))))
        (message ctx "switch: this panel is not switchable")]
       [else
        (define vids (workspace-region-views ws (region-key reg)))
        (cond
          [(< (length vids) 2)
           (message ctx "switch: single member")]
          [else
           (define active (region-active reg))
           (define idx (index-of vids active))
           (define next (list-ref vids (modulo (add1 (or idx -1)) (length vids))))
           (define ws* (workspace-attach-view ws (region-key reg) next))
           (transition-pure (state-set-focus (state-set-workspace s ws*) next))])]))))
