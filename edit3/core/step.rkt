#lang racket

;;; edit3/step.rkt —— 状态转移（纯）+ 应用装配 + 路由
;;;
;;;   step : State Size Event -> State + [Effect]
;;;   jobs : State -> [Job]
;;;
;;; 领域原语（打开/保存/分裂/关闭/区域/输入行/树/浮窗/指针）已抽到 core/session.rkt；
;;; 本模块只负责：键表 / op 解释器 / 路由编译 / 每步入口 / 装配。
;;; 路由分三层，按顺序：全局 → 面板（树/缓冲区）→ 编辑（焦点是编辑器时）。

(provide step boot jobs app-routes
         refresh-panels!
         input-name
         doc-keys bind-doc-keys focused-keymap apply-doc-keys add-doc-keys
         wid-vid wid-panel-name editor-wids panel-wid
         region-visible-vid region-visible? region-active
         focused-did set-focused-path!)

(require "state.rkt" "event.rkt" "effect.rkt" "route.rkt" "command.rkt" "keymap.rkt" "op.rkt"
         "adapter.rkt" "window.rkt" "layout.rkt" "panels.rkt" "interaction.rkt"
         "session.rkt" "job.rkt" "plugin.rkt" "hook.rkt" "face-plugin.rkt"
         "../plugins/catalog.rkt"
         (rename-in "../config/app.rkt"
                    [key-tables key-tables-spec]
                    [doc-key-matchers doc-key-matchers-spec])
         (rename-in "../config/plugins.rkt"
                    [enabled-plugins enabled-plugin-specs]))

