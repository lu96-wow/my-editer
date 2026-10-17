#lang racket

;;; bootstrap/resource-commands.rkt —— 资源列表面板的命令 / keymap
;;;
;;; 面板本身是 *resources* buffer view，选中项 = buffer 光标行。
;;; 命令：
;;;   tab  折叠/展开 document
;;;   v    给选中 document 新建一个 detached view
;;;   n    新建 scratch document + detached view
;;;   r    选中 view -> 进入 placement（等待用户选目标 panel）
;;;   d    把选中 view 从 panel detach（保留资源）
;;;   c    销毁选中 view（document 保留）
;;;   Esc  取消 placement
;;;
;;; placement 是显式两步：
;;;   1. 资源面板里 r；
;;;   2. 焦点移到目标 panel（鼠标/M-方向），按 C-x C-p 提交。
;;; 提交时替换目标 region 的 active view；旧 view 被 detach，不销毁。

(provide resource-keys resource-command-table
         placement-keys placement-scope)

(require "../base/id.rkt"
         "../base/effect.rkt"
         "../base/transition.rkt"
         "../base/keymap.rkt"
         "../../edit-tui/command/key.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/chrome.rkt"
         "../model/resources.rkt"
         "../effects/engine.rkt"
         "../projection/resources.rkt"
         "../env/command.rkt"
         "../env/environment.rkt"
         "../env/scope.rkt"
         "../../edit-tui/command/mouse.rkt"
         "../dispatch/context.rkt")

(define (message ctx text)
  (transition-pure
   (state-chrome* (ctx-state ctx) (λ (c) (chrome-set-message c text)))))

(define (selected-line ctx)
  (define vid (ctx-subject ctx))
  (define line (and vid (engine-view-view-point-line (ctx-engine ctx) vid)))
  (and line (resource-line-at (ctx-state ctx) line)))

