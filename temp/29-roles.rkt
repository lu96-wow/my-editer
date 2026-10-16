#lang racket

;;; 29 —— role 注册表：leaf 角色 → 行为（可 splittable / 关闭策略可配置）
;;;
;;;   racket temp/29-roles.rkt
;;;
;;; 演示：
;;;   · 内置 role：'editor（splittable, keep-last）/ 'panel（不 splittable, hide）；
;;;   · 自定义 role：'tool（splittable, delete）/ 'sidebar（不 splittable, hide）；
;;;   · split-* 只对 splittable 生效，新块**继承原 role**；
;;;   · close-focused 按 role 的 close 策略分派：hide / delete / keep-last；
;;;   · 未注册 role → 保守默认（不 splittable、hide）。

(require tui
         "../core/editor.rkt"
         "../edit-tui/command/main.rkt"
         "../edit-tui/layout/main.rkt"
         "../edit-tui/app/main.rkt")

;;; ════════════════ 自定义 role ════════════════

(define-role! 'tool    #:splittable? #t #:close 'delete)     ; 可切分，但关掉就真删
(define-role! 'sidebar #:splittable? #f #:close 'hide)       ; 固定侧栏，只隐藏

;;; ════════════════ 资源 / 布局 ════════════════

(define-doc-kind! 'text #:keymaps (list edit-keys motion-keys pointer-keys))
(define-doc-kind! 'plain #:keymaps '())

(define res (make-resources))
(define-values (b1 sv) (open-document! res "side" "side\n" #:kind 'plain))
(define-values (b2 tv) (open-document! res "tool" "tool\n" #:kind 'plain))
(define-values (b3 ev) (open-document! res "main" "(f 41)\n" #:kind 'text))

(define W 80) (define H 24)
(define (base-layout)
  (lay 'lr
       (pane 'side   #:view sv #:size 1 #:dock 'left   #:role 'sidebar)
       (lay 'tb
            (pane 'tool   #:view tv #:size 1 #:dock 'top    #:role 'tool)
            (pane 'editor #:view ev #:size 5 #:dock 'center #:role 'editor))))

(define global-keys
  (keys
   [(key 's 'ctrl) (key 'left)  (λ (ctx) (split-left ctx))]
   [(key 's 'ctrl) (key 'right) (λ (ctx) (split-right ctx))]
   [(key 's 'ctrl) (key 'up)    (λ (ctx) (split-up ctx))]
   [(key 's 'ctrl) (key 'down)  (λ (ctx) (split-down ctx))]
   [(key 's 'ctrl) (key 'd)     (λ (ctx) (close-focused ctx))]))

(define (make-app-world)
  (make-world #:area (rect 0 0 W H)
              #:layout (base-layout)
              #:focus (leaf-ref 'editor)
              #:keytable (make-keytable global-keys)))

;;; ════════════════ headless 自检 ════════════════

(define world* (box #f))
(define (plain c) (key-event c (mods #f #f #f)))
(define (ctrl c)  (key-event c (mods #t #f #f)))
(define (check label ok?) (if ok? (printf "  ✓ ~a\n" label) (error 'check "~a 失败" label)))
(define (feed! ev)
  (define-values (w _) (world-step* (unbox world*) (list ev))) (set-box! world* w))
(define (layout) (world-layout (unbox world*)))
(define (leaves) (tree-leaves (layout)))
(define (count-role r) (for/sum ([l (in-list (leaves))] #:when (eq? (leaf-role l) r)) 1))
(define (set-focus! id) (set-box! world* (struct-copy world (unbox world*) [focus (leaf-ref id)])))
(define (leaf-role-of id) (leaf-role (tree-find (layout) id)))
(define (view-of id) (leaf-view (tree-find (layout) id)))

(define (run-check!)
  (set-box! world* (make-app-world))

  (printf "内置：editor splittable=~a close=~a；panel splittable=~a close=~a\n"
          (role-splittable? (role-of 'editor)) (role-close-policy (role-of 'editor))
          (role-splittable? (role-of 'panel))  (role-close-policy (role-of 'panel)))

  (check "内置 'editor：可切分 + keep-last"
         (and (role-splittable? (role-of 'editor))
              (eq? (role-close-policy (role-of 'editor)) 'keep-last)))
  (check "内置 'panel：不可切分 + hide"
         (and (not (role-splittable? (role-of 'panel)))
              (eq? (role-close-policy (role-of 'panel)) 'hide)))
  (check "自定义 'tool 已注册" (role-known? 'tool))
  (check "未注册 role 保守默认（不切分/hide）"
         (and (not (role-splittable? (role-of 'nope))) (eq? (role-close-policy (role-of 'nope)) 'hide)))

  ;; tool：splittable，新块继承 role 'tool
  (set-focus! 'tool)
  (define nt0 (count-role 'tool))
  (feed! (ctrl 's)) (feed! (plain 'right))
  (check "tool 可切分（+1）" (= (add1 nt0) (count-role 'tool)))
  (define new-id (panel-ref-id (world-focus (unbox world*))))
  (check "新块继承 role='tool" (eq? (leaf-role-of new-id) 'tool))
  ;; tool：close='delete' → 直接删（即使只剩一块也删）
  (feed! (ctrl 's)) (feed! (plain 'd))
  (check "tool close='delete'：删掉一块" (= nt0 (count-role 'tool)))

  ;; editor：keep-last → 关到最后一律清 view 保留占位
  (set-focus! 'editor)
  (let loop () (when (> (count-role 'editor) 1) (set-focus! (leaf-id (for/first ([l (leaves)] #:when (eq? (leaf-role l) 'editor)) l)))
                   (feed! (ctrl 's)) (feed! (plain 'd)) (loop)))
  (check "editor 剩 1 块" (= 1 (count-role 'editor)))
  (feed! (ctrl 's)) (feed! (plain 'd))
  (check "editor keep-last：最后一块保留 leaf" (= 1 (count-role 'editor)))
  (check "editor keep-last：view 清空" (not (view-of 'editor)))

  ;; sidebar：不 splittable + hide
  (set-focus! 'side)
  (define n-side-leaves (length (leaves)))
  (feed! (ctrl 's)) (feed! (plain 'right))    ; 非 splittable → no-op
  (check "sidebar 不可切分（no-op）" (= n-side-leaves (length (leaves))))
  (feed! (ctrl 's)) (feed! (plain 'd))        ; close='hide' → 隐藏不删
  (check "sidebar close='hide'：leaf 不删" (= n-side-leaves (length (leaves))))
  (check "sidebar close='hide'：被隐藏" (not (tree-visible? (layout) 'side)))

  (displayln "roles demo: 自检 OK"))

(module+ main (run-check!))