;; 基础键表（未叠加插件前）。
(define base-key-table (compose-keymaps key-tables-spec))
(define (state-routes st) (feature-ref st 'routes #f))

;;; ---------- 键表作用域 ----------

(define (scope-of s)
  (define base
    (cond
      [(eq? s 'always) always]
      [(eq? s 'editor) editor-focus?]
      [(eq? s 'float)  (lambda (st ev) (and (wid-float? st (state-focus st)) #t))]
      [(eq? s 'prompt) (lambda (st ev) (and (prompt-of st) #t))]
      [(eq? s 'new)  (lambda (st ev) (eq? (prefix-of st) 'new))]
      [(eq? s 'new2) (lambda (st ev) (eq? (prefix-of st) 'new2))]
      [(eq? s 'split) (lambda (st ev) (eq? (prefix-of st) 'split))]
      [(eq? s 'placing) (lambda (st ev) (and (placing-of st) #t))]
      [(and (pair? s) (eq? (car s) 'panel)) (focus-panel? (panel-doc-name (cadr s)))]
      [(and (pair? s) (eq? (car s) 'region))
       (lambda (st ev) (and (member (wid-panel-name st (state-focus st)) (region-members* st (cadr s))) #t))]
      [else always]))
  (cond
    [(eq? s 'prompt) base]
    [else (lambda (st ev) (and (not (prompt-of st)) (base st ev)))]))

;;; ---------- op 解释器 ----------

(define base-op-registry
  (make-op-registry
   (list
    (cons 'insert            (lambda (ctx st ev args) (insert-text st (car args))))
    (cons 'insert-event-text (lambda (ctx st ev args) (insert-text st (text-event-text ev))))
    (cons 'delete-back       (lambda (ctx st ev args) (edit-focused st 'backspace)))
    (cons 'delete            (lambda (ctx st ev args) (edit-focused st 'delete)))
    (cons 'move              (lambda (ctx st ev args) (nav-focused st (car args) (and (pair? (cdr args)) (cadr args)))))
    (cons 'undo              (lambda (ctx st ev args) (edit-focused st 'undo)))
    (cons 'redo              (lambda (ctx st ev args) (edit-focused st 'redo)))
    (cons 'select-all        (lambda (ctx st ev args) (edit-focused st 'select-all)))
    (cons 'copy              (lambda (ctx st ev args) (edit-focused st 'copy)))
    (cons 'cut               (lambda (ctx st ev args) (edit-focused st 'cut)))
    (cons 'paste             (lambda (ctx st ev args) (edit-focused st 'paste)))
    (cons 'split             (lambda (ctx st ev args)
                               (let-values ([(ax first?) (split-spec (if (pair? args) (car args) 'h))])
                                 (values (split-focused st ax first?) '()))))
    (cons 'place-confirm     (lambda (ctx st ev args) (place-confirm st)))
    (cons 'place-cancel      (lambda (ctx st ev args) (place-cancel st)))
    (cons 'place-cycle       (lambda (ctx st ev args) (values (place-cycle st (car args)) '())))
    (cons 'place-pick        (lambda (ctx st ev args) (place-pick ctx st ev)))
    (cons 'close-window      (lambda (ctx st ev args) (values (close-window! st (state-focus st)) '())))
    (cons 'close-view        (lambda (ctx st ev args) (values (close-view-at-focus! st) '())))
    (cons 'close-doc         (lambda (ctx st ev args) (request-close-doc-at-focus st)))
    (cons 'save              (lambda (ctx st ev args) (save-focused st)))
    (cons 'quit              (lambda (ctx st ev args) (request-quit st)))
    (cons 'pointer           (lambda (ctx st ev args) (values (cursor-press ctx st ev) '())))
    (cons 'pointer-move      (lambda (ctx st ev args) (values (pointer-move (ctx-geometry ctx) st ev) '())))
    (cons 'pointer-release   (lambda (ctx st ev args) (values (pointer-release st ev) '())))
    (cons 'scroll            (lambda (ctx st ev args) (cursor-scroll ctx st ev (car args))))
    (cons 'region-toggle     (lambda (ctx st ev args) (values (region-toggle! st (car args)) '())))
    (cons 'region-show       (lambda (ctx st ev args) (values (region-show! st (car args)) '())))
    (cons 'region-hide       (lambda (ctx st ev args) (values (region-hide! st (car args)) '())))
    (cons 'region-activate   (lambda (ctx st ev args) (values (region-activate! st (car args) (panel-doc-name (cadr args))) '())))
    (cons 'region-cycle      (lambda (ctx st ev args) (values (region-cycle! st (car args) (cadr args)) '())))
    (cons 'region-focus      (lambda (ctx st ev args) (values (region-focus! st (car args)) '())))
    (cons 'focus             (lambda (ctx st ev args) (run-focus-op st (car args))))
    (cons 'float-open        (lambda (ctx st ev args) (values (float-open-named st (car args)) '())))
    (cons 'float-close       (lambda (ctx st ev args)
                               (define w (state-focus st))
                               (values (if (and w (wid-float? st w)) (close-float st w) st) '())))
    (cons 'float-toggle      (lambda (ctx st ev args)
                               (define name (car args))
                               (define v (view-of-name st (format "*~a*" name)))
                               (cond
                                 [(not v) (values st '())]
                                 [else
                                  (define fw (float-wid-of-vid st v))
                                  (values (if fw (close-float st fw) (float-open-named st name)) '())])))
    (cons 'float-cycle       (lambda (ctx st ev args) (values (cycle-float st) '())))
    (cons 'float-raise       (lambda (ctx st ev args)
                               (define w (state-focus st))
                               (values (if (and w (wid-float? st w)) (raise-float st w) st) '())))
    (cons 'activate          (lambda (ctx st ev args) (activate-focused st)))
    (cons 'collapse          (lambda (ctx st ev args) (tree-collapse st)))
    (cons 'tree-parent       (lambda (ctx st ev args) (tree-move-parent st)))
    (cons 'tree-child        (lambda (ctx st ev args) (tree-move-child st)))
    (cons 'tree-new-file     (lambda (ctx st ev args) (tree-new-file st)))
    (cons 'tree-new-dir      (lambda (ctx st ev args) (tree-new-dir st)))
    (cons 'tree-delete       (lambda (ctx st ev args) (tree-delete st)))
    (cons 'tree-reload       (lambda (ctx st ev args) (values (tree-reload st) '())))
    (cons 'tree-toggle-hidden (lambda (ctx st ev args) (values (tree-hidden-toggle st) '())))
    (cons 'prefix-new        (lambda (ctx st ev args) (values (prefix-new st) '())))
    (cons 'prefix-split      (lambda (ctx st ev args) (values (prefix-set st 'split) '())))
    (cons 'prefix-cancel     (lambda (ctx st ev args) (values (prefix-cancel st) '())))
    (cons 'submit-prompt     (lambda (ctx st ev args) (submit-prompt base-prompt-kinds st)))
    (cons 'cancel-prompt     (lambda (ctx st ev args) (cancel-prompt st)))
    (cons 'buffers-toggle    (lambda (ctx st ev args) (values (buffers-toggle st) '())))
    (cons 'buffers-expand    (lambda (ctx st ev args) (values (buffers-fold! st #f) '())))
    (cons 'buffers-collapse  (lambda (ctx st ev args) (values (buffers-fold! st #t) '())))
    (cons 'new-view          (lambda (ctx st ev args) (values (new-view-for-focused st) '())))
    (cons 'border-toggle     (lambda (ctx st ev args) (values (border-toggle st) '()))))))

