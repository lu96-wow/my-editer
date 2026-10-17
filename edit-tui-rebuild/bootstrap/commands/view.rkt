#lang racket

;;; layer  : bootstrap/commands
;;; effect : engine view 创建/销毁（open-view-effect / close-view-effect）
;;;
;;; view 生命周期命令（不涉及 document 生命周期）：
;;;   split-*          同一 document 再开一个 view，按 role 的 splittable? 判定
;;;   close-view       role 的 close-policy；'ignore 拒绝
;;;   new-document     open-doc-effect + 装进当前/空 editor region
;;;   detach-view      从 region 摘出（保留 view / engine view / document）
;;;   attach-detached  把第一个 detached view 挂回当前 region
;;;   switch-member    同一 region 内切换 active / focus（Tab / C-x C-o）
;;;                    role.switchable? = #f 时拒绝（chrome 槽：status/input 由框架控制）
;;;
;;; 焦点回退一律用 “真实文档 view”（util/real-view?），不会落到 internal 文档上。

(provide split-view-command
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

(define (split-view-command dir)
  (cmd (λ (ctx) (split-view ctx dir))))

(define (split-view ctx dir)
  (define s (ctx-state ctx))
  (define vid (view-subject ctx))
  (define ws (state-workspace s))
  (define did (and vid (workspace-doc-of-view ws vid)))
  (define reg (and vid (workspace-view-region ws vid)))
  (define role (and reg (region-role reg)))
  (cond
    [(input-busy? ctx) (message ctx "split: input active")]
    [(not (and did reg)) (message ctx "split: no view")]
    [(not (role-splittable? (environment-role (ctx-env ctx) role)))
     (message ctx "split: region not splittable")]
    [else
     (define rid (region-key reg))
     (define leaf (tree-find (workspace-layout ws) rid))
     (define borders (if leaf (leaf-borders leaf) leaf-borders-all))
     (transition s
                 (list (open-view-effect did
                                          (λ (s* nvid)
                                            (mount-split s* rid borders nvid dir)))))]))
(define (axis/side dir)
  (case dir
    [(left)  (values 'lr 'before)]
    [(right) (values 'lr 'after)]
    [(up)    (values 'tb 'before)]
    [(down)  (values 'tb 'after)]
    [else (error 'split-view "未知方向：~a" dir)]))

(define (mount-split s source-rid borders nvid dir)
  (define-values (axis side) (axis/side dir))
  (define-values (nrid s1) (state-next-id s 'region))
  (define ws (state-workspace s1))
  (define source-reg (workspace-region ws source-rid))
  (define new-reg (region nrid
                          (list (view-member nvid))
                          nvid
                          (if source-reg (region-role source-reg) 'editor)))
  (define ws* (workspace-add-region ws nrid new-reg))
  (define layout* (tree-split (workspace-layout ws*) source-rid axis nrid
                              #:side side #:borders borders))
  (define s2 (state-set-workspace s1 (struct-copy workspace ws* [layout layout*])))
  (transition-pure (state-set-focus s2 nvid)))

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
  (for/or ([m (in-list (region-members reg))]) (view-member? m)))

;; 目标 region：当前 view 所在 region；没有 view 时找第一个空的 editor region。
(define (target-region-for-new-view* s subj)
  (define ws (state-workspace s))
  (cond
    [(and (view-id? subj) (workspace-view-region ws subj))]
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
     (define vid (view-subject ctx))
     (define ws (state-workspace s))
     (define reg (and vid (workspace-view-region ws vid)))
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
