#lang racket

;;; lab-re-rebuild/app/app.rkt —— 唯一装配点。
;;;
;;; 组装 registry（功能包目录）→ 建主区视图 + 各 dock 视图（kind='dock 贡献）
;;; → 建 workspace / session / runtime / ctx。

(require "../kernel/api.rkt"
         "../config/keys.rkt"
         "../config/packages.rkt")

(provide app-init)

(define (build-registry)
  (for/fold ([r (reg-empty)]) ([p (in-list package-catalog)])
    ((cdr p) r)))

(define (app-init root width height)
  (define reg (build-registry))
  ;; 主区编辑视图
  (define-values (ed0 _did main-vid)
    (editor-add-document-view (make-blank-editor) "" width (max 1 (sub1 height)) "*scratch*"
                              #:line-numbers? #t))
  ;; 各 dock（逻辑在 builtin/status.rkt、builtin/tree.rkt；这里只按贡献建实例）
  (define-values (ed1 docks-rev)
    (for/fold ([ed ed0] [ds '()]) ([c (in-list (reg-kind reg 'dock))])
      (define spec (contrib-value c))
      (define-values (ed* vid) (dock-make-vid spec root ed width height))
      (values ed*
              (cons (dock (dock-spec-id spec) (dock-spec-side spec) (dock-spec-size spec)
                          (dock-spec-visible? spec) vid (dock-spec-keys spec))
                    ds))))
  (define ws (workspace-new (frame-new (leaf main-vid 'edit)) (reverse docks-rev)))
  (define s (make-session ed1 ws (focus-new main-vid) main-vid
                          edit-table global-table width height))
  (define ctx0 (ctx s (make-runtime reg (hash 'root root))))
  ;; 装配后：跑各特性的 init（建 service / 运行时状态）
  (for/fold ([c ctx0]) ([e (in-list (reg-kind reg 'init))])
    ((contrib-value e) c)))
