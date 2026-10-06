#lang racket

;;; lab-rebuild/builtin/panels.rkt —— 左栏文档列表面板（功能包）。
;;;
;;; panel contribution：模型（doc 列表）+ 视图 + 键 + 每帧刷新。
;;; 显示位置由 frame 的 role 决定；平台不认识"面板"是什么。

(require racket/string
         "../kernel/editor-api.rkt"
         "../kernel/effect.rkt"
         "../kernel/binding.rkt"
         "../kernel/table.rkt"
         "../kernel/panel.rkt"
         "../kernel/hooks.rkt"
         "../kernel/session.rkt"
         "../kernel/runtime.rkt"
         "../kernel/registry.rkt")

(provide register-panels!)

;; 内部视图（槽位 + 面板）的 did：不进文档列表。
(define (internal-dids s)
  (define ed (session-editor s))
  (for/list ([v (in-list (append (list (session-status-vid s) (session-input-vid s))
                                 (for/list ([p (in-list (session-panels s))]) (panel-vid p))))])
    (editor-view-document-id ed v)))

(define (doc-list ctx)
  (define s (ctx-session ctx))
  (define ed (session-editor s))
  (for/list ([did (in-list (editor-document-id-list ed))]
             #:unless (memv did (internal-dids s)))
    did))

(define (panel-doc ctx)
  (define s (ctx-session ctx))
  (define ed (session-editor s))
  (document-open (string-join (for/list ([did (in-list (doc-list ctx))])
                                (editor-document-name ed did))
                              "\n")))

;; make : (ed w h) -> (values ed vid data)
(define (make-buffers ed w h)
  (define-values (ed2 _did vid) (editor-add-document-view ed (document-open "") w h "*buffers*"))
  (values ed2 vid '()))

(define (refresh-buffers ctx vid _data)
  (list (e-reload vid (panel-doc ctx))))

(define buffers-panel
  (panel-spec 'buffers 0 make-buffers
              (list (kbd (key 'enter) 'panel-activate
                         (key 'tab)   'toggle-sidebar))
              refresh-buffers))

;;; ================= 命令 =================

(define (cmd-panel-activate ctx ev)
  (define s (ctx-session ctx))
  (define vid (session-focus-vid s))
  (define dids (doc-list ctx))
  (define line (editor-view-point-line (session-editor s) vid))
  (if (< line (length dids))
      (list (e-show (list-ref dids line) 'replace #t))
      '()))

(define (cmd-toggle-sidebar ctx ev)
  (define s (ctx-session ctx))
  (cond
    [(session-sidebar? s) (list (e-sidebar #f) (e-focus 'restore))]
    [(pair? (session-panels s))
     (list (e-sidebar #t) (e-focus-push (panel-vid (car (session-panels s)))))]
    [else (list (e-sidebar #t))]))

;;; ================= 每帧刷新（before-render 钩子） =================

(define (panels-hook ctx _args)
  (define s (ctx-session ctx))
  (append* (for/list ([p (in-list (session-panels s))])
             ((panel-spec-refresh (panel-pspec p)) ctx (panel-vid p) (panel-data p)))))

(define (register-panels! r)
  (reg-add
   (reg-add
    (reg-add
     (reg-add r (contrib 'panel 'buffers 0 buffers-panel))
     (contrib 'command 'panel-activate 0 cmd-panel-activate))
    (contrib 'command 'toggle-sidebar 0 cmd-toggle-sidebar))
   (contrib 'hook 'panels 0 (make-hook 'before-render panels-hook))))