(define (doc-views ws did)
  (sort (for/list ([(vid vm) (in-hash (workspace-views ws))]
                   #:when (equal? (view-meta-doc vm) did))
          vid)
        string<? #:key id->string))

(define (selected-view ctx)
  (define l (selected-line ctx))
  (cond
    [(not l) #f]
    [(resource-view-line? l) (resource-line-view l)]
    [else
     (define ws (state-workspace (ctx-state ctx)))
     (for/first ([v (in-list (doc-views ws (resource-line-doc l)))]) v)]))

(define (selected-doc ctx)
  (define l (selected-line ctx))
  (and l (resource-line-doc l)))

(define (toggle-collapse-command)
  (cmd (λ (ctx)
         (define l (selected-line ctx))
         (if (and l (resource-doc-line? l))
             (transition-pure
              (state-resources* (ctx-state ctx)
                                (λ (r) (resources-toggle-collapse r (resource-line-doc l)))))
             (message ctx "resources: select a document line")))))

;; Enter:
;;   doc line  -> 展开 / 折叠
;;   view line -> attached: 设为 active + focus（打开）
;;                detached: 进入 placement（带选择）
(define (resource-enter-command)
  (cmd (λ (ctx)
         (define l (selected-line ctx))
         (cond
           [(not l) (message ctx "resources: no line")]
           [(resource-doc-line? l)
            (transition-pure
             (state-resources* (ctx-state ctx)
                               (λ (r) (resources-toggle-collapse r (resource-line-doc l)))))]
           [else
            (define vid (resource-line-view l))
            (define s (ctx-state ctx))
            (define ws (state-workspace s))
            (if (workspace-view-attached? ws vid)
                (let* ([reg (workspace-view-region ws vid)]
                       [ws* (workspace-attach-view ws (region-key reg) vid)]
                       [s1 (state-set-focus (state-set-workspace s ws*) vid)])
                  (transition-pure
                   (state-chrome* s1 (λ (c) (chrome-set-message c "opened view")))))
                (transition-pure
                 (state-chrome*
                  (state-resources* s (λ (r) (resources-set-pending r vid)))
                  (λ (c) (chrome-set-message c "place: choose target panel")))))]))))

(define (new-view-command)
  (cmd (λ (ctx)
         (cond
           [(not (selected-doc ctx)) (message ctx "resources: no document")]
           [else
            (define did (selected-doc ctx))
            (transition (ctx-state ctx)
                        (list (open-view-effect
                               did
                               (λ (s _vid)
                                 (notice-state s "new detached view")))))]))))
(define (notice-state s text)
  (transition-pure (state-chrome* s (λ (c) (chrome-set-message c text)))))

(define (new-doc-command)
  (cmd (λ (ctx)
         (transition (ctx-state ctx)
                     (list (open-doc-effect
                            (make-open-doc-spec "*scratch*" "" #:mode 'text)
                            (λ (s _did _vid)
                              (notice-state s "new detached document/view"))))))))

(define (start-placement-command)
  (cmd (λ (ctx)
         (define vid (selected-view ctx))
         (if (not vid)
             (message ctx "resources: select a view")
             (transition-pure
              (state-chrome*
               (state-resources* (ctx-state ctx)
                                 (λ (r) (resources-set-pending r vid)))
               (λ (c) (chrome-set-message c "place: choose target panel, then C-x C-p"))))))))

(define (detach-selected-command)
  (cmd (λ (ctx)
         (define vid (selected-view ctx))
         (cond
           [(not vid) (message ctx "resources: select a view")]
           [else
            (define s (ctx-state ctx))
            (define ws (state-workspace s))
            (if (not (workspace-view-attached? ws vid))
                (message ctx "resources: view already detached")
                (transition-pure
                 (state-chrome*
                  (state-set-workspace s (workspace-detach-view ws vid))
                  (λ (c) (chrome-set-message c "detached view")))))]))))

(define (close-selected-command)
  (cmd (λ (ctx)
         (define vid (selected-view ctx))
         (if (not vid)
             (message ctx "resources: select a view")
             (transition (state-workspace*
                          (ctx-state ctx)
                          (λ (ws) (workspace-remove-view ws vid)))
                         (list (close-view-effect vid)))))))

(define (cancel-placement-command)
  (cmd (λ (ctx)
         (transition-pure
          (state-resources* (ctx-state ctx)
                            (λ (r) (resources-set-pending r #f)))))))

;; 把 pending view 放到 target（view-id / region-id）所在 region。
(define (place-into ctx target)
  (define s (ctx-state ctx))
  (define r (state-resources s))
  (define selected (resources-pending r))
  (cond
    [(not selected) (message ctx "place: no selected view")]
    [else
     (define ws (state-workspace s))
     (define target-reg
       (cond
         [(and target (view-id? target)) (workspace-view-region ws target)]
         [(and target (region-id? target)) (workspace-region ws target)]
         [else #f]))
     (cond
       [(not target-reg) (message ctx "place: choose a target panel")]
       [else
        (define target-region (workspace-region ws (region-key target-reg)))
        (define target-active (region-active target-region))
        (define target-active-view
          (and target-active (workspace-view ws target-active)))
        (define target-doc
          (and target-active-view (workspace-doc ws (view-meta-doc target-active-view))))
        (cond
          [(or (eq? (region-role target-region) 'slot)
               (and target-doc
                    (memq (doc-meta-mode target-doc) '(status state input resources))))
           (message ctx "place: target is chrome, choose an editor panel")]
          [else
           (define ws1
             (if (and target-active-view (not (equal? target-active selected)))
                 (workspace-detach-view ws target-active)
                 ws))
           (define ws2 (workspace-attach-view ws1 (region-key target-reg) selected))
           (define s1 (state-set-workspace s ws2))
           (define s2 (state-resources* s1 (λ (r) (resources-set-pending r #f))))
           (transition-pure
            (state-chrome*
             (state-set-focus s2 selected)
             (λ (c) (chrome-set-message c "view placed"))))])])]))

(define (commit-placement-command)
  (cmd (λ (ctx) (place-into ctx (state-focus (ctx-state ctx))))))

(define (place-at-command)
  (cmd (λ (ctx) (place-into ctx (ctx-subject ctx)))))

(define placement-scope
  (make-scope (λ (s) (and (resources-pending (state-resources s)) #t))))

(define placement-keys
  (keys [(mouse 'press 'left) 'resource-place-at]))

(define (nav-command dir)
  (cmd (λ (ctx)
         (define vid (ctx-subject ctx))
         (if vid
             (transition (ctx-state ctx) (list (nav-effect vid dir)))
             (message ctx "resources: no view")))))

(define resource-keys
  (keys
   [(key 'up)     'resource-up]
   [(key 'down)   'resource-down]
   [(key 'home)   'resource-home]
   [(key 'end)    'resource-end]
   [(key 'enter)  'resource-enter]
   [(key 'tab)    'resource-toggle]
   [(key 'v)      'resource-new-view]
   [(key 'n)      'resource-new-doc]
   [(key 'r)      'resource-place]
   [(key 'd)      'resource-detach]
   [(key 'c)      'resource-close]
   [(key 'escape) 'resource-cancel]))

(define (resource-command-table)
  (hash 'resource-up    (nav-command 'up)
        'resource-down  (nav-command 'down)
        'resource-home  (nav-command 'home)
        'resource-end   (nav-command 'end)
        'resource-enter (resource-enter-command)
        'resource-toggle (toggle-collapse-command)
        'resource-new-view (new-view-command)
        'resource-new-doc (new-doc-command)
        'resource-place (start-placement-command)
        'resource-detach (detach-selected-command)
        'resource-close (close-selected-command)
        'resource-cancel (cancel-placement-command)
        'resource-place-commit (commit-placement-command)
        'resource-place-at (place-at-command)))