;;; ---------- 命令序列 ----------

(define (key-seq st) (feature-ref st 'keys '()))
(define (key-seq-push st label)
  (if label (feature-set st 'keys (append (key-seq st) (list label))) st))
(define (key-seq-clear st) (feature-set st 'keys '()))
(define (prefix-enter-op? o) (memq (car o) '(prefix-new prefix-split)))

(define (placing-op-seq? ops)
  (for/or ([o (in-list ops)]) (memq (car o) '(place-confirm place-cancel place-cycle place-pick))))

(define (prefix-op-seq? ops)
  (for/or ([o (in-list ops)])
    (memq (car o) '(prefix-new prefix-split prefix-cancel tree-new-file tree-new-dir))))

(define (run-ops reg ctx st ev ops)
  (define st0
    (cond
      [(and (placing-of st) (not (placing-op-seq? ops))) (cancel-placing st)]
      [(and (prefix-of st) (not (prefix-op-seq? ops))) (prefix-cancel st)]
      [else st]))
  (define-values (st1 effs)
    (for/fold ([st st0] [effs '()]) ([o (in-list ops)])
      (define-values (st* e*) (op-run reg ctx st ev o))
      (values st* (append effs e*))))
  (values (if (and (prefix-of st1) (not (for/or ([o (in-list ops)]) (prefix-enter-op? o))))
              (prefix-cancel st1)
              st1)
          effs))

(define (op-runner reg binding ops)
  (lambda (ctx st ev k)
    (define-values (st* effs) (run-ops reg ctx (key-seq-push st (binding-label binding)) ev ops))
    (values (if (prefix-of st*) st* (key-seq-clear st*)) effs)))

;;; ---------- 路由 ----------

(define (app-routes [reg base-op-registry] [prompts base-prompt-kinds] [kt base-key-table])
  (define reg* (op-register reg 'submit-prompt (lambda (ctx st ev args) (submit-prompt prompts st))))
  (define runner (lambda (binding ops) (op-runner reg* binding ops)))
  (define global (compile-routes kt scope-of runner))
  (define doc-route
    (route (lambda (st ev) (and (focused-keymap st) #t))
           (lambda (ctx st ev k)
             (route-input/k (compile-routes (focused-keymap st) scope-of runner)
                            ctx st ev k))))
  (cons doc-route global))

;;; ---------- 后台需求 ----------

;; 待办工作由 core/job.rkt 维护（插件用 job-submit 登记）；jobs 从 State 纯取。
;; runtime 每帧调 jobs 拿待办、去重后派给 worker。

;;; ---------- 入口 ----------

(define (step st size ev)
  (cond
    [(resize-event? ev) (values st '())]
    [(job-event? ev)
     (define st* (job-finish st (job-event-id ev) (job-event-result ev)))
     (values (emit st* 'job (list (job-event-id ev) (job-event-kind ev)
                                  (job-event-result ev) (job-event-tag ev)))
             '())]
    [else
     (define g (layout (state-tiling st) (state-floats st) size))
     (define f0 (state-focus st))
     (define-values (st* effs)
       (route-input (or (state-routes st) (app-routes)) (ctx size g) st ev))
     (if (eqv? f0 (state-focus st*))
         (values st* effs)
         (values (emit st* 'focus-changed (list (state-focus st*) f0)) effs))]))

;;; ---------- 装配 ----------

;; 把插件贡献叠加到基础表上，得到本次运行的 op / prompt / panel / region / 键表 / 匹配层，
;; 并编译路由存进 State（step 从 State 读，不依赖插件）。
(define (boot w h #:text [text ""] #:name [name #f]
                   #:root [root (current-directory)]
                   #:plugins [plugins (plugins-by-names enabled-plugin-specs)])
  (define reg (install-plugin-ops base-op-registry plugins))
  (define prompts (install-plugin-prompts base-prompt-kinds plugins))
  (define panel-reg (install-plugin-panels base-panel-registry plugins))
  (define region-list (install-plugin-regions base-regions plugins))
  (define kt (append (append* (collect-key-tables plugins))
                     (compose-keymaps key-tables-spec)))
  (define matchers (append doc-key-matchers-spec (collect-doc-key-matchers plugins)))
  ;; 核心钩子：编辑 / 移动光标后刷新 face（这样插件接管的按键也能刷新）。
  (define core-hooks
    (list (reaction* 'after-edit   (lambda (s a) (refresh-faces-vid! s (and (pair? a) (car a)))))
          (reaction* 'after-insert (lambda (s a) (refresh-faces-vid! s (and (pair? a) (car a)))))
          (reaction* 'after-nav    (lambda (s a) (refresh-faces-vid! s (and (pair? a) (car a)))))))
  (define hooks (append core-hooks (collect-hooks plugins)))
  (define faces (collect-faces plugins))
  (define services (make-service-registry (collect-services plugins)))
  (define routes (app-routes reg prompts kt))
  (define ed0 (blank-editor))
  (define-values (ed1 did vid)
    (if name
        (add-document-view! ed0 text w (max 1 (- h 1)) name)
        (values ed0 #f #f)))
  ;; 为**所有已注册面板**各建一个文档（含插件面板）。
  (define-values (ed2 vids)
    (for/fold ([ed ed1] [vids (hash)]) ([nm (in-list (panel-names panel-reg))])
      (define-values (ed* _pdid vid*) (add-panel! ed "" w 1 nm))
      (values ed* (hash-set vids nm vid*))))
  (define docs
    (for/fold ([d (if did
                      (hash did (doc-meta #f (document-handle ed2 did)))
                      (hash))])
              ([(nm v) (in-hash vids)])
      (hash-set d (view-did ed2 v) (doc-meta #f #f))))
  ;; 底盘：侧栏（区域 sidebar，贴根）+ 主区（编辑器 / 状态栏）。
  (define tree-vid (hash-ref vids "*tree*"))
  (define status-vid (hash-ref vids "*status*"))
  (define right (split 'v (list (item 1 1 1 2 (editor-tile 0 vid default-border))          ; 编辑区 flex（min 2）
                                (item 1 0 0 1 (panel-tile 1 status-vid default-border)))))  ; 状态栏 1 行
  (define base (split 'h (list (item 28 0 0 1 (panel-tile 2 tree-vid default-border))        ; 侧栏固定 28 列
                               (item 1 1 1 2 right))))
  (define st0 (make-state #:ed ed2 #:docs docs #:tiling (tiling base) #:focus 0))
  (define st1 (feature-set st0 'panels panel-reg))
  (define st2 (feature-set st1 'regions region-list))
  (define st3 (feature-set st2 'doc-key-matchers matchers))
  (define st4 (feature-set st3 'routes routes))
  (define st5 (feature-set st4 'plugins plugins))
  (define st5b (feature-set st5 'hooks hooks))
  (define st5c (feature-set st5b 'faces faces))
  (define st5d (feature-set st5c 'services services))
  (define st6 (run-plugin-boots st5d plugins))
  (define st7 (feature-set st6 'tree (tree-init root)))
  (define st8 (region-set-active st7 'sidebar "*tree*"))
  (region-set-active st8 'log "*log*"))
